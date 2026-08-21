#!/usr/bin/env python3
"""Shared reader for a Day One 2 SQLite store.

Day One keeps an unencrypted Core Data store at
  ~/Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents/DayOne.sqlite
with media beside it in DayOnePhotos/ DayOneVideos/ DayOneAudios/, filed by
MD5. Entries carry the timezone they were written in (an archived NSTimeZone
blob), which Day One's own markdown export throws away -- it renders every
date in the exporting machine's zone instead. That loss is the main reason
this module reads the store directly.

Read-only: the store is copied to a temp file before any query, so Day One
may stay open.
"""
import os, re, sys, json, shutil, sqlite3, plistlib, tempfile, datetime

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
IMAGE_RE = re.compile(r"!\[\]\([^)]*\)")


def die(msg):
    sys.stderr.write("dayone: %s\n" % msg)
    sys.exit(1)


def snapshot(db_path):
    """Copy the store (plus -wal/-shm) somewhere safe and return the copy."""
    if not os.path.exists(db_path):
        die("no Day One store at %s\n  Is Day One installed and synced?" % db_path)
    tmp = tempfile.mkdtemp(prefix="dayone-")
    out = os.path.join(tmp, "DayOne.sqlite")
    for suffix in ("", "-wal", "-shm"):
        src = db_path + suffix
        if os.path.exists(src):
            shutil.copy2(src, out + suffix)
    return out


def connect(db_path=None):
    con = sqlite3.connect("file:%s?mode=ro" % snapshot(db_path or DEFAULT_DB),
                          uri=True)
    con.row_factory = sqlite3.Row
    return con


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
_CODE_FENCE = re.compile(r"(?m)^[ \t]*```[^\n]*$")


def markdown_to_text(md):
    """Flatten Day One markdown into what a plain-text reader should see."""
    if not md:
        return md
    out = _CODE_FENCE.sub("", md)
    out = _RULE.sub("", out)
    out = _HEADING.sub("", out)
    # a link becomes "text (url)", or just the url when the text repeats it
    out = _LINK.sub(lambda m: m.group(2) if m.group(1).strip() in ("", m.group(2))
                    else "%s (%s)" % (m.group(1), m.group(2)), out)
    out = _BOLD_ITALIC.sub(lambda m: m.group(2), out)
    out = _ESCAPED.sub(r"\1", out)
    out = re.sub(r"\n{3,}", "\n\n", out)
    return out.strip()


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
        for ref in (m.upper() for m in MOMENT_RE.findall(md)):
            a = by_id.get(ref)
            if a is None:
                # referenced in the text but the attachment row is gone --
                # Day One itself lost it; nothing can recover these.
                missing.append({"uuid": ref, "reason": "no attachment row"})
                continue
            seen.add(ref)
            if a["ZFORMAT"] == "aac" or (a["ZDURATION"] and not a["ZTYPE"]):
                audio.append({"uuid": ref, "duration": a["ZDURATION"],
                              "transcription": a["ZTRANSCRIPTION"]})
                continue
            path = media.get((a["ZMD5"] or "").lower())
            if path:
                files.append(path)
            else:
                missing.append({"uuid": ref, "md5": a["ZMD5"],
                                "reason": "media not downloaded"})
        for a in atts:                      # defensive: unreferenced rows
            i = (a["ZIDENTIFIER"] or "").upper()
            if i and i not in seen:
                path = media.get((a["ZMD5"] or "").lower())
                if path:
                    files.append(path)

        prose = IMAGE_RE.sub("", md)
        prose = re.sub(r"\n{3,}", "\n\n", prose).strip()
        lines = prose.split("\n")
        title, body = None, prose
        if lines and lines[0].strip():
            first = lines[0].strip().lstrip("#").strip()
            # Day One has no title field; the export promotes line 1. When an
            # entry had no text at all, line 1 is just its own UUID.
            if re.fullmatch(r"[0-9A-Fa-f]{32}", first):
                body = "\n".join(lines[1:]).strip()
            else:
                title, body = first, "\n".join(lines[1:]).strip()
        # Keep the raw markdown too: journal-cli --markdown renders it into
        # Journal's rich text, so headings survive as real bold rather than
        # being flattened here.
        title_md, body_md = title, body
        title = markdown_to_text(title) or None
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
