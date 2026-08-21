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
BACKUPS = os.path.expanduser("~/Backups/journal-cli")
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

# Journal stores entry dates as FLOATING wall-clock time encoded as UTC: an
# entry made at 11:51 local is stored so UTC-formatting yields 11:51. Encode
# local wall clock on write; format with UTC on read.
def cd_now():
    return cd(datetime.datetime.now())

def cd(dt):
    return dt.timestamp() - dt.astimezone().utcoffset().total_seconds() * -1 - EPOCH if False else         dt.timestamp() + (dt.astimezone().utcoffset().total_seconds()) - EPOCH

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

class Snapshot:
    """Read-only: copy the store aside so the live database is never touched."""
    def __enter__(self):
        if not os.path.exists(DB):
            die(f"store not found at {DB}")
        self.dir = tempfile.mkdtemp(prefix="journal-cli.")
        base = os.path.basename(DB)
        try:
            for suf in ("", "-wal", "-shm"):
                if os.path.exists(DB + suf):
                    shutil.copy2(DB + suf, os.path.join(self.dir, base + suf))
        except PermissionError:
            shutil.rmtree(self.dir, ignore_errors=True)
            die("permission denied. Grant Full Disk Access to this terminal, then relaunch it.")
        self.conn = sqlite3.connect(os.path.join(self.dir, base))
        self.conn.row_factory = sqlite3.Row
        return self.conn
    def __exit__(self, *e):
        try: self.conn.close()
        finally: shutil.rmtree(self.dir, ignore_errors=True)


def backup(reason="write"):
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    d = os.path.join(BACKUPS, f"{ts}-{reason}")
    os.makedirs(d, exist_ok=True)
    base = os.path.basename(DB)
    for suf in ("", "-wal", "-shm"):
        if os.path.exists(DB + suf):
            shutil.copy2(DB + suf, os.path.join(d, base + suf))
    return d


class Live:
    """Read-write against the real store. Guarded."""
    def __init__(self, allow_live_default=False):
        self.is_default = os.path.realpath(DB) == os.path.realpath(DEFAULT_DB)
        self.allow = allow_live_default
    def __enter__(self):
        if self.is_default:
            if not self.allow:
                die("refusing to modify the real Journal store without --live.\n"
                    "  Test against a sandbox first:  journal-cli sandbox --dir DIR")
            if journal_running():
                die("Journal.app is running. Quit it first, then retry.")
            print(f"backup: {backup()}", file=sys.stderr)
        self.conn = sqlite3.connect(DB)
        self.conn.row_factory = sqlite3.Row
        return self.conn
    def __exit__(self, exc_type, *rest):
        if exc_type: self.conn.rollback()
        else: self.conn.commit()
        self.conn.close()


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
        subprocess.run(["textutil", "-convert", "txt"] + names, capture_output=True, timeout=180)
        for i in idxs:
            t = os.path.join(d, f"{i}.txt")
            if os.path.exists(t):
                out[i] = open(t, errors="replace").read().strip()
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
    if max(w, h) > RESIZE_MAX:
        r = subprocess.run(["sips", "-Z", str(RESIZE_MAX), src, "--out", dst],
                           capture_output=True, timeout=120)
        if r.returncode == 0 and os.path.exists(dst):
            return True
    shutil.copy2(src, dst)
    return False

PHOTOS_DB = os.path.expanduser("~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite")

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
        c = sqlite3.connect(f"file:{PHOTOS_DB.replace(' ', '%20')}?mode=ro&immutable=1", uri=True)
        rows = c.execute("""select a.ZUUID, aa.ZORIGINALFILESIZE
                            from ZASSET a
                            join ZADDITIONALASSETATTRIBUTES aa on aa.ZASSET=a.Z_PK
                            where aa.ZORIGINALFILENAME=?""",
                         (os.path.basename(path),)).fetchall()
        c.close()
    except Exception:
        return None
    if len(rows) == 1:
        return f"{rows[0][0]}/L0/001"
    if len(rows) > 1 and os.path.exists(path):
        size = os.path.getsize(path)
        hits = [r for r in rows if r[1] == size]
        if len(hits) == 1:
            return f"{hits[0][0]}/L0/001"
    return None


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

def make_link_payload(url, title=None):
    """base64 NSKeyedArchiver LPLinkMetadata, the format Journal's link assets use."""
    from urllib.parse import urlparse
    u = urlparse(url)
    if u.scheme not in ("http", "https") or not u.netloc:
        die(f"--link needs an absolute http(s) URL, got {url!r}")
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
    dt = datetime.datetime.fromtimestamp(r["ZENTRYDATE"] + EPOCH) if r["ZENTRYDATE"] else None
    return {"id": r["Z_PK"], "uuid": u_str(r["ZID"]),
            "date": dt.isoformat(sep=" ", timespec="seconds") if dt else None,
            "title": ti, "text": tx, "chars": r["ZTEXTLENGTH"] or 0,
            "bookmarked": bool(r["ZFLAGGED"]), "draft": bool(r["ZISDRAFT"]),
            "synced": bool(r["ZISUPLOADEDTOCLOUD"])}

def assets_for(conn, pk):
    rows = conn.execute("""
        select Z_PK, ZID, ZASSETTYPE, ZSOURCE, ZASSETMETADATA
        from ZJOURNALENTRYASSETMO where ZENTRY=? order by Z_PK""", (pk,)).fetchall()
    out = []
    for r in rows:
        m = resolve_meta(r["ZASSETMETADATA"])
        if not isinstance(m, dict): m = {}
        a = {"id": r["Z_PK"], "uuid": u_str(r["ZID"]), "type": r["ZASSETTYPE"],
             "source": r["ZSOURCE"], "files": []}
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
    os.makedirs(a.dir, exist_ok=True)
    with Snapshot() as c:
        ents = fetch(c)
        for e in ents: e["assets"] = assets_for(c, e["id"])
    if a.format == "json":
        p = os.path.join(a.dir, "journal.json")
        json.dump(ents, open(p, "w"), indent=2, ensure_ascii=False)
        print(f"Wrote {len(ents)} entries to {p}"); return
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
                            f"    lat: {p.get('lat')}\n    lon: {p.get('lon')}\n")
            f.write("---\n\n" + e["text"] + "\n")
            files = [x for asset in e["assets"] for x in asset["files"]]
            if files:
                f.write("\n")
                for x in files:
                    f.write(f"![{x['name']}]({x['path']})\n")
    print(f"Wrote {len(ents)} entries to {a.dir}")

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

def journal_rows(conn):
    out = []
    for r in conn.execute("""select Z_PK, ZMERGEABLEATTRIBUTES, ZSORTCATEGORY
                             from ZJOURNALMO where coalesce(ZUSERDELETED,0)=0
                             order by Z_PK"""):
        blob = r["ZMERGEABLEATTRIBUTES"]
        name = "Journal"          # the built-in default has no CRDT blob
        if blob:
            import re as _re
            cand = _re.findall(rb'[\x20-\x7e\xc2-\xf4][\x20-\x7e\x80-\xbf]{2,}', blob)
            cand = [c.decode("utf-8", "replace") for c in cand]
            if "title" in cand:
                i = cand.index("title")
                if i > 0: name = cand[i - 1]
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
    abs_dir = os.path.join(attach_dir(), rel_dir)
    os.makedirs(abs_dir, exist_ok=True)
    fname = f"{uid()}{ext}" if plain_name else f"{uid()}_resized{ext}"
    dst = os.path.join(abs_dir, fname)
    if name == "image" and resize:
        resize_into(src_path, dst)
    else:
        shutil.copy2(src_path, dst)
    ent, pk = next_pk(conn, "file")
    conn.execute("""
        insert into ZJOURNALENTRYASSETFILEATTACHMENTMO
          (Z_PK, Z_ENT, Z_OPT, ZASSET, ZID, ZPARENTID, ZFILEPATH, ZNAME, ZINDEX,
           ZISUPLOADEDTOCLOUD, ZISREMOVEDFROMCLOUD)
        values (?,?,1,?,?,?,?,?,?,0,0)""",
        (pk, ent, asset_pk, uid_bytes(uid()), uid_bytes(asset_uuid),
         os.path.join(rel_dir, fname), name, index))
    return pk

def cmd_write(a):
    body = a.body
    if a.body_file: body = open(a.body_file, errors="replace").read()
    if body is None and stdin_has_data(): body = sys.stdin.read()
    media = [os.path.abspath(os.path.expanduser(m)) for m in (a.media or [])]
    for m in media:
        if not os.path.exists(m): die(f"media file not found: {m}")
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
    if not (body and body.strip()) and not media and not lp and not has_loc and not a.link:
        die("nothing to write (need --body/--body-file/stdin, --media, --live-photo, "
            "--link, or --lat/--lon)")
    body = body or ""

    when = parse_date(a.date) if a.date else datetime.datetime.now()
    ts = cd(when)
    rtf = txt_to_rtf(body) if body.strip() else None
    title_rtf = txt_to_rtf(a.title) if a.title else None
    entry_uuid = uid()

    with Live(allow_live_default=a.live) as conn:
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
                              {"revision": 2, "visitsData": [visit]}, slim=1)
            ordering += [au, idx]

        if ordering:
            conn.execute("update ZJOURNALENTRYMO set ZASSETORDERING=? where Z_PK=?",
                         (json.dumps(ordering).encode(), pk))

        if a.journal:
            jpk, jname, jdefault = resolve_journal(conn, a.journal)
            if not jdefault:
                conn.execute("insert or ignore into Z_5JOURNALS (Z_5ENTRIES, Z_6JOURNALS) values (?,?)",
                             (pk, jpk))
        # no --journal: the entry lands in the default journal implicitly (no join
        # row), matching how most native entries are stored

    bits = [f"{len(body)} chars"] if body.strip() else []
    if media: bits.append(f"{len(media)} media")
    if lp: bits.append("1 live photo")
    if a.link: bits.append("1 link")
    if has_loc: bits.append(f"location {a.lat:.5f},{a.lon:.5f}")
    if a.journal: bits.append(f"journal {a.journal!r}")
    print(f"Created entry {pk} ({', '.join(bits) or 'empty'}) dated {when:%Y-%m-%d %H:%M}.")

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
            d = os.path.join(attach_dir(), entry_uuid, au)
            if os.path.isdir(d): shutil.rmtree(d, ignore_errors=True)
    if gone_uuids: ordering_drop(conn, entry_pk, gone_uuids)
    return len(gone_uuids)

def cmd_edit(a):
    body = a.body
    if a.body_file: body = open(a.body_file, errors="replace").read()
    if body is None and stdin_has_data(): body = sys.stdin.read()

    media = [os.path.abspath(os.path.expanduser(m)) for m in (a.add_media or [])]
    for m in media:
        if not os.path.exists(m): die(f"media file not found: {m}")
    has_loc = a.lat is not None or a.lon is not None
    if has_loc and (a.lat is None or a.lon is None):
        die("--lat and --lon must be given together")
    bookmark = True if a.bookmark else (False if a.no_bookmark else None)
    touches_text = body is not None or a.title is not None
    if not any([touches_text, media, has_loc, a.clear_location, a.add_link,
                a.remove_media, a.remove_all_media, a.journal,
                a.date is not None, bookmark is not None]):
        die("nothing to change")

    with Live(allow_live_default=a.live) as conn:
        row = conn.execute("""select Z_PK, ZID, ZMERGEABLEATTRIBUTES
                              from ZJOURNALENTRYMO where Z_PK=?""", (a.id,)).fetchone()
        if not row: die(f"no entry with id {a.id}")
        entry_uuid = u_str(row["ZID"])

        if touches_text and row["ZMERGEABLEATTRIBUTES"] is not None and not a.force:
            die(f"entry {a.id} carries a ZMERGEABLEATTRIBUTES CRDT (Journal's merge copy\n"
                "  of the text). Editing ZTEXT alone can be reverted or duplicated on sync.\n"
                "  Change location/media/date/bookmark freely, edit the text in Journal.app,\n"
                "  or pass --force to write ZTEXT anyway.")

        sets, vals = [], []
        if body is not None:
            sets += ["ZTEXT=?", "ZTEXTLENGTH=?"]; vals += [txt_to_rtf(body) if body.strip() else None, len(body)]
        if a.title is not None:
            sets += ["ZTITLE=?", "ZSHOWTITLE=?"]
            vals += [txt_to_rtf(a.title) if a.title.strip() else None, 1 if a.title.strip() else 0]
        if a.date is not None:
            ts = cd(parse_date(a.date))
            sets += ["ZENTRYDATE=?", "ZMOMENTDATEFORSORTING=?"]; vals += [ts, ts]
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
                              {"revision": 2, "visitsData": [visit]}, slim=1)
            added.append(au)

        if a.add_link:
            payload = make_link_payload(a.add_link, a.link_title)
            apk, au = add_asset(conn, a.id, entry_uuid, "link", "shareSheet",
                                {"data": payload, "date": cd_now()})
            conn.execute("update ZJOURNALENTRYASSETMO set ZCONTENTTYPE='unknown' where Z_PK=?",
                         (apk,))
            added.append(au)

        if added: ordering_append(conn, a.id, added)

        if a.journal:
            jpk, jname, jdefault = resolve_journal(conn, a.journal)
            conn.execute("delete from Z_5JOURNALS where Z_5ENTRIES=?", (a.id,))
            if not jdefault:
                conn.execute("insert into Z_5JOURNALS (Z_5ENTRIES, Z_6JOURNALS) values (?,?)",
                             (a.id, jpk))

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
    if a.journal: bits.append(f"moved to journal {a.journal!r}")
    print(f"Updated entry {a.id} ({', '.join(bits)}).")

def cmd_delete(a):
    with Live(allow_live_default=a.live) as conn:
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
                d = os.path.join(attach_dir(), eu)
                if os.path.isdir(d): shutil.rmtree(d, ignore_errors=True)
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
              .isoformat(sep=" ", timespec="seconds")) if r["ZENTRYDATE"] else None
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
    with Live(allow_live_default=a.live) as conn:
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
    with Live(allow_live_default=a.live) as conn:
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
                d = os.path.join(attach_dir(), eu)
                if os.path.isdir(d): shutil.rmtree(d, ignore_errors=True)
            purged += 1
    msg = f"Purged {purged} entr{'y' if purged==1 else 'ies'}."
    if skipped:
        msg += (f" Skipped {skipped} synced entr{'y' if skipped==1 else 'ies'}:"
                " a local purge of synced entries resurrects them from iCloud."
                " Empty Recently Deleted in Journal.app instead (or --force to purge anyway).")
    print(msg)

def cmd_sandbox(a):
    """Seed a throwaway store. --from lets tests run off a backup without FDA."""
    src = os.path.expanduser(a.source) if a.source else DEFAULT_DB
    if not os.path.exists(src):
        die(f"source store not found: {src}")
    os.makedirs(a.dir, exist_ok=True)
    base = "moments.sqlite"
    try:
        for suf in ("", "-wal", "-shm"):
            if os.path.exists(src + suf):
                shutil.copy2(src + suf, os.path.join(a.dir, base + suf))
    except PermissionError:
        die(f"permission denied reading {src}\n"
            "  Grant Full Disk Access, or seed from a backup with --from.")
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
    w.add_argument("--link", metavar="URL", help="attach a web link")
    w.add_argument("--link-title", help="title for --link (default: none)")
    w.add_argument("--journal", help="journal name or id (default: the app's default journal)")
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
    ed.add_argument("--clear-location", action="store_true")
    ed.add_argument("--add-link", metavar="URL")
    ed.add_argument("--link-title")
    ed.add_argument("--journal", help="move the entry to this journal (name or id)")
    ed.add_argument("--force", action="store_true",
                    help="edit text even when the entry has a CRDT copy")
    ed.add_argument("--live", action="store_true")
    ed.set_defaults(func=cmd_edit)

    dl = sub.add_parser("deleted", help="list Recently Deleted entries")
    dl.add_argument("--json", action="store_true"); dl.set_defaults(func=cmd_deleted)

    rs = sub.add_parser("restore", help="restore an entry from Recently Deleted")
    rs.add_argument("id", type=int); rs.add_argument("--live", action="store_true")
    rs.set_defaults(func=cmd_restore)

    em = sub.add_parser("empty", help="purge Recently Deleted (never-synced entries only)")
    em.add_argument("--force", action="store_true",
                    help="also purge synced entries (they may resurrect from iCloud)")
    em.add_argument("--live", action="store_true"); em.set_defaults(func=cmd_empty)

    d = sub.add_parser("delete"); d.add_argument("id", type=int)
    d.add_argument("--hard", action="store_true"); d.add_argument("--live", action="store_true")
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
