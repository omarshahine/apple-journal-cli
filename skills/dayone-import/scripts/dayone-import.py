#!/usr/bin/env python3
"""Move a Day One journal into Apple Journal, with its metadata intact.

Subcommands:
  journals                       list Day One journals and entry counts
  plan     <journal>             what would be imported, and what can't be
  import   <journal>             write the entries via journal-cli
  fix-locations <journal>        correct imported locations from photo EXIF
  fix-text <journal>             re-render entries that show raw Markdown
  fix-export <journal> <dir>     repair a Day One markdown export in place

Why this exists: Day One's markdown export silently renders every timestamp
in the *exporting* machine's timezone, so entries written abroad come out
hours -- sometimes a whole day -- off. Day One's SQLite store still has the
original zone per entry, so this reads that directly and uses the export
folder only as a source of image bytes.
"""
import os, re, sys, json, time, shutil, calendar, zoneinfo, sqlite3, hashlib, argparse, collections, subprocess, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dayone, exifgps, photoslib
from dayone import die

# The import ledger maps Day One entry UUIDs to the Journal rows they became.
# Nothing can regenerate it, and fix-text / fix-locations need it months later,
# so the durable copy lives in the Plugin Data Worker -- the same place the
# rest of this machine's tool state lives -- with a local cache for speed.
# Writing over the network every few entries would stall a large import, so
# the cache is authoritative during a run and published when it finishes.
STATE_DIR = os.path.abspath(os.path.expanduser(
    os.environ.get("DAYONE_IMPORT_STATE", "~/.local/state/dayone-import")))
PLUGIN_DATA = os.path.expanduser("~/.local/bin/plugin-data")
REMOTE_PREFIX = "journal-cli/dayone-import"


def _remote_key(path, ident=None):
    """Where a ledger lives in plugin-data.

    A default ledger (one this tool names, in STATE_DIR) keeps its original
    key, the bare filename, so ledgers published by earlier versions are found
    again. A --state ledger elsewhere is keyed by what it is -- source journal,
    Day One store and destination -- not by its basename, so two different
    ledgers both called state.json never share, and overwrite, one key.
    """
    base = os.path.basename(path)
    if ident is None or os.path.dirname(os.path.abspath(path)) == STATE_DIR:
        return "%s/%s" % (REMOTE_PREFIX, base)
    digest = hashlib.sha1(json.dumps(
        [ident.get("journal"), ident.get("source"), ident.get("target")]
    ).encode("utf-8")).hexdigest()[:12]
    return "%s/%s.%s.json" % (REMOTE_PREFIX, re.sub(r"\.json$", "", base), digest)


def _same_identity(a, b):
    keys = ("journal", "source", "target")
    return all(a.get(k) is None or b.get(k) is None or a.get(k) == b.get(k)
               for k in keys)


def _remote(args, *extra, **kw):
    """Run plugin-data, or return None when it is unavailable."""
    if not os.path.exists(PLUGIN_DATA):
        return None
    try:
        r = subprocess.run([PLUGIN_DATA] + list(args) + list(extra),
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def _remote_status(key):
    """"present" or "absent" for a plugin-data key, or None when it can't say.

    `get` exits 1 both for a missing key and for a failed request, so it
    cannot tell "nothing there" from "couldn't check". `list` can: it
    succeeds with the keys that exist, or fails.
    """
    plugin, _, rel = key.partition("/")
    body = _remote(["list", plugin, os.path.dirname(rel)])
    if body is None:
        return None
    try:
        keys = {k.get("key") for k in json.loads(body).get("keys", [])}
    except (ValueError, AttributeError, TypeError):
        return None
    return "present" if rel in keys else "absent"


def pull_state(path, ident=None):
    """Seed the local cache from the worker when this machine has no copy.

    Tries the ledger's own key, then the bare-filename key earlier versions
    published every ledger under, so a --state ledger from before the keys
    changed is still found. Either copy is restored only if it records this
    import (or records nothing, in which case load_state treats it as an
    untagged ledger and verifies it against the destination before use).
    """
    if os.path.exists(path):
        return
    keys = [_remote_key(path, ident), _remote_key(path)]
    for key in dict.fromkeys(keys):             # de-duplicated, in order
        body = _remote(["get", key])
        if not body:
            continue
        try:
            remote = json.loads(body)
        except ValueError:
            continue                            # not our file; leave it alone
        meta = remote.get("meta") if isinstance(remote, dict) else None
        if ident and meta and not _same_identity(meta, ident):
            sys.stderr.write("note: plugin-data ledger %s belongs to another "
                             "import; not restoring it\n" % key)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(body)
        sys.stderr.write("restored import ledger from plugin-data: %s\n" % key)
        return


def publish_state(path, ident=None):
    """Push the finished ledger to the worker so other machines can see it.

    Never over another import's ledger: if the remote copy at this key records
    a different journal, store or destination, keep it and warn instead.
    """
    if not os.path.exists(path):
        return
    key = _remote_key(path, ident)
    # Only an explicit "absent" lets a put go ahead unchecked; a failed lookup
    # could be hiding another import's ledger at this key.
    status = _remote_status(key)
    body = _remote(["get", key]) if status == "present" else None
    if status is None or (status == "present" and body is None):
        sys.stderr.write(
            "warning: could not check plugin-data key %s, so not publishing over "
            "it. The local copy at %s is the only one; it publishes next run.\n"
            % (key, path))
        return
    if body and ident:
        try:
            meta = json.loads(body).get("meta")
        except (ValueError, AttributeError):
            meta = None
        if meta and not _same_identity(meta, ident):
            sys.stderr.write(
                "warning: plugin-data key %s holds another import's ledger; not "
                "overwriting it. The local copy at %s is the only one.\n"
                % (key, path))
            return
    if _remote(["put", key, path]) is None:
        sys.stderr.write(
            "warning: could not publish the import ledger to plugin-data; "
            "the local copy at %s is the only one.\n" % path)


# --------------------------------------------------------------- helpers

REAL_STORE = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite")


def _target_id(target_db):
    """What a ledger's primary keys belong to: the real store, or one sandbox.

    Resolved the way journal-cli resolves its store: --target-db (passed as
    --db), else $JOURNAL_DB, else the real store. A $JOURNAL_DB sandbox is a
    sandbox, and a path that resolves to the real store is live.
    """
    db = target_db or os.environ.get("JOURNAL_DB")
    if not db:
        return "live"
    real = os.path.realpath(os.path.expanduser(db))
    return "live" if real == os.path.realpath(REAL_STORE) else real


def _store_id(target_db):
    """The destination store's Core Data UUID (Z_METADATA.Z_UUID), or None.

    Paths do not identify a store: two Macs with the same username have the
    same live path but different stores, and a ledger's primary keys are only
    meaningful in the store that allocated them.
    """
    db = target_db or os.environ.get("JOURNAL_DB") or REAL_STORE
    db = os.path.abspath(os.path.expanduser(db))
    if not os.path.exists(db):
        return None
    try:
        from urllib.parse import quote
        c = sqlite3.connect("file:%s?mode=ro" % quote(db), uri=True, timeout=5)
        try:
            row = c.execute("select Z_UUID from Z_METADATA limit 1").fetchone()
        finally:
            c.close()
    except sqlite3.Error:
        return None
    return row[0] if row and row[0] else None


def is_live(target_db):
    return _target_id(target_db) == "live"


def ledger_path(args, journal_name):
    """The ledger for this source journal and this destination.

    A rehearsal against a sandbox gets its own ledger, keyed by the sandbox
    path. Sharing one with the live import made the live run skip every entry
    the rehearsal wrote, and later commands target sandbox primary keys in
    the real store. The live ledger keeps its original name, so ledgers from
    earlier imports still load.
    """
    if args.state:
        return os.path.abspath(os.path.expanduser(args.state))
    stem = re.sub(r"\W+", "_", journal_name)
    target = _target_id(getattr(args, "target_db", None))
    if target != "live":
        stem += ".sandbox-" + hashlib.sha1(target.encode("utf-8")).hexdigest()[:10]
    return os.path.join(STATE_DIR, stem + ".json")


def _source_id(db):
    return os.path.realpath(os.path.expanduser(db or dayone.DEFAULT_DB))


def load_state(path, journal_name, target_db=None, source_db=None):
    """Load a ledger and check it belongs to this journal and destination.

    A ledger written before ledgers recorded their destination has no "meta"
    and may be a rehearsal's, since rehearsals once shared the live filename.
    It is marked "_legacy" so the caller checks it against the destination
    (verify_legacy) before trusting a single primary key in it.
    """
    target = _target_id(target_db)
    source = _source_id(source_db)
    store = _store_id(target_db)
    if target == "live":
        pull_state(path, {"journal": journal_name, "target": target, "source": source})
    if os.path.exists(path):
        with open(path) as fh:
            state = json.load(fh)
    else:
        state = {}
    state.setdefault("done", {})
    state.setdefault("failed", {})
    state.setdefault("pending", {})
    meta = state.get("meta")
    if meta:
        if meta.get("journal") not in (None, journal_name):
            die("ledger %s belongs to Day One journal %r, not %r. Pass --state "
                "to choose another." % (path, meta["journal"], journal_name))
        if meta.get("target") not in (None, target):
            die("ledger %s records writes to %s, not %s. Rehearsal and live "
                "imports keep separate ledgers; pass the matching --target-db "
                "(or --state)." % (path, meta["target"], target))
        if meta.get("source") not in (None, source):
            die("ledger %s was built from Day One store %s, not %s. Pass "
                "--state to choose another." % (path, meta["source"], source))
        if meta.get("source") is None or meta.get("target") is None:
            state["_retag"] = True           # tagged by an older version: save the full tag
        if meta.get("store") and not store:
            # The ledger says which store its ids belong to, and this one's
            # identity can't be read: nothing confirms they match. Fail closed.
            die("ledger %s belongs to Journal store %s, and the destination's "
                "identity could not be read to confirm it is the same store. "
                "Check that journal-cli can read the store (Full Disk Access), "
                "then retry." % (path, meta["store"]))
        if store and meta.get("store") and meta["store"] != store:
            # Written against another Journal store (restored on another Mac):
            # its primary keys belong there. verify_legacy remaps them by the
            # entries' own UUIDs, or refuses.
            state["_moved"] = meta["store"]
        elif store and not meta.get("store") and state["done"]:
            # Tagged before ledgers recorded their store: nothing proves these
            # ids are this store's, so verify them once, as for an untagged one.
            state["_legacy"] = True
    elif state["done"]:
        state["_legacy"] = True
    state.setdefault("dest", {})
    state["meta"] = {"journal": journal_name, "target": target, "source": source}
    if store:
        state["meta"]["store"] = store
    return state


def _record_dest(state, rows):
    """Remember each mapping's Journal entry UUID beside its primary key.

    The UUID is the entry's identity everywhere the entry syncs; the primary
    key is only this store's. With it a ledger restored on another Mac can be
    resolved to that Mac's rows instead of trusted or thrown away.
    """
    by_id = {r["id"]: r for r in rows}
    for uuid, pk in state["done"].items():
        r = by_id.get(pk) if type(pk) is int else None
        if r is not None and r.get("uuid") and uuid not in state["dest"]:
            state["dest"][uuid] = r["uuid"]


def verify_legacy(args, state, state_path, entries):
    """Adopt an untagged ledger only if its entries are really in this store.

    Every done Day One entry must map to a destination entry with that id at
    the instant the import wrote it. A rehearsal ledger fails this against the
    real store (its ids point at other entries), so it is refused before an
    import skips anything or a repair edits the wrong entry.
    """
    retag = state.pop("_retag", False)
    moved = state.pop("_moved", None)
    if moved:
        _remap_moved(args, state, state_path, moved)
        return
    if not state.pop("_legacy", False):
        if retag and not getattr(args, "dry_run", False):
            save_state(state_path, state)    # add the fields older tags lack
        return
    listed = _destination_rows(args.cli, args.target_db)
    rows = {r["id"]: r for r in listed}
    by_uuid = {e["uuid"]: e for e in entries}
    # The old import read each --date in one time zone (and one --time-mode).
    # Find the (mode, zone) pairs under which these mappings land exactly, to
    # the second, on their destination instants -- that absorbs daylight
    # saving and any zone change since -- keep every pair that explains the
    # most of them, and refuse the ledger if any mapping is left unexplained.
    # A rehearsal's ids point at unrelated entries, and a stray entry a
    # quarter hour off cannot fit the same zone as the rest.
    #
    # Content is deliberately not required here: people edit entries after an
    # import (checked against real ledgers: rewritten endings, quotes split
    # into title and author), and that must not make a genuine ledger unusable.
    mapped = [(uuid, pk, by_uuid.get(uuid), rows.get(pk))
              for uuid, pk in state["done"].items() if type(pk) is int]
    zones = _import_zones([(e, row) for _, _, e, row in mapped
                           if e is not None and row is not None])
    bad, checked = [], len(mapped)
    for uuid, pk, e, row in mapped:
        if (e is None or row is None
                or not any(_wrote_at(row["epoch"], e, z) for z in zones)):
            bad.append((uuid, pk))
    if bad:
        die("ledger %s predates destination tagging, and %d of its entries do "
            "not match %s (e.g. Day One %s -> entry %d). It may be a rehearsal's "
            "ledger. Move it aside, or pass --state / --target-db for the store "
            "it belongs to." % (state_path, len(bad), _target_id(args.target_db),
                                bad[0][0], bad[0][1]))
    if not checked:
        # Only id-less marks: nothing ties this ledger to this store, and a
        # rehearsal's marks would make the import skip entries it never wrote.
        die("ledger %s predates destination tagging and records no entry ids, "
            "so it cannot be checked against %s. Move it aside to import from "
            "scratch, or pass --state." % (state_path, _target_id(args.target_db)))
    # Id-less marks are not trusted on the ledger's word: find each one in the
    # destination by instant and words. Found, it gets its id; not found, the
    # mark goes and the entry is imported (a duplicate is recoverable, a
    # skipped entry is silently missing).
    claimed = _claimed(state)
    for uuid, pk in list(state["done"].items()):
        if type(pk) is int:
            continue
        e = by_uuid.get(uuid)
        # Any equally good (mode, zone) may be the right one; only a mark that
        # none of them can place is dropped. Several entries at that second are
        # told apart by their words.
        hits = [r for r in listed if e is not None and r["id"] not in claimed
                and any(_wrote_at(r["epoch"], e, z) for z in zones)]
        if len(hits) > 1:
            hits = [r for r in hits if _same_content(r, e)]
        if len(hits) == 1:
            state["done"][uuid] = hits[0]["id"]
            claimed.add(hits[0]["id"])
        else:
            del state["done"][uuid]
            print("ledger: could not confirm Day One %s in %s; it will be imported"
                  % (uuid, _target_id(args.target_db)))
    _record_dest(state, listed)
    if not getattr(args, "dry_run", False):
        save_state(state_path, state)        # now tagged: verified once


def _remap_moved(args, state, state_path, other_store):
    """Resolve a ledger from another Journal store to this store's rows.

    Each mapping is looked up by the Journal entry UUID it recorded, which
    the entry keeps wherever it syncs. A mapping without one, or whose entry
    is not in this store, cannot be trusted: its primary key names some other
    row here, so the ledger is refused rather than skip entries or repair the
    wrong ones.
    """
    listed = _destination_rows(args.cli, args.target_db)
    by_juuid = {r["uuid"]: r for r in listed if r.get("uuid")}
    bad = []
    for uuid, pk in list(state["done"].items()):
        if type(pk) is not int:
            continue
        r = by_juuid.get(state["dest"].get(uuid))
        if r is None:
            bad.append(uuid)
        else:
            state["done"][uuid] = r["id"]
    idless = [u for u, pk in state["done"].items() if type(pk) is not int]
    if bad or idless:
        die("ledger %s was written against another Journal store (%s; restored "
            "from another Mac?), and %d of its entries cannot be found here by "
            "their entry UUID (e.g. Day One %s). Its entry ids belong to that "
            "store. Move it aside to import from scratch, or run on the Mac "
            "that wrote it." % (state_path, other_store, len(bad) + len(idless),
                                (bad or idless)[0]))
    # A pending write from the other store's run carries that store's id
    # floor, which says nothing about ids here: the entry may have synced in
    # below it. Keep its instant and rendered words as its identity, drop the
    # floor, and let reconcile_pending settle it against this store's rows.
    for info in state["pending"].values():
        info["floor_pk"] = 0
    if not getattr(args, "dry_run", False):
        save_state(state_path, state)        # now this store's ids and tag


_ZONE_CACHE = {}


def _zone(name):
    if name not in _ZONE_CACHE:
        _ZONE_CACHE[name] = zoneinfo.ZoneInfo(name)
    return _ZONE_CACHE[name]


def _naives(e, mode):
    """The wall clocks an import in `mode` may have passed as --date.

    For "local" that includes `local_legacy`: versions before fixed-offset
    zone support read a "GMT+0100" entry's clock as UTC, and a ledger from
    then recorded that reading.
    """
    out = []
    for key in ((mode, "local_legacy") if mode == "local" else (mode,)):
        try:
            out.append(datetime.datetime.strptime(e.get(key) or "", "%Y-%m-%d %H:%M:%S"))
        except ValueError:
            pass
    return out


def _wrote_at(epoch, e, mz):
    """Whether reading the entry's `mode` wall clock in `zone` gives `epoch`."""
    mode, name = mz
    if epoch is None:
        return False
    z = _zone(name)
    return any(int(n.replace(tzinfo=z).timestamp()) == epoch for n in _naives(e, mode))


def _import_zones(pairs):
    """The (mode, zone) pairs that each explain all of these (entry, row) writes.

    Today's zone is tried first: if it explains every write, that is the
    answer (in each mode that does) and no other zone is scanned.
    """
    if not pairs:
        return []
    prepared = [({m: _naives(e, m) for m in ("local", "utc")}, row["epoch"])
                for e, row in pairs]

    def score(mode, name):
        z = _zone(name)
        return sum(1 for naives, epoch in prepared if epoch is not None
                   and any(int(n.replace(tzinfo=z).timestamp()) == epoch
                           for n in naives[mode]))

    names = sorted(zoneinfo.available_timezones())
    local = os.environ.get("TZ")
    if not local:
        try:
            local = os.path.realpath("/etc/localtime").split("zoneinfo/", 1)[1]
        except IndexError:
            local = None
    if local in names:
        full = [(m, local) for m in ("local", "utc") if score(m, local) == len(prepared)]
        if full:
            return full
    # Only a pair that explains EVERY write counts: one import ran under one
    # (mode, zone). Several such pairs (zones that agree on these dates) are
    # all kept; none means no single interpretation fits, and the caller
    # refuses the ledger rather than accept mappings under different zones.
    return [(mode, name) for mode in ("local", "utc") for name in names
            if score(mode, name) == len(prepared)]


def save_state(path, state):
    """Atomically and durably replace the ledger (fsync file and folder)."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=1)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    try:
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def gather(args):
    with dayone.connect(args.db) as con:
        j = dayone.resolve_journal(con, args.journal)
        # Day One's export splits media by kind; search every one it writes,
        # not just photos/, or a journal with video comes up short whenever
        # the app has not also cached the originals locally.
        extra = ([os.path.join(args.export, d)
                  for d in ("photos", "videos", "audios", "pdfs")]
                 if args.export else [])
        media = dayone.media_index(extra, args.db)
        entries = dayone.read_entries(con, j["pk"], media)
    return j, entries


def has_content(e):
    return bool(e["title"] or e["body"] or e["media"]
                or (e["lat"] is not None and e["lon"] is not None))


# ---------------------------------------------------------------- commands

def cmd_journals(args):
    with dayone.connect(args.db) as con:
        rows = dayone.journals(con)
    width = max(len(r["name"] or "") for r in rows) if rows else 4
    print("%-*s  %7s" % (width, "JOURNAL", "ENTRIES"))
    for r in rows:
        print("%-*s  %7d" % (width, r["name"] or "", r["entries"]))
    print("\n%d entries total" % sum(r["entries"] for r in rows))


def cmd_plan(args):
    j, entries = gather(args)
    media = sum(len(e["media"]) for e in entries)
    missing = sum(len(e["missing"]) for e in entries)
    audio = sum(len(e["audio"]) for e in entries)
    empty = [e for e in entries if not has_content(e)]
    located = sum(1 for e in entries if e["lat"] is not None)
    titled = sum(1 for e in entries if e["title"])
    starred = sum(1 for e in entries if e["starred"])
    zones = {}
    for e in entries:
        zones[e["tz"] or "unknown"] = zones.get(e["tz"] or "unknown", 0) + 1

    print("Day One journal : %s (%d entries)" % (j["name"], j["entries"]))
    print("Importable      : %d" % (len(entries) - len(empty)))
    print("  with photos   : %d entries, %d files" %
          (sum(1 for e in entries if e["media"]), media))
    print("  with location : %d" % located)
    print("  with a title  : %d" % titled)
    print("  starred       : %d" % starred)
    if empty:
        print("Skipped (empty) : %d" % len(empty))
    print("\nTimezones represented (%d):" % len(zones))
    for tz, n in sorted(zones.items(), key=lambda x: -x[1]):
        print("  %-24s %4d" % (tz, n))

    if missing or audio:
        print("\nCannot be imported:")
        if audio:
            print("  %d audio recording(s) -- Apple Journal has no write path "
                  "for audio." % audio)
        if missing:
            by_reason = {}
            for e in entries:
                for m in e["missing"]:
                    by_reason[m["reason"]] = by_reason.get(m["reason"], 0) + 1
            for reason, n in sorted(by_reason.items()):
                print("  %d attachment(s): %s" % (n, reason))
            if by_reason.get("media not downloaded"):
                print("     Fix: in Day One, Settings -> Sync -> Download All "
                      "Media, wait, then re-run.")
    if args.json:
        json.dump(entries, open(args.json, "w"), indent=1)
        print("\nmanifest -> %s" % args.json)


def _local_zone_name():
    local = os.environ.get("TZ")
    if not local:
        try:
            local = os.path.realpath("/etc/localtime").split("zoneinfo/", 1)[1]
        except IndexError:
            local = None
    return local


def _wall_epochs(stamp):
    """Every instant a local wall clock can name: two in a daylight-saving fold.

    journal-cli resolves a repeated hour one way and this process might
    resolve it the other, so a pending write records both.
    """
    try:
        naive = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
        z = zoneinfo.ZoneInfo(_local_zone_name())
    except (TypeError, ValueError, zoneinfo.ZoneInfoNotFoundError, OSError):
        e = _wall_epoch(stamp)
        return [e] if e is not None else []
    return sorted({int(naive.replace(tzinfo=z, fold=f).timestamp()) for f in (0, 1)})


def _utc_epoch(stamp):
    """A "YYYY-MM-DD HH:MM:SS" reading in UTC -> unix seconds."""
    try:
        return calendar.timegm(time.strptime(stamp, "%Y-%m-%d %H:%M:%S"))
    except (TypeError, ValueError, OverflowError):
        return None


def _wall_epoch(stamp):
    """A "YYYY-MM-DD HH:MM:SS" wall clock in this Mac's zone -> unix seconds.

    journal-cli reads --date that way and `list` prints dates that way, so
    comparing epochs (not strings) survives a timezone change between a write
    and the run that reconciles it.
    """
    try:
        return int(time.mktime(time.strptime(stamp, "%Y-%m-%d %H:%M:%S")))
    except (TypeError, ValueError, OverflowError):
        return None


def _fingerprint(title, text):
    """A short hash of an entry's visible title and text."""
    raw = "%s\x00%s" % ((title or "").strip(), (text or "").strip())
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]


def _expected_fingerprint(cli, title_md, body_md):
    """What `list --full` will show for this write, via journal-cli's renderer."""
    title = _render(cli, title_md, inline=True) if title_md else b""
    text = _render(cli, body_md, plain=True) if body_md else b""
    if title is None or text is None:
        return None
    return _fingerprint(title.decode("utf-8", "replace"),
                        text.decode("utf-8", "replace"))


def _destination_rows(cli, target_db):
    """[{id, uuid, epoch, fp, ...}] for every entry in the destination store.

    Listed in UTC and read as UTC: a local listing repeats an hour at the end
    of daylight saving, and two instants that print the same cannot both be
    recovered from the text.
    """
    cmd = [cli] + (["--db", target_db] if target_db else []) + [
        "list", "--limit", "1000000", "--include-empty", "--full", "--json"]
    r = subprocess.run(cmd, capture_output=True, text=True,
                       env=dict(os.environ, TZ="UTC"))
    if r.returncode:
        die("could not list destination entries to reconcile the ledger: %s"
            % (r.stderr or r.stdout).strip())
    return [{"id": x["id"], "uuid": x.get("uuid"), "epoch": _utc_epoch(x.get("date")),
             "fp": _fingerprint(x.get("title"), x.get("text")),
             "title": x.get("title") or "", "text": x.get("text") or ""}
            for x in json.loads(r.stdout)]


def _norm(s, digits=False):
    """Letters (optionally digits) only, lowercased.

    Survives raw Markdown vs Journal's rendering, which drops syntax and
    renumbers lists ("7. Walked" is saved as a list item numbered from 1), so
    digits are left out unless a field has no letters at all.
    """
    return re.sub(r"[\W_]+" if digits else r"[\W_\d]+", "", s or "").lower()


def _field_matches(dest, forms):
    """Whether a destination field carries one of these source forms."""
    # A form with no letters or digits ("---", a lone emoji) says nothing.
    forms = [f for f in forms if _norm(f, True)]
    if not forms:
        return True                            # nothing to compare in this field
    digits = not any(_norm(f) for f in forms)  # e.g. a title that is just "2024"
    have = _norm(dest, digits)
    # Equal, or the same opening AND closing 40 letters: a shared introduction
    # with a different ending is a different entry.
    for f in forms:
        want = _norm(f, digits)
        if want and (want == have or (want[:40] in have and want[-40:] in have)):
            return True
    return False


def _same_content(row, e):
    """Whether a destination entry is this Day One entry by its words.

    Title against title and body against body, each in raw Markdown or
    flattened form (early imports wrote Markdown through, later ones rendered
    it). Every field the source has must match: a shared title alone does not
    make two entries the same. An entry with no words matches only one with
    none.
    """
    title_forms = [e.get("title"), e.get("title_md")]
    body_forms = [e.get("body"), e.get("body_md")]
    if not any(_norm(f, True) for f in title_forms + body_forms):
        return not _norm(row["title"] + row["text"], True)
    return (_field_matches(row["title"], title_forms)
            and _field_matches(row["text"], body_forms))


def _landed(info, rows, claimed):
    """Destination entries that are this pending write, by identity.

    Only an entry created after the write was queued (id above its floor),
    not already claimed by another Day One entry, at the same instant, and
    with the same rendered title and text counts. Date alone is not identity.
    """
    floor = info.get("floor_pk", 0)
    epochs = set(info.get("epochs") or [])
    if info.get("epoch") is not None:
        epochs.add(info["epoch"])
    if not epochs:
        epochs = set(_wall_epochs(info.get("date")))
    fp = info.get("fp")
    return [r for r in rows
            if r["id"] > floor and r["id"] not in claimed
            and r["epoch"] is not None and r["epoch"] in epochs
            and (fp is None or r["fp"] == fp)]


def _settle(uuid, info, rows, claimed, state, state_path):
    """Record a pending write as done if it landed; True if it did."""
    hits = _landed(info, rows, claimed)
    if len(hits) > 1:
        die("cannot tell which of entries %s is Day One entry %s (an "
            "interrupted write). Check them in Journal, then record the "
            "right one in %s under \"done\" and remove it from \"pending\"."
            % (", ".join(str(h["id"]) for h in hits), uuid, state_path))
    state["pending"].pop(uuid, None)
    if hits:
        state["done"][uuid] = hits[0]["id"]
        claimed.add(hits[0]["id"])
        return True
    return False


def _claimed(state):
    return {v for v in state["done"].values() if type(v) is int}


def reconcile_pending(args, state, state_path, rows):
    """Settle writes that were in flight when a previous run stopped.

    Each write is marked pending in the ledger before journal-cli runs and
    moved to done right after it succeeds. A pending mark left behind means
    the run stopped in between, so the entry may or may not have landed.
    """
    if not state["pending"]:
        return
    claimed = _claimed(state)
    for uuid, info in list(state["pending"].items()):
        if _settle(uuid, info, rows, claimed, state, state_path):
            print("reconciled: %s already landed as entry %d"
                  % (uuid, state["done"][uuid]))
        else:
            print("reconciled: %s never landed; it will be written" % uuid)
    save_state(state_path, state)


def cmd_import(args):
    j, entries = gather(args)
    target = args.into or j["name"]
    state_path = ledger_path(args, j["name"])
    state = load_state(state_path, j["name"], args.target_db, args.db)
    verify_legacy(args, state, state_path, entries)
    floor_pk = 0
    if not args.dry_run:
        # Prove the ledger can be written before touching the destination:
        # a write the ledger cannot record is a write a re-run repeats.
        try:
            save_state(state_path, state)
        except OSError as e:
            die("cannot write the import ledger %s: %s" % (state_path, e))
        rows = _destination_rows(args.cli, args.target_db)
        reconcile_pending(args, state, state_path, rows)
        _record_dest(state, rows)
        save_state(state_path, state)       # keep them even if nothing is left to write
        # Anything this run creates gets an id above this.
        floor_pk = max([r["id"] for r in rows] or [0])

    todo = [e for e in entries if has_content(e)
            and e["uuid"] not in state["done"]]
    skipped = [e for e in entries if not has_content(e)]
    if args.limit:
        todo = todo[:args.limit]

    # Probe once rather than discovering mid-migration: an older journal-cli
    # rejects --markdown for every text entry while media-only entries still
    # land, leaving a half-written journal and state file.
    if _render(args.cli, "probe") is None:
        die("%s does not support --markdown (needs journal-cli 1.1.0+)"
            % args.cli)
    if any(e["lat"] is not None and e["lon"] is not None for e in todo):
        probe = [args.cli, "write", "--body", "probe", "--lat", "0", "--lon", "0",
                 "--location-presentation", args.location_presentation, "--dry-run"]
        if subprocess.run(probe, capture_output=True, text=True).returncode:
            die("%s does not support --location-presentation %s (needs journal-cli 1.3.0+)"
                % (args.cli, args.location_presentation))

    live = is_live(args.target_db)
    print("Day One '%s' -> Apple Journal '%s'" % (j["name"], target))
    print("%d to write, %d already done, %d empty/skipped%s"
          % (len(todo), len(state["done"]), len(skipped),
             "" if live else "  [sandbox %s]" % args.target_db))
    if not todo:
        print("Nothing to do.")
        return

    backups_before = set(_backup_dirs()) if live and args.prune_backups else set()
    ok = fail = 0
    for n, e in enumerate(todo, 1):
        cmd = [args.cli]
        if args.target_db:
            cmd += ["--db", args.target_db]
        cmd += ["write", "--journal", target]
        when = e["utc"] if args.time_mode == "utc" else e["local"]
        cmd += ["--date", when]
        # Hand over the raw markdown: journal-cli --markdown renders it into
        # Journal's rich text, so headings and emphasis become real formatting
        # instead of literal "###### " in the finished entry.
        # Decide on the raw markdown, not on the flattened text: the renderer
        # in journal-cli is what knows whether a field renders to nothing.
        title_md = e.get("title_md") if e.get("title_md") is not None else e["title"]
        body_md = e.get("body_md") if e.get("body_md") is not None else e["body"]
        if title_md:
            cmd += ["--title", title_md]
        if body_md:
            cmd += ["--body", body_md]
        if title_md or body_md:
            cmd += ["--markdown"]
        if e["starred"]:
            cmd += ["--bookmark"]
        if e["lat"] is not None and e["lon"] is not None:
            cmd += ["--lat", "%.6f" % e["lat"], "--lon", "%.6f" % e["lon"]]
            cmd += ["--location-presentation", args.location_presentation]
            if e["place"]:
                cmd += ["--place", e["place"]]
            if e["city"]:
                cmd += ["--city", e["city"]]
        for m in e["media"]:
            cmd += ["--media", m]
        if live:
            cmd += ["--live", "--accept-risk"]
        if args.dry_run:
            cmd += ["--dry-run"]

        label = (e["title"] or e["body"] or "(photos only)").split("\n")[0][:52]
        sys.stdout.write("[%4d/%d] %s  %s\n" % (n, len(todo), when[:16], label))
        sys.stdout.flush()

        if not args.dry_run:
            # Marked before the write, cleared right after it: if the run
            # dies in between, the next run reconciles instead of guessing.
            # The record carries what identifies the entry once it lands.
            state["pending"][e["uuid"]] = {
                "date": when, "epoch": _wall_epoch(when),
                "epochs": _wall_epochs(when), "floor_pk": floor_pk,
                "fp": _expected_fingerprint(args.cli, title_md, body_md)}
            save_state(state_path, state)
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0 and not args.dry_run:
            # A nonzero exit is not proof nothing landed: journal-cli can be
            # killed after its commit. Check before calling it a failure.
            info = state["pending"][e["uuid"]]
            rows = _destination_rows(args.cli, args.target_db)
            if _settle(e["uuid"], info, rows, _claimed(state), state, state_path):
                state["failed"].pop(e["uuid"], None)
                save_state(state_path, state)
                sys.stderr.write("          journal-cli exited %d, but entry %d "
                                 "landed; recorded it\n"
                                 % (r.returncode, state["done"][e["uuid"]]))
                ok += 1
                continue
        if r.returncode != 0:
            fail += 1
            err = (r.stderr or r.stdout).strip().split("\n")[-1]
            sys.stderr.write("          FAILED: %s\n" % err)
            if not args.dry_run:
                state["failed"][e["uuid"]] = err
                save_state(state_path, state)
            if fail >= args.max_failures:
                die("stopping after %d failures; state saved to %s"
                    % (fail, state_path))
            continue
        ok += 1
        if not args.dry_run:
            m = re.search(r"entry (\d+)", r.stdout)
            state["done"][e["uuid"]] = int(m.group(1)) if m else True
            state["failed"].pop(e["uuid"], None)
            state["pending"].pop(e["uuid"], None)
            save_state(state_path, state)
        if live and args.prune_backups and n % 25 == 0:
            _prune_backups(backups_before)

    if not args.dry_run:
        if ok:
            # One listing to record the new entries' UUIDs, so this ledger
            # can be resolved on another Mac (see _record_dest).
            _record_dest(state, _destination_rows(args.cli, args.target_db))
        save_state(state_path, state)
        if live:                        # rehearsal ledgers stay on this Mac
            publish_state(state_path, state.get("meta"))
    if live and args.prune_backups:
        _prune_backups(backups_before)

    print("\nWrote %d, failed %d. State: %s" % (ok, fail, state_path))
    if not args.dry_run and live:
        print("\nThe entries are in Mac-local staging journal %r." % target)
        print("To sync that journal membership to iPhone and other devices:")
        print("  1. In Journal.app, create a new final journal with a different name.")
        print("  2. Open %r, then choose Select Entries > Select All." % target)
        print("  3. Choose Move / Choose Journals and select the new final journal.")
        print("  4. Wait until %r shows 0 entries and iCloud finishes syncing." % target)


# journal-cli snapshots the whole store before every live write; across a
# few thousand entries that is tens of GB of near-identical copies. Keep the
# ones that predate this run, retire the rest to the Trash (never rm).
_PRUNE_WARNED = False


def _backup_dirs():
    root = os.path.expanduser("~/Backups/journal-cli")
    if not os.path.isdir(root):
        return []
    return [os.path.join(root, d) for d in sorted(os.listdir(root))]


def _prune_backups(keep):
    made = [d for d in _backup_dirs() if d not in keep]
    stale = made[:-1]                       # always keep the most recent
    if not stale:
        return
    if not shutil.which("trash"):
        # These are the only copies of the store from before each write.
        # Retiring them to the Trash is recoverable; deleting them is not, so
        # rather than quietly destroying backups, leave them and say so.
        global _PRUNE_WARNED
        if not _PRUNE_WARNED:
            _PRUNE_WARNED = True
            sys.stderr.write(
                "warning: `trash` is unavailable (macOS 26+), so backup "
                "snapshots are being kept rather than deleted. Remove "
                "~/Backups/journal-cli yourself if disk space runs short.\n")
        return
    subprocess.run(["trash"] + stale, capture_output=True)


def _haversine(a, b, c, d):
    import math
    R = 6371.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def _photo_fix(entry):
    """Where the photos say the entry happened, and what that place is called.

    Day One stamps an entry with wherever the *app* was when the entry was
    written, so entries composed after the fact carry the author's home
    address. The photos' own EXIF is the better witness.

    Anchor on the photo taken closest in time to the entry itself, not on the
    geographic centre: an entry covering a drive or a flight has photos
    scattered along the route, and its location should be where it began, not
    the middle of the journey.
    """
    pts = []
    for m in entry["media"]:
        try:
            g = exifgps.read(m)
        except Exception as ex:          # one damaged photo must not stop the audit
            sys.stderr.write("note: skipping unreadable EXIF in %s (%s)\n" % (m, ex))
            continue
        if "lat" in g:
            pts.append(g)
    if not pts:
        return None
    anchor = pts[0]
    dated = [p for p in pts if p.get("when") and exifgps._valid_when(p["when"])]
    if dated and entry.get("local"):
        try:
            t0 = datetime.datetime.strptime(entry["local"], "%Y-%m-%d %H:%M:%S")
            anchor = min(dated, key=lambda p: abs(
                (datetime.datetime.strptime(p["when"], "%Y-%m-%d %H:%M:%S")
                 - t0).total_seconds()))
        except ValueError:
            pass
    return {"lat": anchor["lat"], "lon": anchor["lon"], "when": anchor.get("when"),
            "ref_lat": anchor["lat"], "ref_lon": anchor["lon"], "n": len(pts)}


def cmd_fix_locations(args):
    j, entries = gather(args)
    state_path = ledger_path(args, j["name"])
    state = load_state(state_path, j["name"], args.target_db, args.db)
    verify_legacy(args, state, state_path, entries)
    if not state["done"]:
        die("no import state at %s -- run `import` first" % state_path)

    con = photoslib.connect()
    if con is None:
        sys.stderr.write("note: no Photos library found; coordinates will be "
                         "corrected without place names.\n")
    try:
        _fix_locations(args, entries, state, con)
    finally:
        if con is not None:
            con.close()


def _fix_locations(args, entries, state, con):

    fixes, skipped_unverified = [], []
    for e in entries:
        pk = state["done"].get(e["uuid"])
        if type(pk) is not int:
            continue
        got = _photo_fix(e)
        if not got:
            continue
        if e["lat"] is not None:
            off = _haversine(e["lat"], e["lon"], got["lat"], got["lon"])
            if off <= args.threshold:
                continue
        else:
            off = None

        place = city = None
        hit = (photoslib.match(con, got["when"], got["ref_lat"], got["ref_lon"])
               if con is not None and got["when"] else None)
        if hit:
            place, city = photoslib.describe(hit)

        # Overriding a location Day One already recorded needs corroboration.
        # A camera with a stale GPS fix will geotag a whole trip from one
        # spot, and those frames have no counterpart in the Photos library --
        # so "EXIF disagrees but nothing in Photos backs it up" is a signal to
        # leave the existing location alone.
        if e["lat"] is not None and hit is None and not args.trust_exif:
            skipped_unverified.append((e, pk, got, off))
            continue

        if args.skip and str(pk) in args.skip.split(","):
            continue
        fixes.append((e, pk, got, off, place, city))

    if skipped_unverified:
        print("Left alone -- photo EXIF disagrees but no Photos library asset "
              "corroborates it (likely a stale camera GPS fix):")
        for e, pk, got, off in skipped_unverified:
            print("  [%s] %-34s  keeps %s, %s  (photos claim %.4f, %.4f, "
                  "%.0f km away)" % (pk, (e["title"] or "(untitled)")[:34],
                                     e["place"], e["city"], got["lat"],
                                     got["lon"], off))
        print("  Pass --trust-exif to apply these anyway.\n")

    if not fixes:
        print("Every entry's location agrees with its photos.")
        return

    print("%d entr%s to relocate (threshold %g km):\n"
          % (len(fixes), "y" if len(fixes) == 1 else "ies", args.threshold))
    for e, pk, got, off, place, city in fixes:
        was = ("%s, %s" % (e["place"], e["city"]) if e["lat"] is not None
               else "(no location)")
        print("  [%s] %-34s" % (pk, (e["title"] or "(untitled)")[:34]))
        print("        was  %s" % was)
        print("        now  %s  (%.4f, %.4f)%s"
              % (", ".join(x for x in (place, city) if x) or "coordinates only",
                 got["lat"], got["lon"],
                 "  %.0f km off" % off if off else ""))

    if args.dry_run:
        print("\nDRY RUN: nothing written.")
        return

    ok = 0
    prune = bool(args.prune_backups) and is_live(args.target_db)
    backups_before = set(_backup_dirs()) if prune else set()
    for n, (e, pk, got, off, place, city) in enumerate(fixes, 1):
        cmd = [args.cli]
        if args.target_db:
            cmd += ["--db", args.target_db]
        cmd += ["edit", str(pk),
                "--lat", "%.6f" % got["lat"], "--lon", "%.6f" % got["lon"]]
        if place:
            cmd += ["--place", place]
        if city:
            cmd += ["--city", city]
        if not args.target_db:
            cmd += ["--live", "--accept-risk"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            sys.stderr.write("  entry %s FAILED: %s\n"
                             % (pk, (r.stderr or r.stdout).strip().split("\n")[-1]))
        else:
            ok += 1
        if prune and n % 25 == 0:
            _prune_backups(backups_before)
    if prune:
        _prune_backups(backups_before)
    print("\nRelocated %d of %d." % (ok, len(fixes)))


def _stored(cli, target_db):
    """pk -> (title, plain text, raw RTF) for entries currently in the store.

    The RTF matters: an entry can read correctly as plain text while still
    having lost the bold and list markup its source called for.
    """
    cmd = [cli]
    if target_db:
        cmd += ["--db", target_db]
    cmd += ["list", "--limit", "100000", "--full", "--include-empty", "--json"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        die("could not list entries: %s" % r.stderr.strip())
    text = {e["id"]: (e.get("title") or "", e.get("text") or "")
            for e in json.loads(r.stdout)}

    # Must be the same store the `list` subprocess just read, or primary keys
    # would be matched against a different database entirely.
    db = target_db or os.environ.get("JOURNAL_DB") or os.path.expanduser(
        "~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite")
    rtf, crdt, rtf_ok = {}, set(), True
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        for pk, blob, merge in con.execute(
                "select Z_PK, ZTEXT, ZMERGEABLEATTRIBUTES from ZJOURNALENTRYMO"):
            if blob is not None:
                rtf[pk] = (bytes(blob) if isinstance(blob, (bytes, bytearray))
                           else str(blob).encode("utf-8"))
            if merge is not None:
                crdt.add(pk)
        con.close()
    except sqlite3.Error:
        # Without the RTF we cannot tell rendered from unrendered formatting.
        # Say so and check only what plain text can prove, rather than
        # treating every entry as having lost its markup.
        rtf_ok = False
        sys.stderr.write("note: could not read entry RTF from %s; checking "
                         "visible text only.\n" % db)
    return ({pk: (t[0], t[1], rtf.get(pk)) for pk, t in text.items()},
            rtf_ok, crdt)


# Formatting controls that carry meaning, counted so two RTF documents can be
# compared without tripping over serializer differences -- a macOS upgrade can
# change the \cocoartf version or font-table order without changing a word.
_FMT_CONTROLS = (
    ("bold", re.compile(rb"\\b(?![0-9a-zA-Z])")),
    ("italic", re.compile(rb"\\i(?![0-9a-zA-Z])")),
    ("strike", re.compile(rb"\\strike(?![0-9a-zA-Z])")),
    ("list", re.compile(rb"\\listtext")),
)


def _fmt_signature(rtf):
    if rtf is None:
        return None
    return tuple(len(pat.findall(rtf)) for _name, pat in _FMT_CONTROLS)


def _render(cli, md, plain=False, inline=False):
    """What journal-cli --markdown would store for this source, or None.

    `inline` matches how a title is rendered: no block handling, so a title
    of "1. first" stays a title rather than becoming a list item.
    """
    cmd = [cli, "render"]
    if inline:
        cmd.append("--inline")
    elif plain:
        cmd.append("--plain")
    r = subprocess.run(cmd, input=(md or "").encode("utf-8"),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return None if r.returncode else r.stdout


def cmd_fix_text(args):
    """Re-render entries whose text still carries raw Markdown syntax.

    Early imports wrote Day One's markdown through as plain text, so headings
    and escapes ended up visible. This rewrites those entries from the
    original markdown using journal-cli --markdown.
    """
    j, entries = gather(args)
    state_path = ledger_path(args, j["name"])
    state = load_state(state_path, j["name"], args.target_db, args.db)
    verify_legacy(args, state, state_path, entries)
    if not state["done"]:
        die("no import state at %s -- run `import` first" % state_path)

    stored, rtf_ok, crdt = _stored(args.cli, args.target_db)
    if _render(args.cli, "probe") is None:
        die("%s has no `render` command -- upgrade journal-cli" % args.cli)

    # Compare each entry against what the renderer would produce now, rather
    # than sniffing the stored text for leftover syntax. Sniffing cannot tell
    # a correctly rendered "**literal**" (from escaped source) or a fenced
    # "# comment" from unrendered markup, so it kept flagging good entries
    # forever. An exact comparison is idempotent by construction.
    todo, reasons, edited = [], collections.Counter(), []
    for e in entries:
        pk = state["done"].get(e["uuid"])
        # `True` is an int in Python and equal to 1, so a state record that
        # fell back to a boolean would otherwise target entry 1.
        if type(pk) is not int or pk not in stored:
            continue
        title, text, rtf = stored[pk]
        # An entry edited in Journal since import carries Journal's own CRDT
        # copy of the text. journal-cli refuses to rewrite those without
        # --force, and forcing would discard the user's edit -- so leave them
        # alone and say which ones rather than failing partway through.
        if pk in crdt:
            edited.append((e, pk))
            continue
        why = None

        want_title = _render(args.cli, e.get("title_md") or e["title"] or "",
                             inline=True)
        if want_title is not None and want_title.decode("utf-8", "replace") != title:
            why = "title differs from rendered source"

        body_md = e.get("body_md")
        if body_md is None:
            body_md = e["body"] or ""
        if why is None:
            want_plain = _render(args.cli, body_md, plain=True)
            want_text = ("" if want_plain is None
                         else want_plain.decode("utf-8", "replace"))
            if want_plain is not None and want_text != text:
                why = "body text differs from rendered source"
            elif rtf_ok and want_plain is not None:
                if not want_text.strip():
                    if rtf is not None:
                        why = "body should be empty"
                elif _fmt_signature(rtf) != _fmt_signature(
                        _render(args.cli, body_md)):
                    why = "body formatting differs from rendered source"

        if why:
            reasons[why] += 1
            todo.append((e, pk))

    if edited:
        print("Skipped %d entr%s edited in Journal since import (they carry "
              "Journal's own copy of the text; re-rendering would discard "
              "your edit):" % (len(edited), "y" if len(edited) == 1 else "ies"))
        for e, pk in edited[:5]:
            print("   [%s] %s" % (pk, (e["title"] or "(untitled)")[:52]))
        if len(edited) > 5:
            print("   ... and %d more" % (len(edited) - 5))
        print()

    print("%d of %d imported entries need re-rendering."
          % (len(todo), len(state["done"])))
    for why, n in reasons.most_common():
        print("   %4d  %s" % (n, why))
    if not todo:
        return
    for e, pk in todo[:5]:
        before = stored[pk][1].split("\n")[0][:64]
        print("   [%s] %s" % (pk, before or stored[pk][0][:64]))
    if len(todo) > 5:
        print("   ... and %d more" % (len(todo) - 5))
    if args.dry_run:
        print("\nDRY RUN: nothing written.")
        return

    ok = fail = 0
    # Gate on the option, not on whether the keep set happens to be non-empty:
    # a first run against an empty ~/Backups would otherwise skip pruning.
    prune = bool(args.prune_backups) and is_live(args.target_db)
    backups_before = set(_backup_dirs()) if prune else set()
    for n, (e, pk) in enumerate(todo, 1):
        cmd = [args.cli]
        if args.target_db:
            cmd += ["--db", args.target_db]
        cmd += ["edit", str(pk), "--markdown"]
        title_md = e.get("title_md") or e["title"]
        # Drive off the raw markdown, not the rendered text: a body that is
        # only a "---" rule renders to nothing and must be cleared, which a
        # truthiness check on the rendered text would skip.
        body_md = e.get("body_md")
        if body_md is None:
            body_md = e["body"]
        # An omitted --title keeps whatever is stored, so a title the source
        # does not have (an older import promoted a code fence to the title)
        # is cleared explicitly with an empty one.
        clear_title = not title_md and bool((stored[pk][0] or "").strip())
        if title_md:
            cmd += ["--title", title_md]
        elif clear_title:
            cmd += ["--title", ""]
        if body_md is not None and (body_md != "" or e["body"] == ""):
            cmd += ["--body", body_md]
        if not title_md and not body_md and not clear_title:
            continue
        if not args.target_db:
            cmd += ["--live", "--accept-risk"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            fail += 1
            sys.stderr.write("  entry %s FAILED: %s\n"
                             % (pk, (r.stderr or r.stdout).strip().split("\n")[-1]))
            if fail >= args.max_failures:
                die("stopping after %d failures" % fail)
        else:
            ok += 1
        if n % 100 == 0:
            print("   %d/%d" % (n, len(todo)))
        if prune and n % 25 == 0:
            _prune_backups(backups_before)
    if prune:
        _prune_backups(backups_before)
    print("\nRewrote %d, failed %d." % (ok, fail))


# ------------------------------------------------------------- fix-export

FM_RE = re.compile(r"\A---\n(.*?)\n---\n(.*)\Z", re.S)
MONTHS = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]


def _stamp(dt):
    """Day One's export filename prefix: '04-9:03am' / '21-12:28pm'."""
    hour = dt.hour % 12 or 12
    return "%02d-%d:%02d%s" % (dt.day, hour, dt.minute,
                               "am" if dt.hour < 12 else "pm")


def cmd_fix_export(args):
    root = args.export
    if not os.path.isdir(root):
        die("no such export directory: %s" % root)
    with dayone.connect(args.db) as con:
        j = dayone.resolve_journal(con, args.journal)
        entries = {e["uuid"].upper(): e
                   for e in dayone.read_entries(con, j["pk"], {})}

    files = []
    for r, _d, fs in os.walk(root):
        if os.path.basename(r) == "photos":
            continue
        files += [os.path.join(r, f) for f in fs if f.endswith(".md")]
    if not files:
        die("no .md files under %s" % root)

    if not args.dry_run and args.backup:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        bdir = os.path.join(args.backup, "dayone-export-%s" % stamp)
        os.makedirs(bdir, exist_ok=True)
        for f in files:
            rel = os.path.relpath(f, root)
            dst = os.path.join(bdir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(f, dst)
        print("backup: %s (%d notes)" % (bdir, len(files)))

    stats = {"retimed": 0, "renamed": 0, "moved": 0, "flagged": 0,
             "enriched": 0, "unmatched": 0}
    planned = {}

    for path in sorted(files):
        text = open(path, encoding="utf-8").read()
        m = FM_RE.match(text)
        if not m:
            stats["unmatched"] += 1
            continue
        fm, body = m.groups()
        um = re.search(r"^uuid:\s*(\S+)", fm, re.M)
        e = entries.get(um.group(1).upper()) if um else None
        if not e:
            stats["unmatched"] += 1
            continue

        created = datetime.datetime.strptime(e["local"], "%Y-%m-%d %H:%M:%S")
        fields = {
            "creationDate": created.strftime("%Y-%m-%dT%H:%M"),
            "modifiedDate": (datetime.datetime.strptime(
                e["modified_local"], "%Y-%m-%d %H:%M:%S").strftime("%Y-%m-%dT%H:%M")
                if e["modified_local"] else None),
            "timezone": e["tz"],
            "uuid": e["uuid"],
        }
        if args.enrich:
            fields.update({
                "place": e["place"], "city": e["city"], "state": e["state"],
                "country": e["country"], "address": e["address"],
                "coordinates": ("%s,%s" % (e["lat"], e["lon"])
                                if e["lat"] is not None else None),
                "starred": "true" if e["starred"] else None,
            })
            for i, a in enumerate(e["audio"]):
                if a.get("transcription"):
                    fields["audioTranscription%s" % (i + 1 if i else "")] = \
                        a["transcription"]

        # blank strings are noise in YAML; treat them as absent
        fields = {k: v for k, v in fields.items()
                  if not (isinstance(v, str) and not v.strip())}

        # rewrite the frontmatter, preserving unknown keys and their order
        kept, seen = [], set()
        for line in fm.split("\n"):
            key = line.split(":", 1)[0].strip()
            if key in fields:
                seen.add(key)
                if fields[key] is not None:
                    kept.append("%s: %s" % (key, fields[key]))
            elif args.enrich and key in ("location",) and e["place"]:
                kept.append(line)
            else:
                kept.append(line)
        for key, val in fields.items():
            if key not in seen and val is not None:
                kept.append("%s: %s" % (key, val))
        new_fm = "\n".join(kept)

        new_body = body
        if args.flag_missing:
            def replace(ref, note):
                # A 32-hex id matches its reference in any form (photo,
                # audio, video, pdfAttachment, ...). Anything else is a
                # reference reported by its own text (read_entries upper-cases
                # it), matched literally -- never compiled as a pattern.
                if re.fullmatch(r"[0-9A-Fa-f]{32}", ref):
                    pat = re.compile(r"!\[\]\(dayone-moment:[^)\s]*?%s\)" % ref, re.I)
                else:
                    pat = re.compile(re.escape(ref), re.I)
                return pat.subn(lambda m: note, new_body)

            for miss in e["missing"]:
                new_body, n = replace(
                    miss["uuid"],
                    "*[missing attachment %s -- %s]*"
                    % (miss["uuid"][:8], miss["reason"]))
                stats["flagged"] += n
            # audio refs render as broken links in any markdown reader; the
            # transcription is preserved in the frontmatter instead.
            for a in e["audio"]:
                secs = int(a["duration"] or 0)
                new_body, n = replace(
                    a["uuid"],
                    "*[voice recording, %d:%02d -- transcription in "
                    "frontmatter]*" % (secs // 60, secs % 60))
                stats["flagged"] += n

        new_text = "---\n%s\n---\n%s" % (new_fm, new_body)

        # relocate: Day One files notes as <Year>/<Month>/<DD-time Title>.md
        base = os.path.basename(path)
        rest = re.sub(r"^\d{2}-\d{1,2}:\d{2}[ap]m ", "", base)
        new_base = "%s %s" % (_stamp(created), rest)
        new_dir = os.path.join(root, str(created.year), MONTHS[created.month - 1]) \
            if args.rename else os.path.dirname(path)
        new_path = os.path.join(new_dir, new_base if args.rename else base)

        if new_path != path:
            n = 2
            while new_path in planned or (os.path.exists(new_path)
                                          and new_path != path):
                stem = (new_base if args.rename else base)[:-3]
                new_path = os.path.join(new_dir, "%s (%d).md" % (stem, n))
                n += 1
        planned[new_path] = True

        changed_text = new_text != text
        if changed_text:
            stats["retimed"] += 1
        if args.enrich:
            stats["enriched"] += 1
        if new_path != path:
            stats["renamed"] += 1
            if os.path.dirname(new_path) != os.path.dirname(path):
                stats["moved"] += 1

        if args.dry_run:
            if new_path != path:
                print("  %s\n    -> %s" % (os.path.relpath(path, root),
                                           os.path.relpath(new_path, root)))
            continue
        if changed_text:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_text)
        if new_path != path:
            os.makedirs(os.path.dirname(new_path), exist_ok=True)
            os.rename(path, new_path)

    # drop directories the moves emptied
    if not args.dry_run and args.rename:
        for r, ds, fs in os.walk(root, topdown=False):
            if r != root and not os.listdir(r):
                os.rmdir(r)

    print("\n%s%d notes: %d retimed, %d renamed, %d refiled, %d refs flagged"
          % ("DRY RUN " if args.dry_run else "", len(files), stats["retimed"],
             stats["renamed"], stats["moved"], stats["flagged"]))
    if stats["unmatched"]:
        print("%d note(s) had no matching Day One entry and were left alone."
              % stats["unmatched"])


# -------------------------------------------------------------------- main

def main():
    p = argparse.ArgumentParser(
        prog="dayone-import", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--db", help="Day One SQLite store (default: the installed one)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("journals", help="list Day One journals")
    s.set_defaults(func=cmd_journals)

    s = sub.add_parser("plan", help="report what would be imported")
    s.add_argument("journal")
    s.add_argument("--export", help="markdown export dir (extra media source)")
    s.add_argument("--json", help="also write the manifest here")
    s.set_defaults(func=cmd_plan)

    s = sub.add_parser("import", help="write entries into Apple Journal")
    s.add_argument("journal")
    s.add_argument("--into", help="target Apple Journal name (default: same)")
    s.add_argument("--export", help="markdown export dir (extra media source)")
    s.add_argument("--target-db", help="write to this store instead of the "
                                       "real one (sandbox rehearsal)")
    s.add_argument("--cli", default="journal-cli")
    s.add_argument("--time-mode", choices=["local", "utc"], default="local",
                   help="local (default) preserves the wall clock you "
                        "experienced; utc preserves the true instant")
    s.add_argument("--location-presentation", choices=["small", "large"],
                   default="small",
                   help="map size for imported locations (default: small). Journal "
                        "stores a hidden map only in an entry's CRDT, so there is no "
                        "'off' journal-cli can write")
    s.add_argument("--limit", type=int)
    s.add_argument("--state", help="import ledger (default: one per journal and "
                                   "destination under ~/.local/state/dayone-import)")
    s.add_argument("--max-failures", type=int, default=5)
    s.add_argument("--prune-backups", action="store_true",
                   help="trash the per-write store snapshots as they pile up")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_import)

    s = sub.add_parser("fix-locations",
                       help="correct imported entry locations from photo EXIF")
    s.add_argument("journal")
    s.add_argument("--export", help="markdown export dir (extra media source)")
    s.add_argument("--target-db", help="operate on a sandbox store instead")
    s.add_argument("--cli", default="journal-cli")
    s.add_argument("--state", help="import state file to map entries by")
    s.add_argument("--threshold", type=float, default=25.0,
                   help="km of disagreement before an entry is rewritten")
    s.add_argument("--skip", help="comma-separated Journal entry ids to leave alone")
    s.add_argument("--trust-exif", action="store_true",
                   help="override existing locations even when the Photos "
                        "library has no matching asset to corroborate them")
    s.add_argument("--prune-backups", action="store_true",
                   help="trash the per-write store snapshots as they pile up")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_fix_locations)

    s = sub.add_parser("fix-text",
                       help="re-render imported entries that still show raw Markdown")
    s.add_argument("journal")
    s.add_argument("--export", help="markdown export dir (extra media source)")
    s.add_argument("--target-db", help="operate on a sandbox store instead")
    s.add_argument("--cli", default="journal-cli")
    s.add_argument("--state", help="import state file to map entries by")
    s.add_argument("--max-failures", type=int, default=5)
    s.add_argument("--prune-backups", action="store_true",
                   help="trash the per-write store snapshots as they pile up")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_fix_text)

    s = sub.add_parser("fix-export",
                       help="repair timestamps in a Day One markdown export")
    s.add_argument("journal")
    s.add_argument("export")
    s.add_argument("--rename", action="store_true",
                   help="also rename/refile notes whose filename encodes the "
                        "wrong time (breaks existing links to them)")
    s.add_argument("--enrich", action="store_true",
                   help="add place/city/country/starred/transcription fields")
    s.add_argument("--flag-missing", action="store_true",
                   help="mark image refs Day One can no longer resolve")
    s.add_argument("--backup", default=os.path.expanduser("~/Backups/dayone-export"),
                   help="copy notes here first ('' to skip)")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_fix_export)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
