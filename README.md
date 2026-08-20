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
# text
journal-cli write --live --title "Monday" --body "Long run, then coffee."
cat notes.md | journal-cli write --live --title "Notes"

# photos and video
journal-cli write --live --body "Beach day" --media ~/Pictures/a.heic ~/Movies/b.mov

# location pin
journal-cli write --live --body "At the office" \
    --lat 47.62055 --lon -122.34930 --place "Space Needle" --city Seattle

# everything at once, backdated and bookmarked
journal-cli write --live --title "Waikiki" --body "..." \
    --media ~/Pictures/surf.heic --lat 21.2793 --lon -157.8294 \
    --place Waikiki --date 2026-08-01 --bookmark

journal-cli delete 103 --live          # soft delete (Recently Deleted)
journal-cli delete 103 --live --hard   # remove row, assets, and files
```

### How writes are constructed

| Field | Storage |
|---|---|
| body / title | RTF blob in `ZTEXT` / `ZTITLE` via `textutil` |
| date | `ZENTRYDATE` + `ZMOMENTDATEFORSORTING`, Core Data epoch |
| bookmark | `ZFLAGGED` |
| photo / video | `ZJOURNALENTRYASSETMO` type `photo`/`video`, source `imagePicker`, plus a `ZJOURNALENTRYASSETFILEATTACHMENTMO` row |
| location | `ZJOURNALENTRYASSETMO` type `multiPinMap`, source `locationPicker`, `ZISSLIM=1` |
| asset order | `ZASSETORDERING`, plain JSON `[assetUUID, index, ...]` |

Asset metadata (`ZASSETMETADATA`) is **one version byte `0x01` followed by JSON**.
For a location that is `{"revision":2,"visitsData":[{latitude, longitude,
placeName, city, visitStartTime, ...}]}`. For a photo it carries `latitude`,
`longitude`, `placeName`, crop rects and `date`.

Media files are copied to:

```
Attachments/<entry-UUID>/<asset-UUID>/<random-UUID>_resized.<ext>
```

with `fileAttachment.ZPARENTID = asset.ZID` and `asset.ZPARENTID = entry.ZID`.

New rows get `ZISUPLOADEDTOCLOUD=0` so Journal's sync engine treats them as new
local content.

### Verified behaviour

A live round trip was tested end to end on macOS 26.6.2 (text entry):

1. `journal-cli write --live` inserted the row.
2. Journal.app rendered it natively, and the Insights word count updated.
3. Within ~60s the sync engine flipped `ZISUPLOADEDTOCLOUD` to `1` and wrote
   back ~1,950 bytes of `ZRECORDSYSTEMFIELDS` — CloudKit accepted it.
4. A `--hard` delete removed it, and it did not return across a Journal
   relaunch and resync.

So Journal's sync engine adopts rows it did not create, provided the Core Data
bookkeeping is right.

### Known limits

- **Media and location writes are schema-verified, not app-verified.** The 45
  tests confirm the rows, blobs, file layout and round-trip reads match what
  Journal itself produces, but I have not yet seen Journal.app render a
  hand-written photo or map pin. Only the text path has been confirmed in the
  app and in CloudKit. Treat media/location writes as experimental.
- Photos are copied as-is. Journal's own `_resized` files are downscaled
  derivatives; no resizing is performed here.
- No Photos-library linkage. Real photo assets carry an `assetIdentifier`
  pointing into the Photos database; written ones do not.
- Deleting a synced row is only partly verified — the CloudKit record may be
  orphaned rather than tombstoned. Prefer deleting through Journal.app.
- Live writes need Full Disk Access, which macOS can revoke; see below.

## Tests

```sh
tests/test_write.sh                                   # seeds from the live store
JOURNAL_SEED=~/Backups/journal-cli/<ts>/moments.sqlite tests/test_write.sh
```

45 assertions against a throwaway copy: argument guards, insert bookkeeping,
RTF round-trip, location metadata and coordinates, photo/video asset rows,
attachment file layout on disk, asset ordering, Markdown export of media and
locations, soft and hard delete, `PRAGMA integrity_check`, and a check that the
source store never moved.

`JOURNAL_SEED` runs the whole suite off a backup, so tests need no Full Disk
Access and never touch the real store.

## Troubleshooting

**`PERMISSION DENIED` on the store.** The group container is TCC-protected.
Grant Full Disk Access to your terminal and relaunch it. Note that the grant can
disappear mid-session; `journal-cli doctor` tells you the current state. Copies
of the store made while access was granted keep working, so a backup is a usable
fallback for reads and tests.

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
