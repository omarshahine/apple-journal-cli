"""Regression tests for the dayone-import scripts.

Run:  python3 -m unittest discover -s skills/dayone-import/tests -v

Everything here is synthetic: a tiny Day One schema in a temp SQLite file,
hand-built JPEG bytes, and a stubbed journal-cli. Nothing touches Day One,
Photos, Apple Journal, or plugin-data.
"""
import datetime, importlib.util, io, json, os, shutil, sqlite3, struct, subprocess, sys, time
import tempfile, types, unittest, zoneinfo
from contextlib import redirect_stdout, redirect_stderr
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, SCRIPTS)

import dayone, exifgps, photoslib                       # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "dayone_import", os.path.join(SCRIPTS, "dayone-import.py"))
di = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(di)

CD = dayone.CD_EPOCH


# ------------------------------------------------------------------ fixtures

def make_dayone(path, entries, attachments=()):
    """entries: (pk, uuid, unix_ts, markdown); attachments: dict rows."""
    con = sqlite3.connect(path)
    con.executescript("""
        create table ZJOURNAL (Z_PK integer primary key, ZNAME text);
        create table ZLOCATION (Z_PK integer primary key, ZPLACENAME, ZLOCALITYNAME,
            ZADMINISTRATIVEAREA, ZCOUNTRY, ZLATITUDE, ZLONGITUDE, ZADDRESS);
        create table ZENTRY (Z_PK integer primary key, ZUUID, ZCREATIONDATE,
            ZMODIFIEDDATE, ZSTARRED, ZTIMEZONE, ZMARKDOWNTEXT, ZLOCATION, ZJOURNAL);
        create table ZATTACHMENT (Z_PK integer primary key, ZENTRY, ZIDENTIFIER,
            ZMD5, ZTYPE, ZFORMAT, ZDURATION, ZTRANSCRIPTION, ZORDERINENTRY);
        insert into ZJOURNAL values (1, 'Travel');
    """)
    for pk, uuid, ts, md in entries:
        con.execute("insert into ZENTRY values (?,?,?,NULL,0,NULL,?,NULL,1)",
                    (pk, uuid, ts - CD, md))
    for a in attachments:
        con.execute("""insert into ZATTACHMENT (ZENTRY, ZIDENTIFIER, ZMD5, ZTYPE,
                       ZFORMAT, ZDURATION, ZTRANSCRIPTION, ZORDERINENTRY)
                       values (:entry, :id, :md5, :type, :format, :duration,
                               :transcription, :order)""", a)
    con.commit()
    con.close()


def jpeg_with_gps(lat=(47, 36, 0), lon=(122, 20, 0)):
    """A minimal big-endian JPEG whose EXIF carries a GPS IFD (N, W)."""
    order = ">"
    # TIFF header + IFD0 with one entry (GPS pointer) at offset 8
    ifd0 = 8
    gps = ifd0 + 2 + 12 + 4
    entries_gps = 4
    data = gps + 2 + entries_gps * 12 + 4
    tiff = bytearray(b"MM" + struct.pack(order + "HI", 42, ifd0))
    tiff += struct.pack(order + "H", 1)
    tiff += struct.pack(order + "HHII", 0x8825, 4, 1, gps)
    tiff += struct.pack(order + "I", 0)
    tiff += struct.pack(order + "H", entries_gps)
    tiff += struct.pack(order + "HHI", 0x0001, 2, 2) + b"N\x00\x00\x00"
    tiff += struct.pack(order + "HHII", 0x0002, 5, 3, data)
    tiff += struct.pack(order + "HHI", 0x0003, 2, 2) + b"W\x00\x00\x00"
    tiff += struct.pack(order + "HHII", 0x0004, 5, 3, data + 24)
    tiff += struct.pack(order + "I", 0)
    for v in lat + lon:
        tiff += struct.pack(order + "II", v, 1)
    app1 = b"Exif\x00\x00" + bytes(tiff)
    return b"\xff\xd8" + b"\xff\xe1" + struct.pack(">H", len(app1) + 2) + app1 + b"\xff\xd9"


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dayone-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def p(self, *parts):
        return os.path.join(self.tmp, *parts)


# ------------------------------------------------------------------ snapshots

class SnapshotTests(Tmp):
    def _wal_db(self):
        db = self.p("live.sqlite")
        con = sqlite3.connect(db)
        con.execute("pragma journal_mode=wal")
        con.execute("create table t(x)")
        con.execute("insert into t values ('checkpointed')")
        con.commit()
        con.execute("pragma wal_checkpoint(truncate)")
        return db, con

    def test_snapshot_sees_wal_only_changes(self):
        db, writer = self._wal_db()
        writer.execute("pragma wal_autocheckpoint=0")
        writer.execute("insert into t values ('wal-only')")
        writer.commit()                      # writer stays open: change lives in -wal
        self.addCleanup(writer.close)
        with dayone.snapshot_connect(db, prefix="dayone-test-snap-") as con:
            got = sorted(r[0] for r in con.execute("select x from t"))
            snap_dir = con.snapshot_dir
            # one self-contained file: no -wal to pair with, rollback journal mode
            self.assertNotIn("live.sqlite-wal", os.listdir(snap_dir))
            self.assertEqual(con.execute("pragma journal_mode").fetchone()[0], "delete")
        self.assertEqual(got, ["checkpointed", "wal-only"])
        self.assertFalse(os.path.exists(snap_dir), "snapshot folder left behind")

    def test_close_removes_snapshot_folder(self):
        db, writer = self._wal_db()
        writer.close()
        con = dayone.snapshot_connect(db, prefix="dayone-test-snap-")
        d = con.snapshot_dir
        self.assertTrue(os.path.isdir(d))
        con.close()
        self.assertFalse(os.path.exists(d))

    def test_failed_snapshot_leaves_nothing(self):
        bad = self.p("not-a-db.sqlite")
        with open(bad, "wb") as fh:
            fh.write(b"this is not sqlite" * 100)
        before = set(os.listdir(tempfile.gettempdir()))
        with self.assertRaises(sqlite3.Error):
            dayone.snapshot_connect(bad, prefix="dayone-test-fail-")
        after = set(os.listdir(tempfile.gettempdir()))
        self.assertFalse([d for d in after - before if d.startswith("dayone-test-fail-")])

    def test_gather_closes_its_connection(self):
        db = self.p("DayOne.sqlite")
        make_dayone(db, [(1, "A" * 32, 1700000000, "Hello\nbody")])
        made = []
        real = dayone.snapshot_connect

        def spy(*a, **kw):
            con = real(*a, **kw)
            made.append(con.snapshot_dir)
            return con
        args = types.SimpleNamespace(db=db, journal="Travel", export=None)
        with mock.patch.object(dayone, "snapshot_connect", spy):
            di.gather(args)
        self.assertEqual(len(made), 1)
        self.assertFalse(os.path.exists(made[0]), "gather leaked its snapshot")

    def test_photos_library_snapshot_and_unreadable_library(self):
        lib = self.p("Lib.photoslibrary")
        os.makedirs(os.path.join(lib, "database"))
        with open(os.path.join(lib, "database", "Photos.sqlite"), "wb") as fh:
            fh.write(b"garbage" * 100)
        with redirect_stderr(io.StringIO()) as err:
            self.assertIsNone(photoslib.connect(lib))
        self.assertIn("could not read the Photos library", err.getvalue())

        good = self.p("Good.photoslibrary")
        os.makedirs(os.path.join(good, "database"))
        sqlite3.connect(os.path.join(good, "database", "Photos.sqlite")).execute(
            "create table ZASSET(x)").connection.commit()
        con = photoslib.connect(good)
        d = con.snapshot_dir
        con.close()
        self.assertFalse(os.path.exists(d))

    def test_match_rejects_an_invalid_wall_clock(self):
        con = sqlite3.connect(":memory:")
        self.assertIsNone(photoslib.match(con, "0000-00-00 00:00:00", 47.6, -122.3))


# ----------------------------------------------------------------------- EXIF

class ExifTests(Tmp):
    def _write(self, name, data):
        f = self.p(name)
        with open(f, "wb") as fh:
            fh.write(data)
        return f

    def test_valid_gps_reads(self):
        g = exifgps.read(self._write("ok.jpg", jpeg_with_gps()))
        self.assertAlmostEqual(g["lat"], 47.6, places=3)
        self.assertAlmostEqual(g["lon"], -122.3333, places=3)

    def test_truncated_tiff_does_not_raise(self):
        app1 = b"Exif\x00\x00MM\x00"            # header cut short
        data = b"\xff\xd8\xff\xe1" + struct.pack(">H", len(app1) + 2) + app1
        self.assertEqual(exifgps.read(self._write("bad.jpg", data)), {})

    def test_bad_pointer_does_not_raise(self):
        app1 = b"Exif\x00\x00" + b"MM" + struct.pack(">HI", 42, 8) + \
            struct.pack(">H", 1) + struct.pack(">HHII", 0x8825, 4, 1, 0xFFFFFFF0)
        data = b"\xff\xd8\xff\xe1" + struct.pack(">H", len(app1) + 2) + app1
        self.assertEqual(exifgps.read(self._write("ptr.jpg", data)), {})

    def test_one_bad_photo_does_not_stop_the_entry(self):
        bad = self._write("bad.jpg", b"\xff\xd8\xff\xe1\x00\x0cExif\x00\x00MM")
        good = self._write("good.jpg", jpeg_with_gps())
        got = di._photo_fix({"media": [bad, good], "local": "2024-01-01 10:00:00"})
        self.assertIsNotNone(got)
        self.assertAlmostEqual(got["lat"], 47.6, places=3)

    def test_invalid_capture_date_is_dropped(self):
        self.assertFalse(exifgps._valid_when("0000-00-00 00:00:00"))
        self.assertTrue(exifgps._valid_when("2024-01-02 03:04:05"))


# ----------------------------------------------------------------------- text

class TextTests(Tmp):
    def entries(self, md, attachments=(), media=None):
        db = tempfile.mktemp(suffix=".sqlite", dir=self.tmp)
        make_dayone(db, [(1, "E" * 32, 1700000000, md)], attachments)
        with dayone.connect(db) as con:
            return dayone.read_entries(con, 1, media or {})

    def test_fenced_rule_survives_flattening(self):
        self.assertEqual(dayone.markdown_to_text("```\n---\n```"), "---")
        e = self.entries("Title\n```\n---\n```")[0]
        self.assertEqual(e["body"], "---")

    def test_longer_fence_keeps_a_shorter_fence_as_content(self):
        md = "````\n```\n---\n````"
        self.assertEqual(dayone.markdown_to_text(md), "```\n---")
        # A first line of the entry's own UUID is how Day One marks "untitled",
        # so the body alone must carry the entry.
        e = self.entries("E" * 32 + "\n" + md)[0]
        self.assertIsNone(e["title"])
        self.assertEqual(e["body"], "```\n---")
        self.assertTrue(di.has_content(e), e)

    def test_fenced_content_keeps_blank_lines_and_hashes(self):
        out = dayone.markdown_to_text("```\n# keep\n\nx\n```")
        self.assertEqual(out, "# keep\n\nx")

    def test_literal_leading_hash_title_is_kept(self):
        self.assertEqual(self.entries("#travel\nTrip notes")[0]["title"], "#travel")
        self.assertEqual(self.entries("#\nbody")[0]["title"], "#")
        e = self.entries("###### Travel\nbody")[0]
        self.assertEqual((e["title"], e["title_md"]), ("Travel", "Travel"))

    def test_unreferenced_attachments_are_classified(self):
        atts = [
            {"entry": 1, "id": "P" * 32, "md5": "a" * 32, "type": "photo",
             "format": "jpeg", "duration": None, "transcription": None, "order": 0},
            {"entry": 1, "id": "Q" * 32, "md5": "b" * 32, "type": None,
             "format": "aac", "duration": 12.0, "transcription": "hi", "order": 1},
        ]
        e = self.entries("Just text", atts)[0]
        self.assertEqual([m["uuid"] for m in e["missing"]], ["P" * 32])
        self.assertEqual(e["missing"][0]["reason"], "media not downloaded")
        self.assertEqual([a["uuid"] for a in e["audio"]], ["Q" * 32])
        self.assertEqual(e["media"], [])


# --------------------------------------------------------------------- import

class FakeCLI:
    """Stands in for journal-cli.

    `render` echoes its input (enough to make content fingerprints line up),
    `write` reads --date as a wall clock in the current zone like the real
    CLI and appends to `store`, and `list` prints each entry's date in the
    *current* zone, so a timezone change between runs shows up as it would.
    """

    def __init__(self, die_on_write=None, fail_after_commit=None):
        self.store, self.writes = [], []
        self.die_on_write = die_on_write              # raise mid-write (killed)
        self.fail_after_commit = fail_after_commit    # commit, then exit 1
        self.next_pk = 100

    def add(self, date, title="", text="", pk=None):
        pk = pk if pk is not None else self.next_pk
        self.next_pk = max(self.next_pk, pk + 1)
        self.store.append({"id": pk, "epoch": di._wall_epoch(date),
                           "title": title, "text": text})
        return pk

    def __call__(self, cmd, *a, **kw):
        args = list(cmd[1:])
        if args[:1] == ["--db"]:
            args = args[2:]
        verb = args[0]
        if verb == "render":
            return subprocess.CompletedProcess(cmd, 0, kw.get("input") or b"", b"")
        if verb == "write" and "--dry-run" in args:
            return subprocess.CompletedProcess(cmd, 0, "", "")
        if verb == "write":
            self.writes.append(args)
            if self.die_on_write and len(self.writes) == self.die_on_write:
                raise KeyboardInterrupt          # run killed mid-write

            def get(flag):
                return args[args.index(flag) + 1] if flag in args else ""
            pk = self.add(get("--date"), get("--title"), get("--body"))
            if self.fail_after_commit and len(self.writes) == self.fail_after_commit:
                return subprocess.CompletedProcess(cmd, 1, "", "killed after commit")
            return subprocess.CompletedProcess(cmd, 0, "Created entry %d." % pk, "")
        if verb == "list":
            rows = [{"id": r["id"], "title": r["title"], "text": r["text"],
                     "date": time.strftime("%Y-%m-%d %H:%M:%S",
                                           time.localtime(r["epoch"]))}
                    for r in self.store]
            return subprocess.CompletedProcess(cmd, 0, json.dumps(rows), "")
        raise AssertionError("unexpected journal-cli call: %r" % cmd)


def set_tz(name):
    os.environ["TZ"] = name
    time.tzset()


class ImportTests(Tmp):
    def setUp(self):
        super().setUp()
        self.db = self.p("DayOne.sqlite")
        make_dayone(self.db, [
            (1, "A" * 32, 1700000000, "First\nbody one"),
            (2, "B" * 32, 1700003600, "Second\nbody two"),
            (3, "C" * 32, 1700007200, "Third\nbody three"),
        ])
        self.state_dir = self.p("state")
        for k, v in (("STATE_DIR", self.state_dir),
                     ("PLUGIN_DATA", self.p("no-plugin-data"))):
            patcher = mock.patch.object(di, k, v)
            patcher.start()
            self.addCleanup(patcher.stop)
        env = mock.patch.dict(os.environ)
        env.start()
        self.addCleanup(time.tzset)
        self.addCleanup(env.stop)
        os.environ.pop("JOURNAL_DB", None)
        set_tz("America/Los_Angeles")

    def args(self, **kw):
        base = dict(db=self.db, journal="Travel", into="Staging", export=None,
                    target_db=None, cli="journal-cli", time_mode="local",
                    location_presentation="small", limit=None, state=None,
                    max_failures=5, prune_backups=False, dry_run=False)
        base.update(kw)
        return types.SimpleNamespace(**base)

    def run_import(self, cli, **kw):
        with mock.patch.object(di.subprocess, "run", cli), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            di.cmd_import(self.args(**kw))

    def ledger(self, **kw):
        with open(di.ledger_path(self.args(**kw), "Travel")) as fh:
            return json.load(fh)

    def kill_second_write_after_it_lands(self, cli):
        """Run until the 2nd write, then store it as if it had committed."""
        with self.assertRaises(KeyboardInterrupt):
            self.run_import(cli)
        w = cli.writes[1]
        cli.add(w[w.index("--date") + 1], w[w.index("--title") + 1],
                w[w.index("--body") + 1])
        cli.die_on_write = None

    def test_interrupted_import_does_not_replay(self):
        cli = FakeCLI(die_on_write=2)
        self.kill_second_write_after_it_lands(cli)
        self.assertEqual(self.ledger()["done"], {"A" * 32: 100})   # recorded at once
        self.run_import(cli)
        self.assertEqual(len(cli.writes), 3)       # A, B (killed), C -- no repeat
        led = self.ledger()
        self.assertEqual(led["done"], {"A" * 32: 100, "B" * 32: 101, "C" * 32: 102})
        self.assertEqual(led["pending"], {})

    def test_pending_write_that_never_landed_is_retried(self):
        cli = FakeCLI(die_on_write=1)
        with self.assertRaises(KeyboardInterrupt):
            self.run_import(cli)
        cli.die_on_write = None
        cli.writes.clear()
        self.run_import(cli)
        self.assertEqual(len(cli.writes), 3)

    # Greptile P1: date alone is not identity
    def test_resume_does_not_claim_an_unrelated_entry_at_the_same_time(self):
        cli = FakeCLI(die_on_write=2)
        # B's wall clock as the import will pass it (entries with no zone use UTC)
        when = datetime.datetime.fromtimestamp(
            1700003600, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        # Same instant and content, but already in the store before this run:
        # below the run's floor, so not it.
        cli.add(when, "Second", "body two", pk=50)
        with self.assertRaises(KeyboardInterrupt):
            self.run_import(cli)
        cli.die_on_write = None
        self.assertEqual(cli.writes[1][cli.writes[1].index("--date") + 1], when)
        # Same instant, different content, newer than the floor: not it either.
        other = cli.add(when, "Someone else's entry", "written by hand")
        self.run_import(cli)
        led = self.ledger()
        self.assertEqual(len(cli.writes), 4, "B should be written again")
        self.assertNotIn(led["done"]["B" * 32], (50, other))

    # Greptile P1: a timezone change between the kill and the resume
    def test_resume_after_a_timezone_change_does_not_duplicate(self):
        cli = FakeCLI(die_on_write=2)
        self.kill_second_write_after_it_lands(cli)
        set_tz("Asia/Tokyo")                       # list now prints other wall clocks
        self.run_import(cli)
        self.assertEqual(len(cli.writes), 3, "the landed entry was written twice")
        self.assertEqual(self.ledger()["done"]["B" * 32], 101)

    # Greptile P1: $JOURNAL_DB picks the store when --target-db is absent
    def test_journal_db_sandbox_gets_its_own_ledger(self):
        sandbox = self.p("env-sandbox.sqlite")
        os.environ["JOURNAL_DB"] = sandbox
        self.assertEqual(di._target_id(None), os.path.realpath(sandbox))
        self.assertFalse(di.is_live(None))
        cli = FakeCLI()
        self.run_import(cli)
        self.assertNotIn("--live", cli.writes[0])
        led_path = di.ledger_path(self.args(), "Travel")
        self.assertIn(".sandbox-", os.path.basename(led_path))
        os.environ.pop("JOURNAL_DB")
        self.assertNotEqual(di.ledger_path(self.args(), "Travel"), led_path)
        # ...and a $JOURNAL_DB that is the real store is live.
        os.environ["JOURNAL_DB"] = di.REAL_STORE
        self.assertTrue(di.is_live(None))

    # Greptile P1: a nonzero exit after the commit must not lose the record
    def test_nonzero_exit_after_commit_is_recorded_as_done(self):
        cli = FakeCLI(fail_after_commit=2)
        self.run_import(cli)
        led = self.ledger()
        self.assertEqual(led["done"]["B" * 32], 101)
        self.assertNotIn("B" * 32, led["failed"])
        self.assertEqual(led["pending"], {})
        self.run_import(cli)                       # a re-run writes nothing more
        self.assertEqual(len(cli.writes), 3)

    def test_nonzero_exit_that_did_not_land_is_a_failure(self):
        cli = FakeCLI()

        def failing(cmd, *a, **kw):
            if "write" in cmd and "--dry-run" not in cmd and "Second" in cmd:
                cli.writes.append(cmd)
                return subprocess.CompletedProcess(cmd, 1, "", "boom")
            return cli(cmd, *a, **kw)
        self.run_import(failing)
        led = self.ledger()
        self.assertIn("B" * 32, led["failed"])
        self.assertEqual(led["pending"], {})
        self.assertNotIn("B" * 32, led["done"])

    def test_rehearsal_and_live_keep_separate_ledgers(self):
        sandbox = self.p("sandbox", "moments.sqlite")
        os.makedirs(os.path.dirname(sandbox))
        rehearsal = FakeCLI()
        self.run_import(rehearsal, target_db=sandbox)
        self.assertEqual(len(rehearsal.writes), 3)
        live = FakeCLI()
        self.run_import(live)
        self.assertEqual(len(live.writes), 3, "live run skipped rehearsal entries")
        self.assertNotEqual(di.ledger_path(self.args(target_db=sandbox), "Travel"),
                            di.ledger_path(self.args(), "Travel"))

    def test_ledger_for_another_destination_is_refused(self):
        sandbox = self.p("sb.sqlite")
        self.run_import(FakeCLI(), target_db=sandbox,
                        state=self.p("shared.json"))
        with self.assertRaises(SystemExit):
            with redirect_stderr(io.StringIO()):
                di.load_state(self.p("shared.json"), "Travel", None)
        with self.assertRaises(SystemExit):
            with redirect_stderr(io.StringIO()):
                di.load_state(self.p("shared.json"), "Other Journal", sandbox)

    def _legacy_ledger(self, done):
        """A ledger in the pre-tagging format, at the live ledger's path."""
        path = di.ledger_path(self.args(), "Travel")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump({"done": done, "failed": {}}, fh)
        return path

    def _local_date(self, uuid):
        with dayone.connect(self.db) as con:
            j = dayone.resolve_journal(con, "Travel")
            return {e["uuid"]: e["local"] for e in dayone.read_entries(con, j["pk"], {})}[uuid]

    def test_legacy_rehearsal_ledger_is_refused_by_a_live_import(self):
        # Before ledgers were tagged, a rehearsal wrote sandbox ids into the
        # live filename. Entry 42 in the real store is something else.
        self._legacy_ledger({"A" * 32: 42})
        cli = FakeCLI()
        cli.add("2020-01-01 00:00:00", "unrelated", "x", pk=42)
        with self.assertRaises(SystemExit):
            self.run_import(cli)
        self.assertEqual(cli.writes, [])

    def test_legacy_live_ledger_is_adopted_when_it_matches(self):
        path = self._legacy_ledger({"A" * 32: 100})
        cli = FakeCLI()
        cli.add(self._local_date("A" * 32), "First", "body one", pk=100)
        self.run_import(cli)
        self.assertEqual(len(cli.writes), 2)          # B and C only
        with open(path) as fh:
            led = json.load(fh)
        self.assertEqual(led["meta"]["target"], "live")
        self.assertNotIn("_legacy", led)

    def test_legacy_mapping_to_a_different_entry_a_quarter_hour_off_is_refused(self):
        # Instant alone could line up by chance; the words cannot.
        self._legacy_ledger({"A" * 32: 42})
        cli = FakeCLI()
        cli.add(self._local_date("A" * 32), "Groceries", "milk and eggs", pk=42)
        cli.store[-1]["epoch"] += 900
        with self.assertRaises(SystemExit):
            self.run_import(cli)
        self.assertEqual(cli.writes, [])

    def test_legacy_ledger_written_as_raw_markdown_is_adopted(self):
        # Early imports wrote Day One's Markdown through as plain text.
        self._legacy_ledger({"A" * 32: 100})
        cli = FakeCLI()
        cli.add(self._local_date("A" * 32), "# First", "**body** one", pk=100)
        self.run_import(cli)
        self.assertEqual(len(cli.writes), 2)

    def test_idless_marks_are_confirmed_or_dropped(self):
        path = self._legacy_ledger({"A" * 32: 100, "B" * 32: True, "C" * 32: True})
        cli = FakeCLI()
        cli.add(self._local_date("A" * 32), "First", "body one", pk=100)
        cli.add(self._local_date("B" * 32), "Second", "body two", pk=101)
        self.run_import(cli)
        # B is found and gets its id; C was never written, so it is imported.
        self.assertEqual(len(cli.writes), 1)
        with open(path) as fh:
            done = json.load(fh)["done"]
        self.assertEqual(done["B" * 32], 101)
        self.assertEqual(type(done["C" * 32]), int)

    def test_shared_title_with_different_body_is_not_the_same_entry(self):
        self._legacy_ledger({"A" * 32: 42})
        cli = FakeCLI()
        cli.add(self._local_date("A" * 32), "First", "bread and coffee", pk=42)
        cli.store[-1]["epoch"] += 900
        with self.assertRaises(SystemExit):
            self.run_import(cli)
        self.assertEqual(cli.writes, [])

    def test_renumbered_list_still_matches(self):
        # Journal renders "7. Walked home" as a list item numbered from 1.
        db = self.p("list.sqlite")
        make_dayone(db, [(1, "D" * 32, 1700000000,
                          "D" * 32 + "\n7. Walked home\n8. Cooked dinner")])
        with dayone.connect(db) as con:
            e = dayone.read_entries(con, dayone.resolve_journal(con, "Travel")["pk"], {})[0]
        self.assertIsNone(e["title"])
        row = {"title": "", "text": "1. Walked home\n2. Cooked dinner"}
        self.assertTrue(di._same_content(row, e))
        self.assertFalse(di._same_content({"title": "", "text": "1. Slept in"}, e))

    def test_shared_opening_with_different_ending_is_not_the_same_entry(self):
        db = self.p("intro.sqlite")
        body = "Dear diary, today I woke up early and went for a long walk by the lake"
        make_dayone(db, [(1, "D" * 32, 1700000000, "D" * 32 + "\n" + body + " and swam.")])
        with dayone.connect(db) as con:
            e = dayone.read_entries(con, dayone.resolve_journal(con, "Travel")["pk"], {})[0]
        self.assertTrue(di._same_content({"title": "", "text": body + " and swam."}, e))
        self.assertFalse(di._same_content({"title": "", "text": body + " and then ate pancakes."}, e))

    def test_a_mapping_off_the_ledgers_shift_is_refused(self):
        # A and B line up exactly; C's entry is a quarter hour off. One import
        # ran in one zone, so C is not that import's write.
        self._legacy_ledger({"A" * 32: 100, "B" * 32: 101, "C" * 32: 102})
        cli = FakeCLI()
        cli.add(self._local_date("A" * 32), "First", "body one", pk=100)
        cli.add(self._local_date("B" * 32), "Second", "body two", pk=101)
        cli.add(self._local_date("C" * 32), "Third", "body three", pk=102)
        cli.store[-1]["epoch"] += 900
        with self.assertRaises(SystemExit):
            self.run_import(cli)
        self.assertEqual(cli.writes, [])

    def test_dst_offsets_from_one_import_zone_are_accepted(self):
        # Imported in Los Angeles, checked in UTC: winter entries are 8h off,
        # summer ones 7h. Same import, same zone.
        os.environ["TZ"] = "UTC"; time.tzset()
        self.addCleanup(lambda: (os.environ.pop("TZ", None), time.tzset()))
        la = zoneinfo.ZoneInfo("America/Los_Angeles")
        e1 = {"local": "2023-01-10 09:00:00", "utc": "2023-01-10 17:00:00",
              "title": "Winter", "body": "cold walk"}
        e2 = {"local": "2023-07-10 09:00:00", "utc": "2023-07-10 16:00:00",
              "title": "Summer", "body": "warm walk"}
        def at(e):
            n = datetime.datetime.strptime(e["local"], "%Y-%m-%d %H:%M:%S")
            return int(n.replace(tzinfo=la).timestamp())
        rows = [{"id": 1, "epoch": at(e1), "title": "Winter", "text": "cold walk"},
                {"id": 2, "epoch": at(e2), "title": "Summer", "text": "warm walk"}]
        zones = di._import_zones(list(zip([e1, e2], rows)))
        for e, row in zip([e1, e2], rows):     # both writes are explained
            self.assertTrue(any(di._wrote_at(row["epoch"], e, z) for z in zones), zones)
        # Without the UTC strings to lean on, Los Angeles is what explains both.
        e1u, e2u = dict(e1, utc=None), dict(e2, utc=None)
        self.assertIn(("local", "America/Los_Angeles"),
                      di._import_zones(list(zip([e1u, e2u], rows))))
        stray = dict(rows[1], epoch=rows[1]["epoch"] + 900)
        self.assertFalse(any(di._wrote_at(stray["epoch"], e2, z) for z in zones))

    def test_legacy_ledger_survives_a_timezone_change(self):
        # Imported in one zone, verified in another: still the same write.
        path = self._legacy_ledger({"A" * 32: 100})
        cli = FakeCLI()
        local = self._local_date("A" * 32)
        cli.add(local, "First", "body one", pk=100)
        # The import ran while the Mac was set to Tokyo: --date was read there.
        naive = datetime.datetime.strptime(local, "%Y-%m-%d %H:%M:%S")
        cli.store[-1]["epoch"] = int(naive.replace(
            tzinfo=zoneinfo.ZoneInfo("Asia/Tokyo")).timestamp())
        self.run_import(cli)
        self.assertEqual(len(cli.writes), 2)

    def test_legacy_ledger_with_only_idless_marks_is_refused(self):
        self._legacy_ledger({"A" * 32: True, "B" * 32: True})
        cli = FakeCLI()
        with self.assertRaises(SystemExit):
            self.run_import(cli)
        self.assertEqual(cli.writes, [])

    def test_older_tag_gains_the_source_on_a_repair(self):
        path = di.ledger_path(self.args(), "Travel")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump({"done": {"A" * 32: 100}, "failed": {}, "pending": {},
                       "meta": {"journal": "Travel", "target": "live"}}, fh)
        state = di.load_state(path, "Travel", None, self.db)
        di.verify_legacy(self.args(), state, path, [])
        with open(path) as fh:
            self.assertEqual(json.load(fh)["meta"]["source"], di._source_id(self.db))

    def test_ledger_from_another_day_one_store_is_refused(self):
        self.run_import(FakeCLI())
        with self.assertRaises(SystemExit):
            with redirect_stderr(io.StringIO()):
                di.load_state(di.ledger_path(self.args(), "Travel"), "Travel",
                              None, self.p("other-DayOne.sqlite"))

    def test_relative_state_path_works(self):
        cwd = os.getcwd()
        os.chdir(self.tmp)
        self.addCleanup(os.chdir, cwd)
        self.run_import(FakeCLI(), state="ledger.json")
        self.assertTrue(os.path.exists(self.p("ledger.json")))

    def test_unwritable_ledger_stops_before_any_write(self):
        blocker = self.p("blocker")
        open(blocker, "w").close()
        cli = FakeCLI()
        with self.assertRaises(SystemExit):
            self.run_import(cli, state=os.path.join(blocker, "ledger.json"))
        self.assertEqual(cli.writes, [])

    def test_body_is_sent_from_raw_markdown(self):
        make_dayone(self.p("fenced.sqlite"), [(1, "F" * 32, 1700000000,
                                               "Title\n```\n---\n```")])
        cli = FakeCLI()
        self.run_import(cli, db=self.p("fenced.sqlite"))
        w = cli.writes[0]
        self.assertEqual(w[w.index("--body") + 1], "```\n---\n```")


if __name__ == "__main__":
    unittest.main()
