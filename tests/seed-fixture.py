"""Seed the schema-only fixture: Core Data bookkeeping plus two journals.

Contains zero personal data. Invoked by make-fixture.sh.
"""
import sqlite3, sys, uuid

db = sqlite3.connect(sys.argv[1])

# Core Data primary-key bookkeeping the CLI relies on
for ent, name in [(1, "AppStorageMO"),
                  (2, "JournalEntryAssetAttachmentMO"),
                  (3, "JournalEntryAssetFileAttachmentMO"),
                  (4, "JournalEntryAssetMO"),
                  (5, "JournalEntryMO"),
                  (6, "JournalMO"),
                  (7, "SyncDataMO")]:
    db.execute("insert into Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) values (?,?,0,0)",
               (ent, name))

# The built-in default journal: no CRDT blob, negative sort category
db.execute("""insert into ZJOURNALMO
              (Z_PK, Z_ENT, Z_OPT, ZISUPLOADEDTOCLOUD, ZSORTCATEGORY, ZSORTORDER, ZUSERDELETED, ZID)
              values (1, 6, 1, 1, -10, 1, 0, ?)""",
           (uuid.UUID("01000000-0000-0000-0000-000000000000").bytes,))

def _len_delimited(field, payload):
    """One protobuf length-delimited record: tag byte, varint length, bytes."""
    out = bytearray([(field << 3) | 2])
    n = len(payload)
    while True:
        b = n & 0x7f
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            break
    return bytes(out) + payload


def journal_crdt(name, color="Blue", icon="book.fill"):
    """A CRDT attribute blob shaped the way Journal.app writes one.

    Real blobs are an 8-byte "crdt" + version header followed by protobuf.
    The attributes live in the field 6 submessage: 48 bytes of replica ids
    (field 1), then the values and their keys alternating as length-delimited
    strings (field 2) -- "Test Journal", "title", "Blue", "color", and so on.

    Worth encoding faithfully rather than approximating: a fixture that only
    lays printable words next to each other will pass for a parser that scans
    for printable runs while telling you nothing about whether real blobs
    still decode.
    """
    body = _len_delimited(1, b"\x00" * 48)
    for s in (name, "title", color, "color", icon, "icon"):
        body += _len_delimited(2, s.encode("utf-8"))
    return b"crdt\x07\x00\x00\x00" + _len_delimited(6, body)


# A second journal named "Test Journal" so journal-targeting tests run.
blob = journal_crdt("Test Journal")
db.execute("""insert into ZJOURNALMO
              (Z_PK, Z_ENT, Z_OPT, ZISUPLOADEDTOCLOUD, ZSORTCATEGORY, ZSORTORDER, ZUSERDELETED,
               ZID, ZMERGEABLEATTRIBUTES)
              values (2, 6, 1, 1, 0, 0, 0, ?, ?)""",
           (uuid.uuid4().bytes, blob))
# A third journal with a two-character name. Short names are the case a
# printable-run scan of the blob gets wrong: too short to survive the scan's
# minimum run length, so the name silently becomes whichever bytes of the
# neighbouring replica ids happen to be printable.
db.execute("""insert into ZJOURNALMO
              (Z_PK, Z_ENT, Z_OPT, ZISUPLOADEDTOCLOUD, ZSORTCATEGORY, ZSORTORDER, ZUSERDELETED,
               ZID, ZMERGEABLEATTRIBUTES)
              values (3, 6, 1, 1, 0, 0, 0, ?, ?)""",
           (uuid.uuid4().bytes, journal_crdt("TV", color="Sand", icon="sparkles.tv.fill")))
db.execute("update Z_PRIMARYKEY set Z_MAX=3 where Z_NAME='JournalMO'")
db.commit()
