#!/usr/bin/env python3
"""journal-cli — read and write Apple Journal entries, including media and location.

Journal's store is a Core Data SQLite database at
    ~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite
"moments" is Journal's internal codename. Entry bodies are plain RTF in
ZJOURNALENTRYMO.ZTEXT — not encrypted. Requires Full Disk Access.

Reads run against a temp snapshot so the live store is never locked. Writes are
opt-in, refuse to run while Journal is open, and always back up first.
"""

import argparse, json, os, shutil, sqlite3, stat, subprocess, sys, tempfile, uuid, datetime

GROUP = os.path.expanduser("~/Library/Group Containers/group.com.apple.moments/Library")
DEFAULT_DB = os.path.join(GROUP, "moments.sqlite")
VERSION = "1.5.3"                      # keep in step with npm/package.json
# $JOURNAL_BACKUP_DIR overrides the backup root and, when set, backs up
# sandbox stores too, which is how the test suite exercises backups.
BACKUP_OVERRIDE = os.environ.get("JOURNAL_BACKUP_DIR") or None
BACKUPS = BACKUP_OVERRIDE or os.path.expanduser("~/Backups/journal-cli")
EPOCH = 978307200                      # Core Data reference date -> unix epoch

# Core Data entity ids (Z_ENT), from Z_PRIMARYKEY
ENT = {"entry": "JournalEntryMO", "asset": "JournalEntryAssetMO",
       "file": "JournalEntryAssetFileAttachmentMO"}

PHOTO_EXT = {".jpg", ".jpeg", ".heic", ".heif", ".png", ".gif", ".tiff", ".webp"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi"}

DB = DEFAULT_DB                        # rebound from --db / $JOURNAL_DB


def die(msg, code=1):
    print(f"journal-cli: {msg}", file=sys.stderr)
    sys.exit(code)

def attach_dir():
    """Attachments live beside the database, so sandboxes stay self-contained."""
    return os.path.join(os.path.dirname(os.path.abspath(DB)), "Attachments")

# Entry dates are stored as the true instant (seconds since the Core Data epoch),
# the same encoding the Swift build writes and reads. A naive datetime is taken
# as local wall clock on write, and read back with fromtimestamp() in local time.
def cd_now():
    return cd(datetime.datetime.now())

def cd(dt):
    return dt.timestamp() - EPOCH

def uid():
    return str(uuid.uuid4()).upper()

def uid_bytes(u):
    return uuid.UUID(u).bytes

def u_str(b):
    try: return str(uuid.UUID(bytes=b)).upper()
    except Exception: return None

def stdin_has_data():
    """True only for a pipe or redirected file. A tty or /dev/null would block."""
    if sys.stdin is None or sys.stdin.isatty():
        return False
    try:
        m = os.fstat(sys.stdin.fileno()).st_mode
    except OSError:
        return False
    return stat.S_ISFIFO(m) or stat.S_ISREG(m)

def journal_running():
    return subprocess.run(["pgrep", "-x", "Journal"], capture_output=True).returncode == 0


# ---------------------------------------------------------------- store access

def sqlite_backup(src, dst):
    """Copy a store into one consistent file with SQLite's online backup API.

    Copying the db, -wal and -shm one after another could mix generations if
    Journal checkpointed in between; the backup API reads every page inside a
    single read transaction. The source is opened read-only.
    """
    from urllib.parse import quote
    s = sqlite3.connect(f"file:{quote(os.path.abspath(src))}?mode=ro", uri=True, timeout=5)
    try:
        d = sqlite3.connect(dst)
        try:
            s.backup(d)
        finally:
            d.close()
    finally:
        s.close()


class Snapshot:
    """Read-only: a consistent copy of the store, so the live one is never written."""
    def __enter__(self):
        if not os.path.exists(DB):
            die(f"store not found at {DB}")
        self.dir = tempfile.mkdtemp(prefix="journal-cli.")
        copy = os.path.join(self.dir, os.path.basename(DB))
        try:
            sqlite_backup(DB, copy)
        except sqlite3.Error as e:
            shutil.rmtree(self.dir, ignore_errors=True)
            if not os.access(DB, os.R_OK):
                die("permission denied. Grant Full Disk Access to this terminal, then relaunch it.")
            die(f"could not snapshot the store: {e}")
        os.chmod(copy, 0o600)       # mkdtemp's folder is already owner-only
        self.conn = sqlite3.connect(copy)
        self.conn.row_factory = sqlite3.Row
        return self.conn
    def __exit__(self, *e):
        try: self.conn.close()
        finally: shutil.rmtree(self.dir, ignore_errors=True)


def backup(reason="write"):
    """Back up the store before a live write. Fails closed, one folder per call."""
    try:
        os.makedirs(BACKUPS, exist_ok=True)
    except OSError as e:
        die(f"backup failed: cannot create {BACKUPS}: {e.strerror}\n  Nothing was written.")
    stem = os.path.join(BACKUPS, datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + f"-{reason}")
    d, n = stem, 1
    while True:
        try:
            os.mkdir(d, 0o700); break      # owner-only: a full copy of the journal
        except FileExistsError:
            n += 1; d = f"{stem}-{n}"
        except OSError as e:
            die(f"backup failed: cannot create {d}: {e.strerror}\n  Nothing was written.")
    dst = os.path.join(d, os.path.basename(DB))
    try:
        sqlite_backup(DB, dst)
    except sqlite3.Error as e:
        shutil.rmtree(d, ignore_errors=True)    # no half-written recovery point
        die(f"backup failed: {e}\n  Nothing was written.")
    for suf in ("", "-wal", "-shm"):
        if os.path.exists(dst + suf): os.chmod(dst + suf, 0o600)
    return d


# Filesystem side effects of the open live write: folders it created (removed
# again if it aborts) and folders to remove, which wait for the commit and move
# into the write's backup when it has one.
LIVE_FILES = None

def stage_created(path):
    if LIVE_FILES is not None: LIVE_FILES["created"].append(path)

def schedule_removal(path):
    if LIVE_FILES is not None: LIVE_FILES["removals"].append(path)
    elif os.path.isdir(path): shutil.rmtree(path, ignore_errors=True)

def apply_removals(files, backup_dir):
    root = attach_dir()
    for path in files["removals"]:
        if not os.path.exists(path): continue
        if not backup_dir:
            shutil.rmtree(path, ignore_errors=True); continue
        rel = os.path.relpath(path, root) if path.startswith(root + os.sep) else os.path.basename(path)
        dest = os.path.join(backup_dir, "Attachments", rel)
        try:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.move(path, dest)
        except OSError as e:
            print(f"journal-cli: warning: kept {path} (could not move it into the backup: {e})",
                  file=sys.stderr)


RISK_MARKER = os.path.expanduser("~/.config/journal-cli/risk-accepted")
RISK_WARNING = """\
================================ WARNING =====================================
journal-cli writes DIRECTLY to Apple Journal's private, undocumented data
store. Apple does not support this. A future macOS update can change the
schema at any time, and a malformed write could corrupt entries or confuse
iCloud sync across ALL your devices.

Before your first live write:
  1. BACK UP your journal in Journal.app:
       Journal -> Settings -> Export Journal Entries...
  2. Know that journal-cli also snapshots the local store to
     ~/Backups/journal-cli/ before every live write -- but that cannot undo
     anything that has already synced to iCloud.

You use this tool AT YOUR OWN RISK.
==============================================================================
"""

def ensure_risk_accepted(accept_flag):
    if os.path.exists(RISK_MARKER):
        return
    def record():
        os.makedirs(os.path.dirname(RISK_MARKER), exist_ok=True)
        open(RISK_MARKER, "w").write(f"accepted {datetime.datetime.now()}\n")
    print(RISK_WARNING, file=sys.stderr)
    if accept_flag:
        print("Risk accepted via --accept-risk.", file=sys.stderr)
        record(); return
    if sys.stdin.isatty():
        try:
            line = input('Type "I understand" to continue: ')
        except EOFError:
            line = ""
        if line.strip().lower() == "i understand":
            record(); return
        die("not accepted; nothing was written")
    die("first live write requires accepting the risk above.\n"
        "  Re-run with --accept-risk (agents: ask the user before passing this).")


def same_store(a, b):
    """Same database file? A hard link to the real store has its own path, and
    treating it as a sandbox would skip every live-write guard."""
    if os.path.realpath(a) == os.path.realpath(b):
        return True
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def lock_store(path):
    """One journal-cli writer per store for the whole write (backup, transaction,
    post-commit file moves), keyed by the store file's identity. Same lock file
    as the Swift build, so the two never interleave."""
    import fcntl
    try:
        st = os.stat(path)
    except OSError:
        return
    # One fixed, owner-only place under the account's real home (pwd, not
    # $HOME, to match the Swift build's NSHomeDirectory), never the temp
    # folder, which TMPDIR can move.
    import pwd
    d = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library/Caches/journal-cli/locks")
    os.makedirs(d, mode=0o700, exist_ok=True)
    lock = os.path.join(d, f"write-{st.st_dev}-{st.st_ino}.lock")
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("journal-cli: waiting for another journal-cli write to finish...", file=sys.stderr)
        fcntl.flock(fd, fcntl.LOCK_EX)
    globals().setdefault("_LOCK_FDS", []).append(fd)   # held until exit

class Live:
    """Read-write against the real store. Guarded."""
    def __init__(self, allow_live_default=False, accept_risk=False):
        self.is_default = same_store(DB, DEFAULT_DB)
        self.allow = allow_live_default
        self.accept = accept_risk
    def __enter__(self):
        global DB
        if self.is_default and DB != DEFAULT_DB:
            DB = DEFAULT_DB          # an alias of the real store is the real store
        lock_store(DB)
        if self.is_default:
            if not self.allow:
                die("refusing to modify the real Journal store without --live.\n"
                    "  Test against a sandbox first:  journal-cli sandbox --dir DIR")
            ensure_risk_accepted(self.accept)
            if journal_running():
                die("Journal.app is running. Quit it first, then retry.")
        # Take the write lock first and back up under it, so no other writer
        # commits between the backup and this write. Readers (the backup's own
        # connection included) are not blocked by a reserved lock.
        self.conn = sqlite3.connect(DB, timeout=5)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("BEGIN IMMEDIATE")
        self.backup = None
        if self.is_default or BACKUP_OVERRIDE:
            self.backup = backup()
            print(f"backup: {self.backup}", file=sys.stderr)
        global LIVE_FILES
        LIVE_FILES = self.files = {"created": [], "removals": []}
        return self.conn
    def __exit__(self, exc_type, *rest):
        global LIVE_FILES
        LIVE_FILES = None
        try:
            if not exc_type:
                self.conn.commit()        # a failed commit lands in the except below
                committed = True
            else:
                committed = False
        except BaseException:
            committed = False
            raise
        finally:
            if not committed:
                try: self.conn.rollback()
                except sqlite3.Error: pass
            self.conn.close()
            if not committed:
                for p in reversed(self.files["created"]):
                    shutil.rmtree(p, ignore_errors=True)
        if committed:                     # only a committed write removes files
            apply_removals(self.files, self.backup)


# ---------------------------------------------------------------- RTF

def rtf_batch(blobs):
    out = [""] * len(blobs)
    idxs = [i for i, b in enumerate(blobs) if b]
    if not idxs: return out
    d = tempfile.mkdtemp(prefix="journal-rtf.")
    try:
        names = []
        for i in idxs:
            n = os.path.join(d, f"{i}.rtf")
            open(n, "wb").write(blobs[i]); names.append(n)
        # Bounded batches: one textutil call per whole library overflows argv
        # (and its timeout) on large journals.
        err, failed = "", False
        for k in range(0, len(names), 200):
            r = subprocess.run(["textutil", "-convert", "txt"] + names[k:k + 200],
                               capture_output=True, timeout=180)
            if r.returncode != 0:
                failed = True; err = r.stderr.decode(errors="replace").strip()
        missing = [i for i in idxs if not os.path.exists(os.path.join(d, f"{i}.txt"))]
        # A failed conversion must not read as empty text: fetch would drop the
        # entry and export would report success without it.
        if failed or missing:
            die(f"textutil could not convert {len(missing) or 'some'} RTF blob(s)"
                + (f": {err}" if err else ""))
        for i in idxs:
            out[i] = open(os.path.join(d, f"{i}.txt"), errors="replace").read().strip()
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return out

def txt_to_rtf(text):
    d = tempfile.mkdtemp(prefix="journal-rtf.")
    try:
        src = os.path.join(d, "in.txt"); open(src, "w").write(text)
        subprocess.run(["textutil", "-convert", "rtf", src], capture_output=True, timeout=60)
        rtf = os.path.join(d, "in.rtf")
        if not os.path.exists(rtf): die("textutil failed to produce RTF")
        return open(rtf, "rb").read()
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------- media helpers

RESIZE_MAX = 2830   # long edge of Journal's own _resized derivatives (~6MP)

def image_dims(path):
    try:
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                             capture_output=True, text=True, timeout=30).stdout
        w = h = 0
        for l in out.splitlines():
            if "pixelWidth" in l: w = int(l.split()[-1])
            if "pixelHeight" in l: h = int(l.split()[-1])
        return w, h
    except Exception:
        return 0, 0

def resize_into(src, dst):
    """Copy src to dst, downscaling to RESIZE_MAX long edge like Journal does."""
    w, h = image_dims(src)
    # sips keeps only the first frame, so an animated GIF would lose its
    # animation. Copy GIFs unchanged.
    if max(w, h) > RESIZE_MAX and os.path.splitext(src)[1].lower() != ".gif":
        r = subprocess.run(["sips", "-Z", str(RESIZE_MAX), src, "--out", dst],
                           capture_output=True, timeout=120)
        if r.returncode == 0 and os.path.exists(dst):
            return True
    shutil.copy2(src, dst)
    return False

# $JOURNAL_PHOTOS_DB points --photos-link at another library (the tests use it).
PHOTOS_DB = (os.environ.get("JOURNAL_PHOTOS_DB")
             or os.path.expanduser("~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"))

def photos_lookup(path):
    """Best-effort PHAsset localIdentifier ('UUID/L0/001') for a media file."""
    stem, _ = os.path.splitext(os.path.basename(path))
    # exported straight out of the library: originals/<x>/<UUID>.ext
    if ".photoslibrary/" in path:
        try:
            uuid.UUID(stem)
            return f"{stem.upper()}/L0/001"
        except ValueError:
            pass
    if not os.path.exists(PHOTOS_DB):
        return None
    try:
        # Plain read-only, not immutable=1: Photos keeps recent assets in its
        # WAL, and immutable would ignore them.
        from urllib.parse import quote
        c = sqlite3.connect(f"file:{quote(PHOTOS_DB)}?mode=ro", uri=True, timeout=5)
        rows = c.execute("""select a.ZUUID, aa.ZORIGINALFILESIZE
                            from ZASSET a
                            join ZADDITIONALASSETATTRIBUTES aa on aa.ZASSET=a.Z_PK
                            where aa.ZORIGINALFILENAME=?""",
                         (os.path.basename(path),)).fetchall()
        c.close()
    except Exception:
        return None
    # A filename alone is not identity (IMG_0001.JPG is everywhere): the size
    # must match too, even for a single candidate.
    if not rows or not os.path.exists(path):
        return None
    size = os.path.getsize(path)
    hits = [r for r in rows if r[1] == size]
    return f"{hits[0][0]}/L0/001" if len(hits) == 1 else None


# ---------------------------------------------------------------- links

MKLINK_SWIFT = r"""
import Foundation
import LinkPresentation
let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else { exit(1) }
let md = LPLinkMetadata()
md.originalURL = url
md.url = url
if args.count >= 3 { md.title = args[2] }
let data = try NSKeyedArchiver.archivedData(withRootObject: md, requiringSecureCoding: true)
print(data.base64EncodedString())
"""

def check_link_url(url):
    """Shared by the real write and --dry-run."""
    from urllib.parse import urlparse
    u = urlparse(url)
    if u.scheme not in ("http", "https") or not u.netloc:
        die(f"--link needs an absolute http(s) URL, got {url!r}")

def check_media_type(path):
    ext = os.path.splitext(path)[1].lower()
    if ext not in PHOTO_EXT and ext not in VIDEO_EXT:
        die(f"unsupported media type {ext!r} ({path})")

def make_link_payload(url, title=None):
    """base64 NSKeyedArchiver LPLinkMetadata, the format Journal's link assets use."""
    check_link_url(url)
    if not shutil.which("swift"):
        die("writing a link needs the `swift` CLI (Xcode or Command Line Tools)")
    d = tempfile.mkdtemp(prefix="journal-link.")
    try:
        src = os.path.join(d, "mklink.swift")
        open(src, "w").write(MKLINK_SWIFT)
        args = ["swift", src, url] + ([title] if title else [])
        r = subprocess.run(args, capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not r.stdout.strip():
            die(f"could not build link metadata for {url!r}: {r.stderr.strip()[:200]}")
        return r.stdout.strip()
    finally:
        shutil.rmtree(d, ignore_errors=True)

def decode_link_payload(meta):
    """Pull url/title back out of a link asset's archived LPLinkMetadata."""
    import base64, plistlib
    try:
        raw = base64.b64decode(meta.get("data", ""))
        objs = plistlib.loads(raw).get("$objects", [])
        strs = [o for o in objs if isinstance(o, str) and o != "$null"]
        url = next((o for o in strs if o.startswith(("http://", "https://"))), None)
        title = next((o for o in strs if not o.startswith(("http://", "https://"))
                      and "/" not in o and not o.endswith(".ico")), None)
        return url, title
    except Exception:
        return None, None

def external_data_dir():
    return os.path.join(os.path.dirname(os.path.abspath(DB)),
                        ".moments_SUPPORT", "_EXTERNAL_DATA")

def resolve_meta(m):
    """parse_meta, following a version-2 external-storage ref to its file."""
    p = parse_meta(m)
    if isinstance(p, dict) and set(p) == {"ref"}:
        f = os.path.join(external_data_dir(), p["ref"])
        if os.path.exists(f):
            try:
                ext = json.loads(open(f, "rb").read())
                if isinstance(ext, dict):
                    ext["_external"] = p["ref"]
                    return ext
            except Exception:
                pass
    return p


# ---------------------------------------------------------------- metadata blobs

def meta_blob(obj):
    """Journal asset metadata: one version byte (0x01) then JSON."""
    return b"\x01" + json.dumps(obj, ensure_ascii=False).encode()

def parse_meta(b):
    if not b: return None
    if b[:1] == b"\x02":
        # version 2: a bare UUID reference to an externally stored payload
        # (seen on drawing, workoutRoute, and link assets)
        try: return {"ref": b[1:].rstrip(b"\x00").decode("ascii")}
        except Exception: return None
    try: return json.loads(b[1:] if b[:1] == b"\x01" else b)
    except Exception: return None


# ---------------------------------------------------------------- queries

def fetch(conn, since=None, until=None, include_empty=False):
    rows = conn.execute("""
        select Z_PK, ZID, ZENTRYDATE, ZTEXTLENGTH, ZFLAGGED, ZISDRAFT,
               ZISUPLOADEDTOCLOUD, ZTITLE, ZTEXT
        from ZJOURNALENTRYMO
        where coalesce(ZISFULLYREMOVED,0)=0 and coalesce(ZRECENTLYDELETED,0)=0
          and coalesce(ZISTIP,0)=0
        order by ZENTRYDATE desc""").fetchall()
    titles = rtf_batch([r["ZTITLE"] for r in rows])
    texts  = rtf_batch([r["ZTEXT"] for r in rows])
    out = []
    for r, ti, tx in zip(rows, titles, texts):
        if r["ZENTRYDATE"] is None: continue
        dt = datetime.datetime.fromtimestamp(r["ZENTRYDATE"] + EPOCH)
        if since and dt < since: continue
        if until and dt > until: continue
        if not include_empty and not tx.strip() and not ti.strip(): continue
        out.append({"id": r["Z_PK"], "uuid": u_str(r["ZID"]),
                    "date": dt.isoformat(sep=" ", timespec="seconds"),
                    "title": ti, "text": tx, "chars": r["ZTEXTLENGTH"] or 0,
                    "bookmarked": bool(r["ZFLAGGED"]), "draft": bool(r["ZISDRAFT"]),
                    "synced": bool(r["ZISUPLOADEDTOCLOUD"])})
    return out

def fetch_one(conn, pk):
    """Single entry, without decoding RTF for the whole library."""
    r = conn.execute("""
        select Z_PK, ZID, ZENTRYDATE, ZTEXTLENGTH, ZFLAGGED, ZISDRAFT,
               ZISUPLOADEDTOCLOUD, ZTITLE, ZTEXT
        from ZJOURNALENTRYMO where Z_PK=?""", (pk,)).fetchone()
    if not r: return None
    ti, tx = rtf_batch([r["ZTITLE"], r["ZTEXT"]])
    # 0 is a real date (2001-01-01, the Core Data epoch), not a missing one.
    dt = (datetime.datetime.fromtimestamp(r["ZENTRYDATE"] + EPOCH)
          if r["ZENTRYDATE"] is not None else None)
    return {"id": r["Z_PK"], "uuid": u_str(r["ZID"]),
            "date": dt.isoformat(sep=" ", timespec="seconds") if dt else None,
            "title": ti, "text": tx, "chars": r["ZTEXTLENGTH"] or 0,
            "bookmarked": bool(r["ZFLAGGED"]), "draft": bool(r["ZISDRAFT"]),
            "synced": bool(r["ZISUPLOADEDTOCLOUD"])}

def assets_for(conn, pk):
    # Removed assets are not part of the entry; hidden ones are, flagged.
    rows = conn.execute("""
        select Z_PK, ZID, ZASSETTYPE, ZSOURCE, ZASSETMETADATA, ZISHIDDEN
        from ZJOURNALENTRYASSETMO
        where ZENTRY=? and coalesce(ZISFULLYREMOVED,0)=0 and coalesce(ZISUNDOABLYDELETED,0)=0
        order by Z_PK""", (pk,)).fetchall()
    # Journal's display order is the entry's ZASSETORDERING; unlisted follow.
    pos = {}
    er = conn.execute("select ZASSETORDERING from ZJOURNALENTRYMO where Z_PK=?", (pk,)).fetchone()
    try:
        lst = json.loads(er[0]) if er and er[0] else []
    except (ValueError, TypeError):
        lst = []
    for i in range(0, len(lst) - 1, 2):
        if isinstance(lst[i], str) and isinstance(lst[i + 1], int):
            pos[lst[i].upper()] = lst[i + 1]
    rows = sorted(rows, key=lambda r: pos.get((u_str(r["ZID"]) or "").upper(), float("inf")))
    out = []
    for r in rows:
        m = resolve_meta(r["ZASSETMETADATA"])
        if not isinstance(m, dict): m = {}
        a = {"id": r["Z_PK"], "uuid": u_str(r["ZID"]), "type": r["ZASSETTYPE"],
             "source": r["ZSOURCE"], "files": []}
        if r["ZISHIDDEN"]: a["hidden"] = True
        if r["ZASSETTYPE"] in ("multiPinMap", "genericMap"):
            visits = m.get("visitsData") or []
            if not isinstance(visits, list): visits = []
            a["places"] = [{"name": v.get("placeName"), "city": v.get("city"),
                            "lat": v.get("latitude"), "lon": v.get("longitude")}
                           for v in visits
                           if isinstance(v, dict) and v.get("latitude") is not None]
        elif r["ZASSETTYPE"] == "audio":
            if m.get("duration") is not None: a["duration"] = m["duration"]
            segs = m.get("transcriptSegments") or []
            words = [x.get("text","") for x in segs if isinstance(x, dict)]
            if words: a["transcript"] = " ".join(w for w in words if w)
        elif r["ZASSETTYPE"] == "drawing":
            ic = (m.get("indexableContent") or "").strip()
            if ic: a["drawing_text"] = ic
        elif r["ZASSETTYPE"] == "link":
            url, title = decode_link_payload(m)
            if url: a["url"] = url
            if title: a["link_title"] = title
        elif isinstance(m, dict) and "latitude" in m:
            a["place"] = {"name": m.get("placeName"), "lat": m.get("latitude"),
                          "lon": m.get("longitude")}
        for f in conn.execute("""select ZFILEPATH, ZNAME, ZINDEX
                                 from ZJOURNALENTRYASSETFILEATTACHMENTMO
                                 where ZASSET=? order by ZINDEX""", (r["Z_PK"],)):
            p = f["ZFILEPATH"]
            if not p: continue
            full = p if os.path.isabs(p) else os.path.join(attach_dir(), p)
            a["files"].append({"path": full, "name": f["ZNAME"],
                               "exists": os.path.exists(full)})
        out.append(a)
    return out


# ---------------------------------------------------------------- read commands

def parse_date(s):
    if not s: return None
    for f in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try: return datetime.datetime.strptime(s, f)
        except ValueError: pass
    die(f"cannot parse date {s!r} (use YYYY-MM-DD)")

def render(ents, as_json, limit=None, full=False):
    if limit: ents = ents[:limit]
    if as_json:
        print(json.dumps(ents, indent=2, ensure_ascii=False)); return
    if not ents:
        print("No entries."); return
    for e in ents:
        mark = "*" if e["bookmarked"] else (" " if e["synced"] else "+")
        head = e["title"] or (e["text"].split("\n")[0][:60] if e["text"] else "(empty)")
        print(f"{mark}{e['id']:>5}  {e['date']:<20}  {head}")
        if full and e["text"]:
            for line in e["text"].splitlines(): print(f"        {line}")
            print()
    print(f"\n{len(ents)} entr{'y' if len(ents)==1 else 'ies'}.")

def cmd_list(a):
    with Snapshot() as c:
        render(fetch(c, parse_date(a.since), parse_date(a.until), a.include_empty),
               a.json, a.limit, a.full)

def cmd_show(a):
    with Snapshot() as c:
        e = fetch_one(c, a.id)
        if not e: die(f"no entry with id {a.id}")
        e["assets"] = assets_for(c, a.id)
    if a.json:
        print(json.dumps(e, indent=2, ensure_ascii=False)); return
    print(f"id      {e['id']}\nuuid    {e['uuid']}\ndate    {e['date']}")
    if e["title"]: print(f"title   {e['title']}")
    flags = [k for k in ("bookmarked", "draft") if e[k]] + ([] if e["synced"] else ["unsynced"])
    if flags: print(f"flags   {', '.join(flags)}")
    print()
    print(e["text"] or "(no text)")
    for asset in e["assets"]:
        if asset.get("transcript") is not None or asset.get("duration") is not None:
            dur = f"{asset['duration']:.1f}s" if asset.get("duration") else ""
            tr = f'  "{asset["transcript"]}"' if asset.get("transcript") else ""
            print(f"\naudio (asset {asset['id']})  {dur}{tr}")
        if asset.get("drawing_text"):
            print(f"\ndrawing (asset {asset['id']})  text: {asset['drawing_text']}")
        if asset.get("url"):
            t = f"  {asset['link_title']}" if asset.get("link_title") else ""
            print(f"\nlink (asset {asset['id']})  {asset['url']}{t}")
        if asset.get("places"):
            for p in asset["places"]:
                loc = ", ".join(x for x in (p.get("name"), p.get("city")) if x)
                print(f"\nlocation  {loc or '(unnamed)'}  "
                      f"({p.get('lat')}, {p.get('lon')})")
        for f in asset["files"]:
            print(f"\n{asset['type']} (asset {asset['id']})  "
                  f"{'ok' if f['exists'] else 'MISSING'}  {f['path']}")

def cmd_search(a):
    q = a.query.lower()
    with Snapshot() as c:
        hits = [e for e in fetch(c) if q in e["text"].lower() or q in (e["title"] or "").lower()]
    render(hits, a.json, a.limit, a.full)

def cmd_export(a):
    try:
        os.makedirs(a.dir, exist_ok=True)
    except OSError as e:
        die(f"cannot create {a.dir}: {e.strerror}")
    with Snapshot() as c:
        # Keep entries with words OR assets: photo- or location-only entries count.
        ents = []
        for e in fetch(c, include_empty=True):
            e["assets"] = assets_for(c, e["id"])
            if e["text"] or e["title"] or e["assets"]: ents.append(e)
    if a.format == "json":
        p = os.path.join(a.dir, "journal.json")
        try:
            with open(p, "w") as f: json.dump(ents, f, indent=2, ensure_ascii=False)
        except OSError as e:
            die(f"cannot write {p}: {e.strerror}")
        print(f"Wrote {len(ents)} entries to {p}"); return
    try:
        _export_md(a, ents)
    except OSError as e:
        die(f"cannot write to {a.dir}: {e.strerror}")
    print(f"Wrote {len(ents)} entries to {a.dir}")

def _export_md(a, ents):
    for e in ents:
        slug = "".join(ch if ch.isalnum() or ch in "-_ " else "" for ch in (e["title"] or ""))
        slug = slug[:50].strip().replace(" ", "-")
        name = f"{e['date'][:10]}-{e['id']}{('-'+slug) if slug else ''}.md"
        with open(os.path.join(a.dir, name), "w") as f:
            f.write(f"---\ndate: {e['date']}\nid: {e['id']}\n")
            if e["title"]: f.write(f"title: {json.dumps(e['title'])}\n")
            if e["bookmarked"]: f.write("bookmarked: true\n")
            places = [p for asset in e["assets"] for p in asset.get("places", [])]
            if places:
                f.write("locations:\n")
                for p in places:
                    f.write(f"  - name: {json.dumps(p.get('name'))}\n"
                            f"    lat: {yaml_num(p.get('lat'))}\n    lon: {yaml_num(p.get('lon'))}\n")
            f.write("---\n\n" + e["text"] + "\n")
            files = [x for asset in e["assets"] for x in asset["files"]]
            if files:
                f.write("\n")
                for x in files:
                    f.write(f"![{md_label(x['name'] or 'file')}]({md_dest(x['path'])})\n")
            # Content that lives in assets rather than files.
            extras = md_asset_text(e["assets"])
            if extras:
                f.write("\n" + "\n".join(extras) + "\n")

def yaml_num(v):
    """A numeric YAML scalar, or null ("None" would read as a string)."""
    return "null" if v is None else repr(float(v)) if isinstance(v, float) else str(v)

def md_label(s):
    """Markdown link text with brackets and backslashes escaped."""
    return "".join("\\" + ch if ch in "\\[]&" else ch for ch in s)

def md_dest(s, is_path=True):
    """Angle-bracket Markdown destination: survives spaces and parentheses."""
    # line breaks can't appear in a destination; %, # and ? are URL syntax
    # a renderer would act on ("%20" -> space, "#"/"?" cut the path short)
    enc = {"\n": "%0A", "\r": "%0D"}
    if is_path:                         # a web link keeps its own query and escapes
        enc.update({"%": "%25", "#": "%23", "?": "%3F"})
    return "<" + "".join(enc.get(ch) or ("\\" + ch if ch in "\\<>&" else ch)
                         for ch in s) + ">"

def md_asset_text(assets):
    """Readable text carried by non-file assets: links, transcripts, drawings."""
    lines = []
    for a in assets:
        if a.get("url"):
            lines.append(f"[{md_label(a.get('link_title') or a['url'])}]({md_dest(a['url'], is_path=False)})")
        if a.get("transcript"): lines.append(f"Audio transcript: {a['transcript']}")
        if a.get("drawing_text"): lines.append(f"Drawing: {a['drawing_text']}")
    return lines

def cmd_stats(a):
    with Snapshot() as c:
        ents = fetch(c, include_empty=True)
        n_at = c.execute("select count(*) from ZJOURNALENTRYASSETFILEATTACHMENTMO").fetchone()[0]
        n_loc = c.execute("""select count(*) from ZJOURNALENTRYASSETMO
                             where ZASSETTYPE in ('multiPinMap','genericMap')""").fetchone()[0]
    real = [e for e in ents if e["text"].strip()]
    by_year = {}
    for e in real: by_year[e["date"][:4]] = by_year.get(e["date"][:4], 0) + 1
    print(f"entries      {len(real)} with text ({len(ents)} rows total)")
    print(f"words        {sum(len(e['text'].split()) for e in real):,}")
    print(f"attachments  {n_at}")
    print(f"locations    {n_loc}")
    if real: print(f"range        {real[-1]['date'][:10]} .. {real[0]['date'][:10]}")
    print("\nby year")
    for y in sorted(by_year):
        print(f"  {y}  {by_year[y]:>4}  {'#' * min(by_year[y], 50)}")


# ---------------------------------------------------------------- journals

def _crdt_varint(b, i):
    """Read one base-128 varint at i. Returns (value, next_index)."""
    value = shift = 0
    while i < len(b):
        byte = b[i]
        i += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, i
        shift += 7
        if shift > 63:
            break
    raise ValueError("truncated varint")


def _crdt_fields(b, field):
    """Payloads of every length-delimited `field` at this nesting level."""
    out, i = [], 0
    while i < len(b):
        try:
            key, i = _crdt_varint(b, i)
        except ValueError:
            return out
        number, wire = key >> 3, key & 7
        try:
            if wire == 0:
                _, i = _crdt_varint(b, i)
            elif wire == 1:
                i += 8
            elif wire == 5:
                i += 4
            elif wire == 2:
                n, i = _crdt_varint(b, i)
                if i + n > len(b):
                    return out
                if number == field:
                    out.append(b[i:i + n])
                i += n
            else:
                return out
        except ValueError:
            return out
    return out


def journal_name_from_crdt(blob):
    """The journal's name, or None.

    The blob is an 8-byte "crdt" + version header followed by protobuf. The
    attributes live in the field 6 submessage as repeated length-delimited
    strings (field 2), alternating value then key: "TV", "title", "Sand",
    "color", and so on.

    Reading the declared lengths keeps short names intact. Scanning for runs
    of printable bytes instead loses any name below the run threshold and
    reports the neighbouring replica-id bytes, which change as iCloud touches
    the record.
    """
    if not blob or len(blob) <= 8:
        return None
    strings = []
    for submessage in _crdt_fields(blob[8:], 6):
        for s in _crdt_fields(submessage, 2):
            strings.append(s.decode("utf-8", "replace"))
    # walk the value/key pairs, so a journal named "title" reports its own name
    for i in range(0, len(strings) - 1, 2):
        if strings[i + 1] == "title":
            return strings[i]
    return None


def journal_rows(conn):
    out = []
    for r in conn.execute("""select Z_PK, ZMERGEABLEATTRIBUTES, ZSORTCATEGORY
                             from ZJOURNALMO where coalesce(ZUSERDELETED,0)=0
                             order by Z_PK"""):
        blob = r["ZMERGEABLEATTRIBUTES"]
        name = "Journal"          # the built-in default has no CRDT blob
        if blob:
            name = journal_name_from_crdt(blob) or name
        out.append({"pk": r["Z_PK"], "name": name,
                    "default": blob is None and r["ZSORTCATEGORY"] is not None
                               and r["ZSORTCATEGORY"] < 0})
    return out

def resolve_journal(conn, sel):
    """sel is a name or a pk. Returns (pk, name, is_default)."""
    rows = journal_rows(conn)
    if str(sel).isdigit():
        for j in rows:
            if j["pk"] == int(sel): return j["pk"], j["name"], j["default"]
        die(f"no journal with id {sel}")
    hits = [j for j in rows if j["name"].lower() == str(sel).lower()]
    if len(hits) == 1:
        return hits[0]["pk"], hits[0]["name"], hits[0]["default"]
    if not hits:
        die(f"no journal named {sel!r}. Have: " + ", ".join(f"{j['name']} ({j['pk']})" for j in rows))
    die(f"journal name {sel!r} is ambiguous; use the id: " +
        ", ".join(str(j["pk"]) for j in hits))

def cmd_journals(a):
    with Snapshot() as c:
        rows = journal_rows(c)
        live = ("coalesce(e.ZISFULLYREMOVED,0)=0 and coalesce(e.ZRECENTLYDELETED,0)=0 "
                "and coalesce(e.ZISTIP,0)=0 and e.ZENTRYDATE is not null")
        counts = dict(c.execute(f"""select j.Z_6JOURNALS, count(*) from Z_5JOURNALS j
                                    join ZJOURNALENTRYMO e on e.Z_PK=j.Z_5ENTRIES
                                    where {live} group by 1"""))
        unassigned = c.execute(f"""select count(*) from ZJOURNALENTRYMO e
                                   where {live}
                                     and not exists(select 1 from Z_5JOURNALS j where j.Z_5ENTRIES=e.Z_PK)""").fetchone()[0]
    if a.json:
        for j in rows: j["entries"] = counts.get(j["pk"], 0) + (unassigned if j["default"] else 0)
        print(json.dumps(rows, indent=2)); return
    for j in rows:
        n = counts.get(j["pk"], 0) + (unassigned if j["default"] else 0)
        tag = "  (default)" if j["default"] else ""
        print(f"{j['pk']:>3}  {j['name']:<24} {n:>4} entries{tag}")


# ---------------------------------------------------------------- write

def next_pk(conn, kind):
    name = ENT[kind]
    row = conn.execute("select Z_ENT, Z_MAX from Z_PRIMARYKEY where Z_NAME=?", (name,)).fetchone()
    if not row: die(f"entity {name} missing from Z_PRIMARYKEY")
    pk = row["Z_MAX"] + 1
    conn.execute("update Z_PRIMARYKEY set Z_MAX=? where Z_NAME=?", (pk, name))
    return row["Z_ENT"], pk

# Journal stores a map card's size in the asset row (ZISSLIM), but stores "Off"
# only in the entry's own CRDT, under `hiddenAssetIDs` — the asset row of a
# hidden map is byte-identical to a large one (ZISSLIM=0, ZISHIDDEN=0). Setting
# ZISHIDDEN=1 does not hide the card; Journal drops the location entirely,
# Places included. We do not author CRDTs, so "off" is not ours to write.
def location_slim(a, has_loc):
    if a.location_presentation is None:
        return 1
    if not has_loc:
        die("--location-presentation needs --lat and --lon")
    if a.location_presentation == "off":
        die("--location-presentation off is not supported.\n"
            "  Journal records a hidden map only in the entry's CRDT, which\n"
            "  journal-cli does not write. Earlier builds approximated it with\n"
            "  ZISHIDDEN=1, which makes Journal drop the location altogether —\n"
            "  no map card AND no Places entry. Use small or large.")
    return 1 if a.location_presentation == "small" else 0

def add_asset(conn, entry_pk, entry_uuid, asset_type, source, metadata, slim=0):
    ent, pk = next_pk(conn, "asset")
    au = uid()
    conn.execute("""
        insert into ZJOURNALENTRYASSETMO
          (Z_PK, Z_ENT, Z_OPT, ZENTRY, ZID, ZPARENTID, ZASSETTYPE, ZSOURCE,
           ZCREATEDDATE, ZASSETMETADATA, ZISSLIM, ZISHIDDEN, ZISBEINGEDITED,
           ZISUNDOABLYDELETED, ZISUPLOADEDTOCLOUD, ZISREMOVEDFROMCLOUD,
           ZREFRESHASSETMETADATA, ZMINIMUMSUPPORTEDAPPVERSION)
        values (?,?,1,?,?,?,?,?,?,?,?,0,0,0,0,0,0,0)""",
        (pk, ent, entry_pk, uid_bytes(au), uid_bytes(entry_uuid), asset_type, source,
         cd_now(), meta_blob(metadata) if metadata is not None else None, slim))
    return pk, au

def add_file(conn, asset_pk, asset_uuid, entry_uuid, src_path, index,
             resize=True, plain_name=False):
    ext = os.path.splitext(src_path)[1].lower()
    if ext in VIDEO_EXT: name = "video"
    elif ext in PHOTO_EXT: name = "image"
    else: die(f"unsupported media type {ext!r} ({src_path})")
    rel_dir = os.path.join(entry_uuid, asset_uuid)
    entry_dir = os.path.join(attach_dir(), entry_uuid)
    abs_dir = os.path.join(attach_dir(), rel_dir)
    new_entry, new_asset = not os.path.exists(entry_dir), not os.path.exists(abs_dir)
    # Staged before creating, so a failure part way through still cleans up.
    if new_entry: stage_created(entry_dir)
    elif new_asset: stage_created(abs_dir)
    try:
        os.makedirs(abs_dir, exist_ok=True)
    except OSError as e:
        die(f"cannot create attachment folder {abs_dir}: {e.strerror}")
    fname = f"{uid()}{ext}" if plain_name else f"{uid()}_resized{ext}"
    dst = os.path.join(abs_dir, fname)
    try:
        if name == "image" and resize:
            resize_into(src_path, dst)
        else:
            shutil.copy2(src_path, dst)
    except OSError as e:
        die(f"cannot copy {src_path} into the store: {e.strerror}")
    ent, pk = next_pk(conn, "file")
    conn.execute("""
        insert into ZJOURNALENTRYASSETFILEATTACHMENTMO
          (Z_PK, Z_ENT, Z_OPT, ZASSET, ZID, ZPARENTID, ZFILEPATH, ZNAME, ZINDEX,
           ZISUPLOADEDTOCLOUD, ZISREMOVEDFROMCLOUD)
        values (?,?,1,?,?,?,?,?,?,0,0)""",
        (pk, ent, asset_pk, uid_bytes(uid()), uid_bytes(asset_uuid),
         os.path.join(rel_dir, fname), name, index))
    return pk

def read_body_file(path):
    """A read failure must not look like an empty body: `edit` would clear the text."""
    try:
        with open(os.path.expanduser(path), "rb") as f:
            raw = f.read()
    except OSError as e:
        die(f"cannot read --body-file: {path} ({e.strerror})")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        die(f"--body-file is not valid UTF-8: {path}")

def cmd_write(a):
    body = a.body
    if a.body_file: body = read_body_file(a.body_file)
    if body is None and stdin_has_data(): body = sys.stdin.read() or None
    media = [os.path.abspath(os.path.expanduser(m)) for m in (a.media or [])]
    for m in media:
        if not os.path.exists(m): die(f"media file not found: {m}")
        check_media_type(m)
    if a.link: check_link_url(a.link)
    lp = None
    if a.live_photo:
        lp = [os.path.abspath(os.path.expanduser(x)) for x in a.live_photo]
        img_ext = os.path.splitext(lp[0])[1].lower()
        mov_ext = os.path.splitext(lp[1])[1].lower()
        if img_ext not in PHOTO_EXT or mov_ext not in VIDEO_EXT:
            die("--live-photo takes IMAGE then VIDEO (e.g. IMG.heic IMG.mov)")
        for x in lp:
            if not os.path.exists(x): die(f"live-photo file not found: {x}")
    has_loc = a.lat is not None or a.lon is not None
    if has_loc and (a.lat is None or a.lon is None):
        die("--lat and --lon must be given together")
    slim = location_slim(a, has_loc)
    if not (body and body.strip()) and not media and not lp and not has_loc and not a.link:
        die("nothing to write (need --body/--body-file/stdin, --media, --live-photo, "
            "--link, or --lat/--lon)")
    body = body or ""

    when = parse_date(a.date) if a.date else datetime.datetime.now()
    ts = cd(when)
    rtf = txt_to_rtf(body) if body.strip() else None
    title_rtf = txt_to_rtf(a.title) if a.title else None
    entry_uuid = uid()

    if a.dry_run:
        bits = [f"{len(body)} chars"] if body.strip() else []
        if media: bits.append(f"{len(media)} media")
        if lp: bits.append("1 live photo")
        if a.link: bits.append("1 link")
        if has_loc: bits.append(f"location {a.lat:.5f},{a.lon:.5f}")
        # resolve journals as the real write would, so an unknown one fails here too
        if (a.journal or a.add_journal):
            with Snapshot() as c:
                for sel in (a.journal or []) + (a.add_journal or []): resolve_journal(c, sel)
        for j in (a.journal or []) + (a.add_journal or []): bits.append(f"journal {j!r}")
        print(f"DRY RUN: would create entry ({', '.join(bits) or 'empty'}) dated {when:%Y-%m-%d %H:%M}. Nothing written.")
        return
    staged = False
    with Live(allow_live_default=a.live, accept_risk=a.accept_risk) as conn:
        ent, pk = next_pk(conn, "entry")
        conn.execute("""
            insert into ZJOURNALENTRYMO
              (Z_PK, Z_ENT, Z_OPT, ZENTRYTYPE, ZID,
               ZENTRYDATE, ZCREATEDDATE, ZUPDATEDDATE, ZMOMENTDATEFORSORTING,
               ZTEXT, ZTITLE, ZTEXTLENGTH, ZSHOWTITLE,
               ZISDRAFT, ZFLAGGED, ZISUPLOADEDTOCLOUD, ZISREMOVEDFROMCLOUD,
               ZISFULLYREMOVED, ZRECENTLYDELETED, ZISTIP,
               ZMINIMUMSUPPORTEDAPPVERSION, ZMINIMUMSUPPORTEDAPPVERSIONMODE)
            values (?,?,1,'blankEntry',?, ?,?,?,?, ?,?,?,?, 0,?,0,0, 0,0,0, 0,0)""",
            (pk, ent, uid_bytes(entry_uuid), ts, cd_now(), cd_now(), ts,
             rtf, title_rtf, len(body), 1 if a.title else 0, 1 if a.bookmark else 0))

        ordering = []
        idx = 0
        for m in media:
            ext = os.path.splitext(m)[1].lower()
            atype = "video" if ext in VIDEO_EXT else "photo"
            meta = {"date": ts}
            if has_loc:
                meta.update({"latitude": a.lat, "longitude": a.lon})
                if a.place: meta["placeName"] = a.place
            if a.photos_link:
                aid = photos_lookup(m)
                if aid: meta["assetIdentifier"] = aid
                else: print(f"warning: no Photos-library match for {os.path.basename(m)}",
                            file=sys.stderr)
            apk, au = add_asset(conn, pk, entry_uuid, atype, "imagePicker", meta)
            add_file(conn, apk, au, entry_uuid, m, 0, resize=not a.no_resize)
            ordering += [au, idx]; idx += 1

        if lp:
            meta = {"date": ts}
            if a.photos_link:
                aid = photos_lookup(lp[0])
                if aid: meta["assetIdentifier"] = aid
            apk, au = add_asset(conn, pk, entry_uuid, "livePhoto", "imagePicker", meta)
            add_file(conn, apk, au, entry_uuid, lp[0], 0, resize=False, plain_name=True)
            add_file(conn, apk, au, entry_uuid, lp[1], 0, resize=False, plain_name=True)
            ordering += [au, idx]; idx += 1

        if a.link:
            payload = make_link_payload(a.link, a.link_title)
            apk, au = add_asset(conn, pk, entry_uuid, "link", "shareSheet",
                                {"data": payload, "date": cd_now()})
            conn.execute("update ZJOURNALENTRYASSETMO set ZCONTENTTYPE='unknown' where Z_PK=?",
                         (apk,))
            ordering += [au, idx]; idx += 1

        if has_loc:
            visit = {"latitude": a.lat, "longitude": a.lon,
                     "createdDate": cd_now(), "visitStartTime": ts, "visitEndTime": ts,
                     "horizontalAccuracy": 0, "confidenceLevel": 0,
                     "assetSource": "locationPicker"}
            if a.place: visit["placeName"] = a.place
            if a.city:  visit["city"] = a.city
            _, au = add_asset(conn, pk, entry_uuid, "multiPinMap", "locationPicker",
                              {"revision": 2, "visitsData": [visit]}, slim=slim)
            ordering += [au, idx]

        if ordering:
            conn.execute("update ZJOURNALENTRYMO set ZASSETORDERING=? where Z_PK=?",
                         (json.dumps(ordering).encode(), pk))

        # membership is many-to-many: every --journal/--add-journal adds one
        for sel in (a.journal or []) + (a.add_journal or []):
            jpk, jname, jdefault = resolve_journal(conn, sel)
            if not jdefault:
                conn.execute("insert or ignore into Z_5JOURNALS (Z_5ENTRIES, Z_6JOURNALS) values (?,?)",
                             (pk, jpk))
                staged = True
        # no --journal: the entry lands in the default journal implicitly (no join
        # row), matching how most native entries are stored

    bits = [f"{len(body)} chars"] if body.strip() else []
    if media: bits.append(f"{len(media)} media")
    if lp: bits.append("1 live photo")
    if a.link: bits.append("1 link")
    if has_loc: bits.append(f"location {a.lat:.5f},{a.lon:.5f}")
    for j in (a.journal or []) + (a.add_journal or []): bits.append(f"journal {j!r}")
    print(f"Created entry {pk} ({', '.join(bits) or 'empty'}) dated {when:%Y-%m-%d %H:%M}.")
    if staged:
        print("warning: this is a Mac-local staging membership. "
              "Run `sync-journals --journal NAME` for the native Journal.app "
              "steps required to sync it to other devices.", file=sys.stderr)

def ordering_append(conn, pk, new_uuids):
    """Append asset UUIDs to ZASSETORDERING, preserving existing order."""
    row = conn.execute("select ZASSETORDERING from ZJOURNALENTRYMO where Z_PK=?", (pk,)).fetchone()
    cur = []
    if row and row[0]:
        try: cur = json.loads(row[0])
        except Exception: cur = []
    nxt = (max([cur[i] for i in range(1, len(cur), 2)], default=-1)) + 1
    for u in new_uuids:
        cur += [u, nxt]; nxt += 1
    conn.execute("update ZJOURNALENTRYMO set ZASSETORDERING=? where Z_PK=?",
                 (json.dumps(cur).encode(), pk))

def ordering_drop(conn, pk, gone_uuids):
    row = conn.execute("select ZASSETORDERING from ZJOURNALENTRYMO where Z_PK=?", (pk,)).fetchone()
    if not row or not row[0]: return
    try: cur = json.loads(row[0])
    except Exception: return
    out = []
    for i in range(0, len(cur) - 1, 2):
        if cur[i] not in gone_uuids:
            out += [cur[i], cur[i + 1]]
    conn.execute("update ZJOURNALENTRYMO set ZASSETORDERING=? where Z_PK=?",
                 (json.dumps(out).encode(), pk))

MEDIA_TYPES = {"photo", "video", "livePhoto"}

def remove_assets(conn, entry_pk, entry_uuid, asset_pks):
    """Remove media asset rows, their file rows, their files, and their ordering slots."""
    gone_uuids = []
    for apk in asset_pks:
        r = conn.execute("""select Z_PK, ZID, ZASSETTYPE from ZJOURNALENTRYASSETMO
                            where Z_PK=? and ZENTRY=?""", (apk, entry_pk)).fetchone()
        if not r:
            die(f"entry {entry_pk} has no asset {apk} (see `show {entry_pk} --json` for ids)")
        if r["ZASSETTYPE"] not in MEDIA_TYPES:
            die(f"asset {apk} is type {r['ZASSETTYPE']!r}, not media; refusing to remove it")
        au = u_str(r["ZID"])
        conn.execute("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", (apk,))
        conn.execute("delete from ZJOURNALENTRYASSETMO where Z_PK=?", (apk,))
        gone_uuids.append(au)
        if entry_uuid and au:
            schedule_removal(os.path.join(attach_dir(), entry_uuid, au))
    if gone_uuids: ordering_drop(conn, entry_pk, gone_uuids)
    return len(gone_uuids)

def cmd_edit(a):
    body = a.body
    if a.body_file: body = read_body_file(a.body_file)
    if body is None and stdin_has_data(): body = sys.stdin.read() or None

    media = [os.path.abspath(os.path.expanduser(m)) for m in (a.add_media or [])]
    for m in media:
        if not os.path.exists(m): die(f"media file not found: {m}")
        check_media_type(m)
    if a.add_link: check_link_url(a.add_link)
    has_loc = a.lat is not None or a.lon is not None
    if has_loc and (a.lat is None or a.lon is None):
        die("--lat and --lon must be given together")
    slim = location_slim(a, has_loc)
    bookmark = True if a.bookmark else (False if a.no_bookmark else None)
    touches_text = body is not None or a.title is not None
    if not any([touches_text, media, has_loc, a.clear_location, a.add_link,
                a.remove_media, a.remove_all_media, a.journal, a.add_journal, a.remove_journal,
                a.date is not None, bookmark is not None]):
        die("nothing to change")
    # --journal replaces every membership; --add-journal/--remove-journal change one
    # at a time. Together the intent is ambiguous, so refuse rather than guess.
    if a.journal and (a.add_journal or a.remove_journal):
        die("--journal replaces every membership; use it alone, or use only "
            "--add-journal/--remove-journal to change memberships one at a time")

    # Parse the date up front so --dry-run rejects a bad one too.
    new_ts = cd(parse_date(a.date)) if a.date is not None else None

    def validate(conn):
        """Every refusal the real edit can make, checked read-only: --dry-run
        runs it on a snapshot, the real edit inside its transaction before
        changing anything."""
        row = conn.execute("""select Z_PK, ZID, ZMERGEABLEATTRIBUTES
                              from ZJOURNALENTRYMO where Z_PK=?""", (a.id,)).fetchone()
        if not row: die(f"no entry with id {a.id}")
        if touches_text and row["ZMERGEABLEATTRIBUTES"] is not None and not a.force:
            die(f"entry {a.id} carries a ZMERGEABLEATTRIBUTES CRDT (Journal's merge copy\n"
                "  of the text). Editing ZTEXT alone can be reverted or duplicated on sync.\n"
                "  Change location/media/date/bookmark freely, edit the text in Journal.app,\n"
                "  or pass --force to write ZTEXT anyway.")
        if (a.journal or a.add_journal or a.remove_journal) and row["ZMERGEABLEATTRIBUTES"] is not None:
            die(f"entry {a.id} already has Journal merge attributes. A direct journal move\n"
                "  would be Mac-local and can be reverted by iCloud. Move it in Journal.app.")
        if not a.remove_all_media:
            for apk in a.remove_media or []:
                r = conn.execute("""select ZASSETTYPE from ZJOURNALENTRYASSETMO
                                    where Z_PK=? and ZENTRY=?""", (apk, a.id)).fetchone()
                if not r:
                    die(f"entry {a.id} has no asset {apk} (see `show {a.id} --json` for ids)")
                if r["ZASSETTYPE"] not in MEDIA_TYPES:
                    die(f"asset {apk} is type {r['ZASSETTYPE']!r}, not media; refusing to remove it")
        # resolve every name before writing, so a typo can't half-apply a change
        moves = [resolve_journal(conn, sel) for sel in a.journal or []]
        adds = [resolve_journal(conn, sel) for sel in a.add_journal or []]
        removes = [resolve_journal(conn, sel) for sel in a.remove_journal or []]
        if any(jdefault for _, _, jdefault in adds):
            die("the default journal holds every entry that is in no other journal; "
                "there is no membership to add")
        return row, moves, adds, removes

    if a.dry_run:
        with Snapshot() as c:
            validate(c)
        print(f"DRY RUN: would update entry {a.id}. Nothing written.")
        return

    staged = False
    with Live(allow_live_default=a.live, accept_risk=a.accept_risk) as conn:
        row, moves, adds, removes = validate(conn)
        entry_uuid = u_str(row["ZID"])

        sets, vals = [], []
        if body is not None:
            sets += ["ZTEXT=?", "ZTEXTLENGTH=?"]; vals += [txt_to_rtf(body) if body.strip() else None, len(body)]
        if a.title is not None:
            sets += ["ZTITLE=?", "ZSHOWTITLE=?"]
            vals += [txt_to_rtf(a.title) if a.title.strip() else None, 1 if a.title.strip() else 0]
        if new_ts is not None:
            sets += ["ZENTRYDATE=?", "ZMOMENTDATEFORSORTING=?"]; vals += [new_ts, new_ts]
        if bookmark is not None:
            sets += ["ZFLAGGED=?"]; vals += [1 if bookmark else 0]
        sets += ["ZUPDATEDDATE=?", "ZENTRYDATAUPDATEDATE=?", "ZISUPLOADEDTOCLOUD=0"]
        vals += [cd_now(), cd_now()]
        conn.execute(f"update ZJOURNALENTRYMO set {', '.join(sets)} where Z_PK=?", (*vals, a.id))

        if a.clear_location or has_loc:
            gone = []
            for r in conn.execute("""select Z_PK, ZID from ZJOURNALENTRYASSETMO
                                     where ZENTRY=? and ZASSETTYPE in ('multiPinMap','genericMap')""", (a.id,)):
                gone.append(u_str(r["ZID"]))
                conn.execute("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", (r["Z_PK"],))
                conn.execute("delete from ZJOURNALENTRYASSETMO where Z_PK=?", (r["Z_PK"],))
            if gone: ordering_drop(conn, a.id, gone)

        removed = 0
        if a.remove_all_media:
            pks = [r[0] for r in conn.execute(
                """select Z_PK from ZJOURNALENTRYASSETMO
                   where ZENTRY=? and ZASSETTYPE in ('photo','video','livePhoto')""", (a.id,))]
            removed = remove_assets(conn, a.id, entry_uuid, pks)
        elif a.remove_media:
            removed = remove_assets(conn, a.id, entry_uuid, a.remove_media)

        added = []
        for m in media:
            ext = os.path.splitext(m)[1].lower()
            atype = "video" if ext in VIDEO_EXT else "photo"
            meta = {"date": cd_now()}
            if a.photos_link:
                aid = photos_lookup(m)
                if aid: meta["assetIdentifier"] = aid
                else: print(f"warning: no Photos-library match for {os.path.basename(m)}",
                            file=sys.stderr)
            apk, au = add_asset(conn, a.id, entry_uuid, atype, "imagePicker", meta)
            add_file(conn, apk, au, entry_uuid, m, 0, resize=not a.no_resize)
            added.append(au)

        if has_loc:
            ets = conn.execute("select ZENTRYDATE from ZJOURNALENTRYMO where Z_PK=?", (a.id,)).fetchone()[0]
            visit = {"latitude": a.lat, "longitude": a.lon, "createdDate": cd_now(),
                     "visitStartTime": ets, "visitEndTime": ets,
                     "horizontalAccuracy": 0, "confidenceLevel": 0,
                     "assetSource": "locationPicker"}
            if a.place: visit["placeName"] = a.place
            if a.city:  visit["city"] = a.city
            _, au = add_asset(conn, a.id, entry_uuid, "multiPinMap", "locationPicker",
                              {"revision": 2, "visitsData": [visit]}, slim=slim)
            added.append(au)

        if a.add_link:
            payload = make_link_payload(a.add_link, a.link_title)
            apk, au = add_asset(conn, a.id, entry_uuid, "link", "shareSheet",
                                {"data": payload, "date": cd_now()})
            conn.execute("update ZJOURNALENTRYASSETMO set ZCONTENTTYPE='unknown' where Z_PK=?",
                         (apk,))
            added.append(au)

        if added: ordering_append(conn, a.id, added)

        # journal names were resolved in validate(), before anything changed
        if moves:
            conn.execute("delete from Z_5JOURNALS where Z_5ENTRIES=?", (a.id,))
            for jpk, _, jdefault in moves:
                if not jdefault:
                    conn.execute("insert or ignore into Z_5JOURNALS (Z_5ENTRIES, Z_6JOURNALS) values (?,?)",
                                 (a.id, jpk))
                    staged = True
        for jpk, _, _ in adds:
            conn.execute("insert or ignore into Z_5JOURNALS (Z_5ENTRIES, Z_6JOURNALS) values (?,?)",
                         (a.id, jpk))
            staged = True
        for jpk, _, _ in removes:
            conn.execute("delete from Z_5JOURNALS where Z_5ENTRIES=? and Z_6JOURNALS=?", (a.id, jpk))

    bits = []
    if body is not None: bits.append("body")
    if a.title is not None: bits.append("title")
    if a.date is not None: bits.append("date")
    if bookmark is not None: bits.append("bookmark=" + str(bookmark).lower())
    if a.clear_location and not has_loc: bits.append("location cleared")
    if has_loc: bits.append("location set")
    if media: bits.append(f"{len(media)} media added")
    if a.remove_media or a.remove_all_media: bits.append(f"{removed} media removed")
    if a.add_link: bits.append("1 link added")
    if a.journal: bits.append("moved to journal " + ", ".join(repr(j) for j in a.journal))
    for j in a.add_journal or []: bits.append(f"added to {j!r}")
    for j in a.remove_journal or []: bits.append(f"removed from {j!r}")
    print(f"Updated entry {a.id} ({', '.join(bits)}).")
    if staged:
        print("warning: this is a Mac-local staging membership. "
              "Run `sync-journals --journal NAME` for the native Journal.app "
              "steps required to sync it to other devices.", file=sys.stderr)

def cmd_delete(a):
    if a.dry_run:
        with Snapshot() as c:
            if not c.execute("select Z_PK from ZJOURNALENTRYMO where Z_PK=?", (a.id,)).fetchone():
                die(f"no entry with id {a.id}")
        print(f"DRY RUN: would {'hard' if a.hard else 'soft'}-delete entry {a.id}. Nothing written.")
        return
    with Live(allow_live_default=a.live, accept_risk=a.accept_risk) as conn:
        row = conn.execute("""select Z_PK, ZID, ZISUPLOADEDTOCLOUD
                              from ZJOURNALENTRYMO where Z_PK=?""", (a.id,)).fetchone()
        if not row: die(f"no entry with id {a.id}")
        if a.hard and row["ZISUPLOADEDTOCLOUD"] and not a.force:
            die(f"entry {a.id} has synced to iCloud. A local hard delete does not\n"
                "  tombstone the CloudKit record, and the entry RESURRECTS on the next\n"
                "  sync (verified). Use a soft delete (no --hard), delete it in\n"
                "  Journal.app, or pass --force if you accept the resurrection risk.")
        if a.hard:
            apks = [r[0] for r in conn.execute(
                "select Z_PK from ZJOURNALENTRYASSETMO where ZENTRY=?", (a.id,))]
            for apk in apks:
                conn.execute("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", (apk,))
            conn.execute("delete from ZJOURNALENTRYASSETMO where ZENTRY=?", (a.id,))
            conn.execute("delete from Z_5JOURNALS where Z_5ENTRIES=?", (a.id,))
            conn.execute("delete from ZJOURNALENTRYMO where Z_PK=?", (a.id,))
            eu = u_str(row["ZID"])
            if eu:
                schedule_removal(os.path.join(attach_dir(), eu))
            what = f"hard-deleted (with {len(apks)} assets)"
        else:
            conn.execute("""update ZJOURNALENTRYMO
                            set ZRECENTLYDELETED=1, ZRECENTLYDELETEDENTRYDATE=?, ZUPDATEDDATE=?,
                                ZISUPLOADEDTOCLOUD=0
                            where Z_PK=?""", (cd_now(), cd_now(), a.id))
            what = "marked deleted (Recently Deleted); deletion will sync"
    print(f"Entry {a.id} {what}.")

def cmd_deleted(a):
    with Snapshot() as c:
        rows = c.execute("""select Z_PK, ZID, ZENTRYDATE, ZRECENTLYDELETEDENTRYDATE,
                                   ZISUPLOADEDTOCLOUD, ZTITLE, ZTEXT
                            from ZJOURNALENTRYMO
                            where coalesce(ZRECENTLYDELETED,0)=1
                              and coalesce(ZISFULLYREMOVED,0)=0
                            order by ZRECENTLYDELETEDENTRYDATE desc""").fetchall()
        titles = rtf_batch([r["ZTITLE"] for r in rows])
        texts  = rtf_batch([r["ZTEXT"] for r in rows])
    out = []
    for r, ti, tx in zip(rows, titles, texts):
        dt = (datetime.datetime.fromtimestamp(r["ZENTRYDATE"] + EPOCH)
              .isoformat(sep=" ", timespec="seconds")) if r["ZENTRYDATE"] is not None else None
        dd = (datetime.datetime.fromtimestamp(r["ZRECENTLYDELETEDENTRYDATE"] + EPOCH)
              .isoformat(sep=" ", timespec="seconds")) if r["ZRECENTLYDELETEDENTRYDATE"] else None
        out.append({"id": r["Z_PK"], "date": dt, "deleted": dd,
                    "title": ti, "text": tx, "synced": bool(r["ZISUPLOADEDTOCLOUD"])})
    if a.json:
        print(json.dumps(out, indent=2, ensure_ascii=False)); return
    if not out:
        print("Recently Deleted is empty."); return
    for e in out:
        head = e["title"] or (e["text"].split("\n")[0][:50] if e["text"] else "(empty)")
        print(f"{e['id']:>5}  entry {str(e['date'])[:10]}  deleted {str(e['deleted'])[:16]}  {head}")
    print(f"\n{len(out)} entr{'y' if len(out)==1 else 'ies'} in Recently Deleted."
          "  restore <id> brings one back; they purge ~30 days after deletion.")

def cmd_restore(a):
    if a.dry_run:
        print(f"DRY RUN: would restore entry {a.id}. Nothing written.")
        return
    with Live(allow_live_default=a.live, accept_risk=a.accept_risk) as conn:
        row = conn.execute("""select Z_PK, ZRECENTLYDELETED from ZJOURNALENTRYMO
                              where Z_PK=?""", (a.id,)).fetchone()
        if not row: die(f"no entry with id {a.id}")
        if not row["ZRECENTLYDELETED"]:
            die(f"entry {a.id} is not in Recently Deleted")
        conn.execute("""update ZJOURNALENTRYMO
                        set ZRECENTLYDELETED=0, ZRECENTLYDELETEDENTRYDATE=NULL,
                            ZUPDATEDDATE=?, ZISUPLOADEDTOCLOUD=0
                        where Z_PK=?""", (cd_now(), a.id))
    print(f"Entry {a.id} restored; the restore will sync.")

def cmd_empty(a):
    if a.dry_run:
        with Snapshot() as c:
            n = c.execute("""select count(*) from ZJOURNALENTRYMO
                             where coalesce(ZRECENTLYDELETED,0)=1
                               and coalesce(ZISFULLYREMOVED,0)=0""").fetchone()[0]
        print(f"DRY RUN: would consider {n} Recently Deleted entr{'y' if n==1 else 'ies'}. Nothing written.")
        return
    with Live(allow_live_default=a.live, accept_risk=a.accept_risk) as conn:
        rows = conn.execute("""select Z_PK, ZID, ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO
                               where coalesce(ZRECENTLYDELETED,0)=1
                                 and coalesce(ZISFULLYREMOVED,0)=0""").fetchall()
        purged = skipped = 0
        for r in rows:
            if r["ZISUPLOADEDTOCLOUD"] and not a.force:
                skipped += 1; continue
            eu = u_str(r["ZID"])
            for (apk,) in conn.execute("select Z_PK from ZJOURNALENTRYASSETMO where ZENTRY=?",
                                       (r["Z_PK"],)):
                conn.execute("delete from ZJOURNALENTRYASSETFILEATTACHMENTMO where ZASSET=?", (apk,))
            conn.execute("delete from ZJOURNALENTRYASSETMO where ZENTRY=?", (r["Z_PK"],))
            conn.execute("delete from Z_5JOURNALS where Z_5ENTRIES=?", (r["Z_PK"],))
            conn.execute("delete from ZJOURNALENTRYMO where Z_PK=?", (r["Z_PK"],))
            if eu:
                schedule_removal(os.path.join(attach_dir(), eu))
            purged += 1
    msg = f"Purged {purged} entr{'y' if purged==1 else 'ies'}."
    if skipped:
        msg += (f" Skipped {skipped} synced entr{'y' if skipped==1 else 'ies'}:"
                " a local purge of synced entries resurrects them from iCloud."
                " Empty Recently Deleted in Journal.app instead (or --force to purge anyway).")
    print(msg)

def cmd_sync_journals(a):
    def selected_rows(conn):
        if a.journal:
            pk, name, is_default = resolve_journal(conn, a.journal)
            if is_default:
                die("the default journal has no custom membership to audit")
            return [{"pk": pk, "name": name, "default": False}]
        return [j for j in journal_rows(conn) if not j["default"]]

    with Snapshot() as conn:
        rows = selected_rows(conn)
        repairs = []
        for j in rows:
            count = conn.execute("""select count(*) from Z_5JOURNALS j
                                    join ZJOURNALENTRYMO e on e.Z_PK=j.Z_5ENTRIES
                                    where j.Z_6JOURNALS=?
                                      and e.ZMERGEABLEATTRIBUTES is null
                                      and coalesce(e.ZISFULLYREMOVED,0)=0
                                      and coalesce(e.ZRECENTLYDELETED,0)=0""",
                                 (j["pk"],)).fetchone()[0]
            if count:
                repairs.append((j, count))
    if not repairs:
        print("No Mac-local custom-journal memberships found.")
        return
    print("Mac-local memberships that require finalization in Journal.app:")
    for journal, count in repairs:
        print(f"  {journal['name']}: {count} entr{'y' if count == 1 else 'ies'}")
    print("""
Direct database relationships do not contain Journal's per-entry iCloud merge data.
For each journal above:
  1. In Journal.app, create a new final journal with a different name.
  2. Open the staging journal, then choose Select Entries > Select All.
  3. Choose Move / Choose Journals and select the new final journal.
  4. Wait until the staging journal shows 0 entries and iCloud finishes syncing.

This command is read-only. --live and --dry-run are accepted for compatibility.""")

def cmd_repair_locations(a):
    """Undo the ZISHIDDEN=1 map assets written by 1.2.0's --location-presentation off.

    Journal reads such an asset as absent, so the entry shows no map AND no
    place — but the coordinates are still in the row, so this repairs in place
    rather than needing a re-import.
    """
    if a.to not in ("small", "large"):
        die("--to must be small or large")
    slim = 1 if a.to == "small" else 0
    find = """select Z_PK, ZENTRY from ZJOURNALENTRYASSETMO
              where ZASSETTYPE='multiPinMap' and coalesce(ZISHIDDEN,0)=1
              order by ZENTRY"""
    if a.dry_run:
        with Snapshot() as c:
            rows = c.execute(find).fetchall()
        entries = {r["ZENTRY"] for r in rows}
        print(f"DRY RUN: would repair {len(rows)} hidden map asset(s) across "
              f"{len(entries)} entr{'y' if len(entries) == 1 else 'ies'} "
              f"to '{a.to}'. Nothing written.")
        return
    with Live(allow_live_default=a.live, accept_risk=a.accept_risk) as conn:
        rows = conn.execute(find).fetchall()
        entries = {r["ZENTRY"] for r in rows}
        for r in rows:
            # The asset carries its own upload flag and Journal's sync engine
            # honors it, so clearing the entry's alone would leave the fix
            # local -- other devices would keep the hidden map. Not
            # ZUPDATEDDATE: assets only gained that column on newer stores.
            conn.execute("""update ZJOURNALENTRYASSETMO
                            set ZISHIDDEN=0, ZISSLIM=?, ZISUPLOADEDTOCLOUD=0
                            where Z_PK=?""",
                         (slim, r["Z_PK"]))
        # Re-upload the entries so the corrected assets reach the other devices.
        for epk in entries:
            conn.execute("""update ZJOURNALENTRYMO
                            set ZUPDATEDDATE=?, ZENTRYDATAUPDATEDATE=?, ZISUPLOADEDTOCLOUD=0
                            where Z_PK=?""", (cd_now(), cd_now(), epk))
    if not rows:
        print("No hidden map assets found. Nothing to repair.")
        return
    print(f"Repaired {len(rows)} map asset(s) across {len(entries)} "
          f"entr{'y' if len(entries) == 1 else 'ies'} to '{a.to}'.")

def cmd_sandbox(a):
    """Seed a throwaway store. --from lets tests run off a backup without FDA."""
    src = os.path.expanduser(a.source) if a.source else DEFAULT_DB
    if not os.path.exists(src):
        die(f"source store not found: {src}")
    os.makedirs(a.dir, exist_ok=True)
    base = "moments.sqlite"
    dst = os.path.join(a.dir, base)
    if os.path.realpath(src) == os.path.realpath(dst):
        die(f"sandbox --from and --dir name the same store: {src}")
    # Copy beside the destination and swap it in only once the copy is good,
    # so a failed copy never costs the store that was already there.
    tmp = f"{dst}.journal-cli-{uid()}"
    try:
        sqlite_backup(src, tmp)
    except sqlite3.Error as e:
        if os.path.exists(tmp): os.remove(tmp)
        if not os.access(src, os.R_OK):
            die(f"permission denied reading {src}\n"
                "  Grant Full Disk Access, or seed from a backup with --from.")
        die(f"could not copy {src}: {e}")
    for suf in ("-wal", "-shm"):
        if os.path.exists(dst + suf): os.remove(dst + suf)
    os.replace(tmp, dst)
    os.makedirs(os.path.join(a.dir, "Attachments"), exist_ok=True)
    print(os.path.join(a.dir, base))

def cmd_doctor(a):
    ok = True
    print(f"store    {DB}")
    if not os.path.exists(DB):
        print("         NOT FOUND"); sys.exit(1)
    try:
        open(DB, "rb").read(16)
        print(f"         readable, {os.path.getsize(DB)/1e6:.1f} MB")
    except PermissionError:
        print("         PERMISSION DENIED - grant Full Disk Access"); ok = False
    print(f"attach   {attach_dir()}  " + ("ok" if os.path.isdir(attach_dir()) else "missing"))
    print("textutil " + ("found" if shutil.which("textutil") else "MISSING"))
    print("Journal  " + ("RUNNING (quit before writing)" if journal_running() else "not running"))
    if ok:
        with Snapshot() as c:
            print(f"\nRead {len(fetch(c))} entries. All good.")
    sys.exit(0 if ok else 1)


def main():
    global DB
    p = argparse.ArgumentParser(prog="journal-cli", description=__doc__.splitlines()[0])
    p.add_argument("--db", default=os.environ.get("JOURNAL_DB", DEFAULT_DB))
    p.add_argument("--version", action="version", version=f"journal-cli {VERSION}")
    sub = p.add_subparsers(dest="cmd", required=True)

    def readopts(x):
        x.add_argument("--json", action="store_true")
        x.add_argument("--limit", type=int)
        x.add_argument("--full", action="store_true")

    l = sub.add_parser("list"); readopts(l)
    l.add_argument("--since"); l.add_argument("--until")
    l.add_argument("--include-empty", action="store_true"); l.set_defaults(func=cmd_list)

    s = sub.add_parser("show"); s.add_argument("id", type=int)
    s.add_argument("--json", action="store_true"); s.set_defaults(func=cmd_show)

    f = sub.add_parser("search"); f.add_argument("query"); readopts(f); f.set_defaults(func=cmd_search)

    e = sub.add_parser("export"); e.add_argument("--dir", required=True)
    e.add_argument("--format", choices=["md", "json"], default="md"); e.set_defaults(func=cmd_export)

    j = sub.add_parser("journals", help="list journals")
    j.add_argument("--json", action="store_true"); j.set_defaults(func=cmd_journals)

    sub.add_parser("stats").set_defaults(func=cmd_stats)
    sub.add_parser("doctor").set_defaults(func=cmd_doctor)

    w = sub.add_parser("write", help="create an entry")
    w.add_argument("--title"); w.add_argument("--body"); w.add_argument("--body-file")
    w.add_argument("--date"); w.add_argument("--bookmark", action="store_true")
    w.add_argument("--media", nargs="+", metavar="PATH", help="photos or videos to attach")
    w.add_argument("--live-photo", nargs=2, metavar=("IMAGE", "VIDEO"),
                   help="attach a Live Photo as an image + video pair")
    w.add_argument("--photos-link", action="store_true",
                   help="link media back to the Photos library (assetIdentifier)")
    w.add_argument("--no-resize", action="store_true",
                   help="copy images as-is instead of downscaling to Journal's ~6MP")
    w.add_argument("--lat", type=float); w.add_argument("--lon", type=float)
    w.add_argument("--place", help="place name for the location pin")
    w.add_argument("--city")
    w.add_argument("--location-presentation", choices=["off", "small", "large"],
                   help="show the location in the entry as a small or large map "
                        "(default: small); off is not supported, see --help output")
    w.add_argument("--link", metavar="URL", help="attach a web link")
    w.add_argument("--link-title", help="title for --link (default: none)")
    w.add_argument("--journal", action="append",
                   help="journal name or id (default: the app's default journal); repeat for several")
    w.add_argument("--add-journal", action="append", metavar="JOURNAL",
                   help="same as --journal: add a membership (repeatable)")
    w.add_argument("--dry-run", dest="dry_run", action="store_true")
    w.add_argument("--accept-risk", dest="accept_risk", action="store_true")
    w.add_argument("--live", action="store_true", help="allow writing to the real store")
    w.set_defaults(func=cmd_write)

    ed = sub.add_parser("edit", help="modify an existing entry")
    ed.add_argument("id", type=int)
    ed.add_argument("--title"); ed.add_argument("--body"); ed.add_argument("--body-file")
    ed.add_argument("--date")
    ed.add_argument("--bookmark", action="store_true")
    ed.add_argument("--no-bookmark", action="store_true")
    ed.add_argument("--add-media", nargs="+", metavar="PATH")
    ed.add_argument("--photos-link", action="store_true")
    ed.add_argument("--no-resize", action="store_true")
    ed.add_argument("--remove-media", nargs="+", type=int, metavar="ASSET_ID",
                    help="remove media assets by id (ids shown in `show <id>`)")
    ed.add_argument("--remove-all-media", action="store_true")
    ed.add_argument("--lat", type=float); ed.add_argument("--lon", type=float)
    ed.add_argument("--place"); ed.add_argument("--city")
    ed.add_argument("--location-presentation", choices=["off", "small", "large"],
                    help="show the replacement location as a small or large map "
                         "(default: small); off is not supported")
    ed.add_argument("--clear-location", action="store_true")
    ed.add_argument("--add-link", metavar="URL")
    ed.add_argument("--link-title")
    ed.add_argument("--journal", action="append",
                    help="move the entry to this journal (name or id), replacing every "
                         "membership; repeat to land in several")
    ed.add_argument("--add-journal", action="append", metavar="JOURNAL",
                    help="add a membership, leaving the others alone (repeatable)")
    ed.add_argument("--remove-journal", action="append", metavar="JOURNAL",
                    help="drop one membership (repeatable)")
    ed.add_argument("--force", action="store_true",
                    help="edit text even when the entry has a CRDT copy")
    ed.add_argument("--dry-run", dest="dry_run", action="store_true")
    ed.add_argument("--accept-risk", dest="accept_risk", action="store_true")
    ed.add_argument("--live", action="store_true")
    ed.set_defaults(func=cmd_edit)

    dl = sub.add_parser("deleted", help="list Recently Deleted entries")
    dl.add_argument("--json", action="store_true"); dl.set_defaults(func=cmd_deleted)

    rs = sub.add_parser("restore", help="restore an entry from Recently Deleted")
    rs.add_argument("id", type=int)
    rs.add_argument("--dry-run", dest="dry_run", action="store_true")
    rs.add_argument("--accept-risk", dest="accept_risk", action="store_true")
    rs.add_argument("--live", action="store_true")
    rs.set_defaults(func=cmd_restore)

    em = sub.add_parser("empty", help="purge Recently Deleted (never-synced entries only)")
    em.add_argument("--force", action="store_true",
                    help="also purge synced entries (they may resurrect from iCloud)")
    em.add_argument("--dry-run", dest="dry_run", action="store_true")
    em.add_argument("--accept-risk", dest="accept_risk", action="store_true")
    em.add_argument("--live", action="store_true"); em.set_defaults(func=cmd_empty)

    sj = sub.add_parser("sync-journals",
                        help="audit Mac-local memberships and print native repair steps")
    sj.add_argument("--journal", help="journal name or id (default: all custom journals)")
    sj.add_argument("--dry-run", dest="dry_run", action="store_true")
    sj.add_argument("--accept-risk", dest="accept_risk", action="store_true")
    sj.add_argument("--live", action="store_true")
    sj.set_defaults(func=cmd_sync_journals)

    rl = sub.add_parser("repair-locations",
                        help="restore map assets written with --location-presentation off")
    rl.add_argument("--to", choices=["small", "large"], default="small",
                    help="map size to restore them to (default: small)")
    rl.add_argument("--dry-run", action="store_true")
    rl.add_argument("--accept-risk", action="store_true")
    rl.add_argument("--live", action="store_true")
    rl.set_defaults(func=cmd_repair_locations)

    d = sub.add_parser("delete"); d.add_argument("id", type=int)
    d.add_argument("--hard", action="store_true")
    d.add_argument("--dry-run", dest="dry_run", action="store_true")
    d.add_argument("--accept-risk", dest="accept_risk", action="store_true")
    d.add_argument("--live", action="store_true")
    d.add_argument("--force", action="store_true",
                   help="hard-delete even a synced entry (it may resurrect from iCloud)")
    d.set_defaults(func=cmd_delete)

    sb = sub.add_parser("sandbox"); sb.add_argument("--dir", required=True)
    sb.add_argument("--from", dest="source", metavar="DB",
                    help="seed from this store instead of the live one (e.g. a backup)")
    sb.set_defaults(func=cmd_sandbox)

    a = p.parse_args()
    DB = os.path.expanduser(a.db)
    a.func(a)


if __name__ == "__main__":
    main()
