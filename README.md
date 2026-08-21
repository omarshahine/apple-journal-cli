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
journal-cli list                                      # newest first
journal-cli list --limit 20 --full                    # --full prints bodies
journal-cli list --since 2025-01-01 --until 2025-12-31
journal-cli list --include-empty                      # photo-only entries too
journal-cli show 95                                   # one entry + attachments
journal-cli search anguilla --full
journal-cli export --dir ~/journal-export             # one .md per entry
journal-cli export --dir ~/journal-export --format json
journal-cli stats
journal-cli doctor                                    # check access
```

Every read command takes `--json` for scripting. `list` and `search` also take
`--limit N` and `--full`.

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

# photos and video (images are downscaled to Journal's own ~6MP cap; --no-resize to skip)
journal-cli write --live --body "Beach day" --media ~/Pictures/a.heic ~/Movies/b.mov

# a Live Photo is an image + video pair
journal-cli write --live --body "Golden hour" --live-photo IMG_0123.heic IMG_0123.mov

# link media back to the Photos library (writes assetIdentifier via Photos.sqlite lookup)
journal-cli write --live --body "..." --media IMG_0079.JPG --photos-link

# location pin
journal-cli write --live --body "At the office" \
    --lat 47.62055 --lon -122.34930 --place "Space Needle" --city Seattle

# everything at once, backdated and bookmarked
journal-cli write --live --title "Waikiki" --body "..." \
    --media ~/Pictures/surf.heic --lat 21.2793 --lon -157.8294 \
    --place Waikiki --date 2026-08-01 --bookmark

journal-cli write --live --title "Notes" --body-file notes.txt

# edit an existing entry
journal-cli edit 103 --live --body "Rewritten." --title "New title"
journal-cli edit 103 --live --lat 47.62055 --lon -122.34930 --place "Space Needle" --city Seattle
journal-cli edit 103 --live --add-media ~/Pictures/b.heic
journal-cli edit 103 --live --clear-location
journal-cli edit 103 --live --remove-media 700        # asset ids shown by `show 103`
journal-cli edit 103 --live --remove-all-media
journal-cli edit 103 --live --date 2024-03-05 --bookmark   # or --no-bookmark

# target a journal (default: the app's default journal)
journal-cli journals                                  # list journals
journal-cli write --live --journal "Test Journal" --body "..."
journal-cli edit 103 --live --journal "Test Journal"  # move an entry

journal-cli delete 103 --live          # soft delete; the deletion syncs
journal-cli delete 103 --live --hard   # ONLY for never-synced entries (see below)
```

To rehearse anything without risk, work against a throwaway copy:

```sh
DB=$(journal-cli sandbox --dir /tmp/jtest)            # seed from the live store
DB=$(journal-cli sandbox --dir /tmp/jtest --from ~/Backups/journal-cli/<ts>/moments.sqlite)
journal-cli --db "$DB" write --body "no --live needed here"
journal-cli --db "$DB" list --limit 3
```

`--db` (or `$JOURNAL_DB`) points any command at another store. Anything that is
not the real Journal store skips the `--live` guard, and attachments are read
and written beside that database rather than in your real `Attachments/`.

### How writes are constructed

| Field | Storage |
|---|---|
| body / title | RTF blob in `ZTEXT` / `ZTITLE` via `textutil` |
| date | `ZENTRYDATE` + `ZMOMENTDATEFORSORTING`, Core Data epoch |
| bookmark | `ZFLAGGED` (verified: Journal shows the Bookmarked badge) |
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

Text, photo and location writes have all been confirmed end to end on
macOS 26.6.2 against a real library:

1. `journal-cli write --live --media pic.jpg --lat .. --lon .. --place ..`
   inserted an entry, a `photo` asset, a `multiPinMap` asset and a file
   attachment, and copied the image into `Attachments/`.
2. Journal.app rendered the entry natively — photo displayed full width, a
   location chip reading "Space Needle · Seattle", title and body intact.
3. The sidebar **Places** counter incremented (481 -> 483), so Journal ingested
   the pin into its own location index rather than merely displaying it.
4. Within ~60s every row synced: entry, both assets and the file attachment all
   flipped `ZISUPLOADEDTOCLOUD` to `1` and received ~1,900-1,970 bytes of
   `ZRECORDSYSTEMFIELDS`. CloudKit accepted the image upload too.
5. `edit` was confirmed the same way: an entry created without a location had
   its body rewritten and a pin added, and Journal showed both the new text and
   a "Space Needle - Seattle" chip. The edit re-synced to CloudKit.
6. A `--hard` delete removed the entry, its assets and the attachment
   directory. It did not return across a Journal relaunch and resync.

So Journal's sync engine fully adopts rows and files it did not create,
provided the Core Data bookkeeping is right.

### Not supported

Journal stores twelve asset types. This tool writes three:

| Asset type | Count in a real library | Support |
|---|---|---|
| `photo` | 267 | read + write |
| `streakEvent` | 208 | read metadata only |
| `livePhoto` | 89 | read + write |
| `multiPinMap` (location) | 85 | read + write |
| `video` | 31 | read + write |
| `stateOfMind` | 6 | read metadata only |
| `workoutRoute` | 3 | read metadata only |
| `workoutIcon` | 3 | read metadata only |
| `motionActivity` | 1 | read metadata only |
| `link` | 1 | read metadata only |
| `genericMap` | 1 | read only |
| `drawing` | 1 | read metadata only |

"read metadata only" means `show`/`export` report the asset's type and any
attached files, but do not decode its type-specific payload and cannot create one.

Beyond assets:

- **Text edits are blocked on CRDT entries by default.** Journal keeps a second
  copy of the entry text in a `ZMERGEABLEATTRIBUTES` CRDT blob (magic `crdt`, a
  protobuf) for merge-safe multi-device editing. Roughly half a real library has
  one. `edit` refuses to rewrite `ZTEXT` on those entries unless you pass
  `--force`, since the CRDT copy may win on sync. Location, media, date and
  bookmark edits are unaffected — none of them live in the CRDT.
- **Written entries have no CRDT.** They carry `ZTEXT` only. Journal renders and
  syncs them fine and does not backfill one, but concurrent edits on two devices
  may not merge the way a natively-created entry would.
- **No Recently Deleted restore/empty.** `delete` without `--hard` moves an
  entry there (and the deletion syncs); there is no restore command yet.
- **No audio.** Journal can record audio entries; this cannot.
- **No reflection prompts.** `ZPROMPT` / `ZREFLECTIONPROMPT` are read-only
  curiosities here.
- **Search is a client-side substring match** over title and body. It is not
  Journal's own index, does not rank, and does not search asset metadata.

### Known limits on what is supported

- Images are downscaled to Journal's own ~6MP `_resized` cap (long edge 2830)
  unless `--no-resize` is passed; Live Photo pairs are stored untouched, as
  Journal does.
- `--photos-link` resolves `assetIdentifier` by original filename (and size,
  when the name is ambiguous) against `Photos.sqlite`, or from the UUID when
  the file comes straight out of a `.photoslibrary`. Files Photos does not
  know about are attached unlinked, with a warning.
- **Hard-deleting a synced entry resurrects it.** Confirmed empirically: four
  hard-deleted synced entries came back hours later with new Z_PKs — a local
  row delete does not tombstone the CloudKit record, and sync re-creates the
  entry. `delete --hard` therefore refuses synced entries unless `--force` is
  passed. The safe paths are a soft delete (the CLI marks the flagged row
  unsynced, Journal's engine uploads the deletion, and the entry lands in
  Recently Deleted everywhere) or deleting in Journal.app.
- Live writes need Full Disk Access, which macOS can revoke mid-session; see
  Troubleshooting.

## Tests

```sh
tests/test_write.sh                                   # seeds from the live store
JOURNAL_SEED=~/Backups/journal-cli/<ts>/moments.sqlite tests/test_write.sh
```

93 assertions against a throwaway copy: argument guards, insert bookkeeping,
RTF round-trip, location metadata and coordinates, photo/video asset rows,
attachment file layout on disk, asset ordering, Markdown export of media and
locations, every `edit` operation (including media removal) and its CRDT guard, image
resizing, Live Photo pairing, Photos-library linkage, journal targeting and
the journals listing, the synced hard-delete guard, soft and hard delete, `PRAGMA integrity_check`, and a check that the
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
