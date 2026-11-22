#!/usr/bin/env python3
"""Shared reader for a Day One 2 SQLite store.

Day One keeps an unencrypted Core Data store at
  ~/Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents/DayOne.sqlite
with media beside it in DayOnePhotos/ DayOneVideos/ DayOneAudios/, filed by
MD5. Entries carry the timezone they were written in (an archived NSTimeZone
blob), which Day One's own markdown export throws away -- it renders every
date in the exporting machine's zone instead. That loss is the main reason
this module reads the store directly.

Read-only: queries run against a snapshot taken with SQLite's online backup
API, so Day One may stay open. The snapshot lives in a temp folder that is
removed when its connection closes (and at exit, for any left open).
"""
import os, re, sys, json, atexit, shutil, sqlite3, plistlib, tempfile, datetime
from urllib.parse import quote

try:
    import zoneinfo
except ImportError:                                        # pragma: no cover
    zoneinfo = None

CD_EPOCH = 978307200                       # Core Data reference date -> unix
DAYONE_DIR = os.path.expanduser(
    "~/Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents")
DEFAULT_DB = os.path.join(DAYONE_DIR, "DayOne.sqlite")
MEDIA_DIRS = ("DayOnePhotos", "DayOneVideos", "DayOneAudios")

# Day One embeds attachments in the body as ![](dayone-moment://<uuid>) and
# ![](dayone-moment:/audio/<uuid>); body order is the true display order.
MOMENT_RE = re.compile(
    r"!\[\]\(dayone-moment:/*(?:audio/|video/)?([0-9A-Fa-f]{32})\)")
# Real (not backslash-escaped) Day One reference syntax, any kind --
# photo, audio, video, pdfAttachment, ... -- which is never text. Other image
# syntax (an external URL, say) is content and stays in the text.
# A "!" is escaped only by an odd run of backslashes ("\\!" is an escaped
# backslash and a live "!"), so each pattern captures the even run in front
# (group "lead") and keeps it when the reference is removed.
_LEAD = r"(?<!\\)(?P<lead>(?:\\\\)*)"
_MOMENT_ANY_RE = re.compile(_LEAD + r"!\[\]\(dayone-moment:[^)\s]*\)")
_MOMENT_ID = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])")


def die(msg):
    sys.stderr.write("dayone: %s\n" % msg)
    sys.exit(1)


# Temp folders behind open snapshot connections; whatever is still here at
# exit (a crash, a caller that never closed) is removed then.
_SNAPSHOT_DIRS = set()


def _drop_snapshot_dir(d):
    if d:
        _SNAPSHOT_DIRS.discard(d)
        shutil.rmtree(d, ignore_errors=True)


atexit.register(lambda: [_drop_snapshot_dir(d) for d in list(_SNAPSHOT_DIRS)])


class SnapshotConnection(sqlite3.Connection):
    """A read-only connection to a private snapshot; closing it removes the copy.

    Also usable as `with ... as con:`, which (unlike a plain sqlite3
    connection) closes it on the way out.
    """
    snapshot_dir = None

    def close(self):
        try:
            super().close()
        finally:
            _drop_snapshot_dir(self.snapshot_dir)
            self.snapshot_dir = None

    def __exit__(self, *exc):
        self.close()
        return False


def snapshot_connect(src, prefix="snapshot-"):
    """Open a consistent, private, read-only copy of the SQLite store at `src`.

    Copying the database, -wal and -shm one after another can mix
    generations if the app checkpoints in between. The online backup API
    reads every page inside one read transaction of a read-only source
    connection instead, and never writes the source. Raises sqlite3.Error
    (or OSError) when the source cannot be read; the temp folder is removed
    on any failure.
    """
    tmp = tempfile.mkdtemp(prefix=prefix)
    _SNAPSHOT_DIRS.add(tmp)
    try:
        dst = os.path.join(tmp, os.path.basename(src))
        source = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(src)),
                                 uri=True, timeout=5)
        try:
            out = sqlite3.connect(dst)
            try:
                source.backup(out)
                # The copy inherits the source's WAL mode, and a WAL database
                # cannot be opened read-only without its -shm. A private
                # snapshot needs no WAL, so make it a plain rollback-journal file.
                out.execute("pragma journal_mode=delete")
            finally:
                out.close()
        finally:
            source.close()
        con = sqlite3.connect("file:%s?mode=ro" % quote(dst), uri=True,
                              factory=SnapshotConnection)
    except BaseException:
        _drop_snapshot_dir(tmp)
        raise
    con.snapshot_dir = tmp
    con.row_factory = sqlite3.Row
    return con


def connect(db_path=None):
    """A snapshot connection to the Day One store. Close it when done."""
    db_path = db_path or DEFAULT_DB
    if not os.path.exists(db_path):
        die("no Day One store at %s\n  Is Day One installed and synced?" % db_path)
    try:
        return snapshot_connect(db_path, prefix="dayone-")
    except (sqlite3.Error, OSError) as e:
        if not os.access(db_path, os.R_OK):
            die("cannot read %s. Grant Full Disk Access to this terminal, "
                "then relaunch it." % db_path)
        die("could not snapshot %s: %s" % (db_path, e))


def journals(con):
    return [dict(r) for r in con.execute("""
        select j.Z_PK pk, j.ZNAME name,
               (select count(*) from ZENTRY e where e.ZJOURNAL = j.Z_PK) entries
        from ZJOURNAL j order by entries desc, name
    """)]


def resolve_journal(con, name):
    rows = journals(con)
    exact = [r for r in rows if r["name"] == name]
    if exact:
        return exact[0]
    loose = [r for r in rows if name.lower() in (r["name"] or "").lower()]
    if len(loose) == 1:
        return loose[0]
    if len(loose) > 1:
        die("'%s' matches several journals: %s"
            % (name, ", ".join(r["name"] for r in loose)))
    die("no Day One journal named '%s'. Available: %s"
        % (name, ", ".join("%s (%d)" % (r["name"], r["entries"]) for r in rows)))


def timezone_name(blob):
    """Day One stores the entry's zone as an NSKeyedArchiver'd NSTimeZone."""
    if not blob:
        return None
    try:
        objs = plistlib.loads(blob).get("$objects", [])
        # the zone name is the only Region/City string in the archive
        for o in objs:
            if isinstance(o, str) and "/" in o and not o.startswith("$"):
                return o
    except Exception:
        pass
    m = re.search(rb"([A-Za-z_]+/[A-Za-z_/+\-]+)", blob)
    return m.group(1).decode("utf-8", "replace") if m else None


# Day One writes markdown; Apple Journal stores plain text and renders none
# of it, so any syntax left in place shows up literally as "###### " and
# "\\." in the finished entry.
_ESCAPED = re.compile(r"\\([\\`*_{}\[\]()#+\-.!>~|])")
_HEADING = re.compile(r"(?m)^[ \t]{0,3}#{1,6}[ \t]+")
_RULE = re.compile(r"(?m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$")
_BOLD_ITALIC = re.compile(r"(\*{1,3}|_{1,3})(\S(?:.*?\S)?)\1", re.S)
_LINK = re.compile(r'\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
_FENCE_OPEN = re.compile(r"[ \t]*(`{3,})[^`\n]*")
_FENCE_CLOSE = re.compile(r"[ \t]*(`{3,})[ \t]*")
_TITLE_HEADING = re.compile(r"^#{1,6}[ \t]+")


def markdown_to_inline_text(md):
    """Flatten a single-line field such as a title.

    Block rules must not apply: a first line of "---" is a title, not a
    horizontal rule, and "1. first" is a title, not a list item. Mirrors
    journal-cli's `render --inline`.
    """
    if not md:
        return md
    out = _LINK.sub(lambda m: m.group(2) if m.group(1).strip() in ("", m.group(2))
                    else "%s (%s)" % (m.group(1), m.group(2)), md)
    out = _BOLD_ITALIC.sub(lambda m: m.group(2), out)
    out = _ESCAPED.sub(r"\1", out)
    return out.strip()


def _flatten_prose(text):
    out = _RULE.sub("", text)
    out = _HEADING.sub("", out)
    # a link becomes "text (url)", or just the url when the text repeats it
    out = _LINK.sub(lambda m: m.group(2) if m.group(1).strip() in ("", m.group(2))
                    else "%s (%s)" % (m.group(1), m.group(2)), out)
    out = _BOLD_ITALIC.sub(lambda m: m.group(2), out)
    return _ESCAPED.sub(r"\1", out)


def _split_moments(md):
    """(prose, refs): the text without its Day One attachment references.

    Only real references are taken out: not escaped ones, and nothing inside
    a fenced code block, whose content is literal. Blank-line runs left by the
    removal are collapsed in prose only; code keeps its blank lines.
    """
    out, refs, fence, blanks = [], [], 0, 0
    for line in (md or "").split("\n"):
        if fence:
            m = _FENCE_CLOSE.fullmatch(line)
            if m and len(m.group(1)) >= fence:
                fence = 0
            out.append(line)
            continue
        m = _FENCE_OPEN.fullmatch(line)
        if m:
            fence = len(m.group(1))
            blanks = 0
            out.append(line)
            continue
        # Every reference that is removed is also reported, so none can vanish
        # unaccounted for: its 32-hex id when it has one (any kind, including
        # pdfAttachment), else the reference itself, which then reads as
        # missing rather than silently disappearing.
        for m in _MOMENT_ANY_RE.finditer(line):
            ref = m.group(0)[len(m.group("lead")):]
            hexid = _MOMENT_ID.search(ref)
            refs.append(hexid.group(0) if hexid else ref)
        line = _MOMENT_ANY_RE.sub(lambda m: m.group("lead"), line)
        # Same rule as before for prose: runs of empty lines collapse to one
        # (a whitespace-only line is not empty, and stays).
        if line == "":
            blanks += 1
            if blanks > 1:
                continue
        else:
            blanks = 0
        out.append(line)
    return "\n".join(out).strip(), refs


def markdown_to_text(md):
    """Flatten Day One markdown into what a plain-text reader should see.

    Fenced code is kept verbatim: only the fence lines go. A "---" or "# x"
    inside a fence is content, not a rule or heading, so it must not be
    stripped (journal-cli's renderer treats it the same way).
    """
    if not md:
        return md
    # A fence opens with three or more backticks (plus an optional info
    # string) and closes only on a bare run at least as long, so a shorter
    # "```" inside a "````" block is content -- the same rule as journal-cli's
    # renderer.
    chunks, cur, fence = [], [], 0             # fence: opening run, 0 = prose
    for line in md.split("\n"):
        if fence:
            m = _FENCE_CLOSE.fullmatch(line)
            if m and len(m.group(1)) >= fence:
                chunks.append((True, "\n".join(cur)))
                cur, fence = [], 0
                continue
        else:
            m = _FENCE_OPEN.fullmatch(line)
            if m:
                chunks.append((False, "\n".join(cur)))
                cur, fence = [], len(m.group(1))
                continue
        cur.append(line)
    chunks.append((bool(fence), "\n".join(cur)))
    out = []
    for is_code, text in chunks:
        if not is_code:
            text = re.sub(r"\n{3,}", "\n\n", _flatten_prose(text)).strip("\n")
        if text.strip():
            out.append(text)
    return "\n".join(out).strip()


def _local(utc, tz):
    if tz and zoneinfo:
        try:
            return utc.astimezone(zoneinfo.ZoneInfo(tz))
        except Exception:
            pass
    return utc


def media_index(extra_dirs=()):
    """MD5 -> file path, across Day One's own media dirs and any extras.

    Day One frequently keeps media cloud-only (thumbnails locally, originals
    on demand), so a markdown export's photos/ folder is often the *better*
    source of bytes. Extra dirs are searched first for that reason.
    """
    index = {}
    dirs = [d for d in extra_dirs] + [os.path.join(DAYONE_DIR, d)
                                      for d in MEDIA_DIRS]
    for d in dirs:
        if not d or not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            stem = f.split(".")[0].lower()
            if len(stem) == 32 and stem not in index:
                index[stem] = os.path.join(d, f)
    return index


def read_entries(con, journal_pk, media=None):
    """Normalized entries for one journal, oldest first."""
    media = media if media is not None else {}
    out = []
    rows = con.execute("""
        select e.Z_PK, e.ZUUID, e.ZCREATIONDATE, e.ZMODIFIEDDATE, e.ZSTARRED,
               e.ZTIMEZONE, e.ZMARKDOWNTEXT,
               l.ZPLACENAME, l.ZLOCALITYNAME, l.ZADMINISTRATIVEAREA,
               l.ZCOUNTRY, l.ZLATITUDE, l.ZLONGITUDE, l.ZADDRESS
        from ZENTRY e left join ZLOCATION l on e.ZLOCATION = l.Z_PK
        where e.ZJOURNAL = ? order by e.ZCREATIONDATE, e.Z_PK
    """, (journal_pk,)).fetchall()

    for e in rows:
        atts = con.execute("""
            select ZIDENTIFIER, ZMD5, ZTYPE, ZFORMAT, ZDURATION,
                   ZTRANSCRIPTION, ZORDERINENTRY
            from ZATTACHMENT where ZENTRY = ? order by ZORDERINENTRY, Z_PK
        """, (e["Z_PK"],)).fetchall()
        by_id = {(a["ZIDENTIFIER"] or "").upper(): a for a in atts}

        md = e["ZMARKDOWNTEXT"] or ""
        files, audio, missing, seen = [], [], [], set()

        def classify(ref, a):
            if a["ZFORMAT"] == "aac" or (a["ZDURATION"] and not a["ZTYPE"]):
                audio.append({"uuid": ref, "duration": a["ZDURATION"],
                              "transcription": a["ZTRANSCRIPTION"]})
                return
            path = media.get((a["ZMD5"] or "").lower())
            if path:
                files.append(path)
            else:
                missing.append({"uuid": ref, "md5": a["ZMD5"],
                                "reason": "media not downloaded"})

        prose, refs = _split_moments(md)
        for ref in (m.upper() for m in refs):
            a = by_id.get(ref)
            if a is None:
                # referenced in the text but the attachment row is gone --
                # Day One itself lost it; nothing can recover these.
                missing.append({"uuid": ref, "reason": "no attachment row"})
                continue
            if ref in seen:
                continue
            seen.add(ref)
            classify(ref, a)
        # Rows the text never references still belong to the entry: body
        # order first, then database order, and the same audio and
        # missing-media handling as referenced ones.
        for a in atts:
            i = (a["ZIDENTIFIER"] or "").upper()
            if i and i not in seen:
                seen.add(i)
                classify(i, a)

        lines = prose.split("\n")
        title, body = None, prose
        own = (e["ZUUID"] or "").replace("-", "").upper()
        if lines and lines[0].strip() and not _FENCE_OPEN.fullmatch(lines[0]):
            # Only a real ATX heading marker ("# ", up to six hashes, then
            # whitespace) is syntax; "#travel" is a literal title. A body that
            # opens with a code fence has no title: promoting the fence line
            # would strip the block's opener.
            first = _TITLE_HEADING.sub("", lines[0].strip(), count=1).strip()
            # Day One has no title field; the export promotes line 1. When an
            # entry had no text at all, line 1 is just its own UUID -- that
            # UUID, not any 32-hex string, which is a real title.
            if own and first.replace("-", "").upper() == own:
                body = "\n".join(lines[1:]).strip()
            else:
                title, body = first, "\n".join(lines[1:]).strip()
        # Keep the raw markdown too: journal-cli --markdown renders it into
        # Journal's rich text, so headings survive as real bold rather than
        # being flattened here.
        title_md, body_md = title, body
        title = markdown_to_inline_text(title) or None
        body = markdown_to_text(body)

        tz = timezone_name(e["ZTIMEZONE"])
        utc = datetime.datetime.fromtimestamp(
            e["ZCREATIONDATE"] + CD_EPOCH, datetime.timezone.utc)
        mod = (datetime.datetime.fromtimestamp(
            e["ZMODIFIEDDATE"] + CD_EPOCH, datetime.timezone.utc)
            if e["ZMODIFIEDDATE"] else None)

        out.append({
            "uuid": e["ZUUID"],
            "utc": utc.strftime("%Y-%m-%d %H:%M:%S"),
            "tz": tz,
            "local": _local(utc, tz).strftime("%Y-%m-%d %H:%M:%S"),
            "modified_local": (_local(mod, tz).strftime("%Y-%m-%d %H:%M:%S")
                               if mod else None),
            "starred": bool(e["ZSTARRED"]),
            "title": title,
            "body": body,
            "title_md": title_md,
            "body_md": body_md,
            "media": files,
            "audio": audio,
            "missing": missing,
            "place": e["ZPLACENAME"],
            "city": e["ZLOCALITYNAME"],
            "state": e["ZADMINISTRATIVEAREA"],
            "country": e["ZCOUNTRY"],
            "address": e["ZADDRESS"],
            "lat": e["ZLATITUDE"],
            "lon": e["ZLONGITUDE"],
        })
    return out
