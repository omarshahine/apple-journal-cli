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

# A second journal named "Test Journal" so journal-targeting tests run. The
# name lives in the CRDT blob as the printable string preceding "title".
blob = b"crdt\x00" + b"Test Journal" + b"\x00" + b"title" + b"\x00"
db.execute("""insert into ZJOURNALMO
              (Z_PK, Z_ENT, Z_OPT, ZISUPLOADEDTOCLOUD, ZSORTCATEGORY, ZSORTORDER, ZUSERDELETED,
               ZID, ZMERGEABLEATTRIBUTES)
              values (2, 6, 1, 1, 0, 0, 0, ?, ?)""",
           (uuid.uuid4().bytes, blob))
db.execute("update Z_PRIMARYKEY set Z_MAX=2 where Z_NAME='JournalMO'")
db.commit()
