"""Regression tests for the dayone-import scripts.

Run:  python3 -m unittest discover -s skills/dayone-import/tests -v

Everything here is synthetic: a tiny Day One schema in a temp SQLite file,
hand-built JPEG bytes, and a stubbed journal-cli. Nothing touches Day One,
Photos, Apple Journal, or plugin-data.
"""
import importlib.util, io, json, os, shutil, sqlite3, struct, subprocess, sys
import tempfile, types, unittest
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
    """Stands in for journal-cli. Writes append to `store`; list returns it."""

    def __init__(self, die_on_write=None):
        self.store, self.writes, self.die_on_write = [], [], die_on_write

    def __call__(self, cmd, *a, **kw):
        args = list(cmd[1:])
        if args[:1] == ["--db"]:
            args = args[2:]
        verb = args[0]
        if verb == "render":
            return subprocess.CompletedProcess(cmd, 0, b"x", b"")
        if verb == "write" and "--dry-run" in args:
            return subprocess.CompletedProcess(cmd, 0, "", "")
        if verb == "write":
            self.writes.append(args)
            if self.die_on_write and len(self.writes) == self.die_on_write:
                raise KeyboardInterrupt          # run killed mid-write
            pk = len(self.store) + 100
            self.store.append({"id": pk, "date": args[args.index("--date") + 1],
                               "title": ""})
            return subprocess.CompletedProcess(cmd, 0, "Created entry %d." % pk, "")
        if verb == "list":
            return subprocess.CompletedProcess(cmd, 0, json.dumps(self.store), "")
        raise AssertionError("unexpected journal-cli call: %r" % cmd)


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

    def test_interrupted_import_does_not_replay(self):
        cli = FakeCLI(die_on_write=2)
        with self.assertRaises(KeyboardInterrupt):
            self.run_import(cli)
        # The first write was recorded the moment it succeeded.
        ledger = json.load(open(di.ledger_path(self.args(), "Travel")))
        self.assertEqual(ledger["done"], {"A" * 32: 100})
        # The second write landed in the store before the kill; resume must
        # reconcile it rather than write it again.
        cli.store.append({"id": 101, "date": cli.writes[1][cli.writes[1].index("--date") + 1],
                          "title": ""})
        cli.die_on_write = None
        self.run_import(cli)
        dates = [w[w.index("--date") + 1] for w in cli.writes]
        self.assertEqual(len(dates), 3, dates)       # A, B (killed), C -- no repeat
        ledger = json.load(open(di.ledger_path(self.args(), "Travel")))
        self.assertEqual(ledger["done"], {"A" * 32: 100, "B" * 32: 101, "C" * 32: 102})
        self.assertEqual(ledger["pending"], {})

    def test_pending_write_that_never_landed_is_retried(self):
        cli = FakeCLI(die_on_write=1)
        with self.assertRaises(KeyboardInterrupt):
            self.run_import(cli)
        cli.die_on_write = None
        cli.writes.clear()
        self.run_import(cli)
        self.assertEqual(len(cli.writes), 3)

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
