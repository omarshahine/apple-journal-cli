# journal-cli

Read and write Apple Journal entries from the terminal, straight from the app's
own Core Data store.

## Why this exists

Journal has no public SDK, no AppleScript dictionary, and no export format worth
scripting against. Every tool on GitHub works from the app's HTML export zip.

But the entries are sitting in a plain SQLite database:

```
~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite
```

"moments" is Journal's internal codename, which is why searching for "journal"
never finds it. Entry bodies are **plain RTF** in `ZJOURNALENTRYMO.ZTEXT` — not
encrypted. The encrypted CloudKit records in
`~/Library/Containers/com.apple.journal/Data/CloudKit/` are just the sync cache
sitting next to the real data.

Requires **Full Disk Access** for your terminal.

## Install

```sh
ln -s "$PWD/journal-cli" ~/.local/bin/journal-cli
journal-cli doctor
```

## Reading

Reads run against a temp snapshot of `db` + `-wal` + `-shm`, so the live store is
never locked or modified. Safe to run while Journal is open.

```sh
journal-cli list --limit 20
journal-cli list --since 2025-01-01 --full
journal-cli show 95
journal-cli search anguilla
journal-cli export --dir ~/journal-export             # one .md per entry
journal-cli export --dir ~/journal-export --format json
journal-cli stats
```

`show` resolves attachment paths to real files under `Library/Attachments/`.

List markers: `*` bookmarked, `+` not yet synced to iCloud, ` ` normal.

## Writing

Writing is opt-in and guarded. Against the real store, `journal-cli`:

1. refuses to run without `--live`
2. refuses to run while Journal.app is open
3. takes a timestamped backup to `~/Backups/journal-cli/` first

```sh
# make a scratch copy and experiment there
DB=$(journal-cli sandbox --dir /tmp/jtest)
journal-cli --db "$DB" write --title "Test" --body "Hello."
journal-cli --db "$DB" list --limit 3

# the real thing
journal-cli write --live --title "Monday" --body "..." 
journal-cli delete 103 --live          # soft delete (Recently Deleted)
journal-cli delete 103 --live --hard   # remove the row
```

A written row gets a fresh `Z_PK`, a bumped `Z_PRIMARYKEY.Z_MAX`, a 16-byte UUID
`ZID`, RTF body via `textutil`, and `ZISUPLOADEDTOCLOUD=0` so Journal's sync
engine treats it as new local content.

### Verified behaviour

A live round trip was tested end to end on macOS 26.6.2:

1. `journal-cli write --live` inserted a row with a fresh `Z_PK`, bumped
   `Z_PRIMARYKEY.Z_MAX`, 16-byte UUID `ZID`, RTF body, `ZISUPLOADEDTOCLOUD=0`.
2. Journal.app rendered it natively (title + body, correct date section) and
   the Insights word count updated.
3. Within ~60s the sync engine flipped `ZISUPLOADEDTOCLOUD` to `1` and wrote
   back ~1,950 bytes of `ZRECORDSYSTEMFIELDS` — CloudKit accepted the
   hand-written row.

So Journal's own sync engine adopts rows it did not create, as long as the
Core Data bookkeeping is right.

### Known limits

- **Deleting a synced row is only partly verified.** A `--hard` delete of a
  row with `ZISUPLOADEDTOCLOUD=1` removed it locally and it did not reappear
  after Journal relaunched and resynced. Whether the CloudKit record is
  tombstoned or merely orphaned was not confirmed, and other devices were not
  checked. Prefer deleting through Journal.app for anything already synced.
- No attachment/photo writing. Text and title only.
- `--hard` delete does not clean up orphaned assets.
- GUI automation of Journal.app is unreliable: menu element indexes go stale
  between accessibility calls. Do not script the UI; use the database.

## Tests

```sh
tests/test_write.sh
```

17 assertions against a throwaway copy of the store: insert bookkeeping, RTF
round-trip, soft and hard delete, `PRAGMA integrity_check`, and a check that the
live store row count never moved.

## Schema notes

| Table | Rows (example) | What |
|---|---|---|
| `ZJOURNALENTRYMO` | 101 | entries; `ZTEXT`/`ZTITLE` are RTF blobs |
| `ZJOURNALENTRYASSETMO` | 691 | photos, audio, suggestions |
| `ZJOURNALENTRYASSETFILEATTACHMENTMO` | 484 | files under `Library/Attachments/` |
| `ZJOURNALMO` | 1 | the journal itself |
| `Z_5JOURNALS` | 10 | entry↔journal join (sparse) |
| `Z_PRIMARYKEY` | — | per-entity max PK; must be bumped on insert |

Timestamps are Core Data reference dates: add `978307200` for unix epoch.
