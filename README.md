# apple-journal-cli

**Read and write Apple Journal entries from the terminal.** Text, photos,
videos, Live Photos, web links, location pins, bookmarks, multiple journals —
plus search, Markdown/JSON export, and audio transcripts. Native Swift, zero
dependencies, macOS 14+.

Apple Journal has no public API, no AppleScript dictionary, and no export
format worth scripting against. journal-cli talks directly to the app's own
data store, safely: reads never touch the live database, writes are guarded,
backed up, and verified against Journal's sync engine.

```
$ journal-cli list --limit 3
   117  2026-08-21 00:43:01  Test new features
   116  2026-08-21 00:32:11  link test
   115  2026-08-20 22:16:40  test journal routing

$ journal-cli show 117
audio (asset 705)  2.2s  "This is a test of an audio recording."
location  15835 NE 36th St, Redmond  (47.641544, -122.129299)
```

## Install

```sh
brew install omarshahine/tap/journal-cli
# or
npm install -g apple-journal-cli
# or from source
git clone https://github.com/omarshahine/apple-journal-cli && cd apple-journal-cli/swift
swift build -c release && cp .build/release/journal-cli /usr/local/bin/
```

Grant **Full Disk Access** to your terminal (System Settings → Privacy &
Security), then:

```sh
journal-cli doctor
```

## Reading

Reads run against a temp snapshot of the store, so they are safe while
Journal.app is open and never lock the live database.

```sh
journal-cli list --limit 20 --full            # --full prints bodies
journal-cli list --since 2025-01-01 --until 2025-12-31
journal-cli show 95                           # entry + assets + attachment paths
journal-cli search anguilla
journal-cli export --dir ~/journal-export     # one .md per entry, YAML frontmatter
journal-cli export --dir ~/export --format json
journal-cli stats                             # counts, words, by-year histogram
journal-cli journals                          # list journals
journal-cli deleted                           # list Recently Deleted
```

`show` decodes everything Journal stores: entry text, titles, bookmark state,
photo/video attachment paths, location pins with place names, web links with
titles, **audio transcripts** (word-level, joined), and handwriting-recognition
text from drawings.

## Writing

Writes against the real store require `--live`, refuse to run while
Journal.app is open, and take a timestamped backup to `~/Backups/journal-cli/`
first. New entries sync to iCloud like native ones — verified end to end,
including CloudKit accepting attached files.

```sh
# text, dated, bookmarked
journal-cli write --live --title "Monday" --body "Long run, then coffee." \
    --date 2026-08-01 --bookmark

# photos and video (images auto-downscale to Journal's own ~6MP cap)
journal-cli write --live --body "Beach day" --media a.heic b.mov

# a Live Photo is an image + video pair
journal-cli write --live --body "Golden hour" --live-photo IMG_0123.heic IMG_0123.mov

# location pin
journal-cli write --live --body "At the office" \
    --lat 47.62055 --lon -122.34930 --place "Space Needle" --city Seattle

# web link (renders as a rich link card)
journal-cli write --live --body "Read this" --link https://example.com --link-title "A Post"

# target a journal; link photos back to the Photos library
journal-cli write --live --journal "Travel" --body "..." --media IMG_0079.JPG --photos-link
```

### Editing

```sh
journal-cli edit 103 --live --body "Rewritten." --title "New title"
journal-cli edit 103 --live --lat 47.6 --lon -122.3 --place Home   # set/replace pin
journal-cli edit 103 --live --add-media c.heic --add-link https://example.org
journal-cli edit 103 --live --remove-media 700                     # ids shown by `show`
journal-cli edit 103 --live --clear-location --no-bookmark
journal-cli edit 103 --live --journal "Travel"                     # move journals
```

### Deleting

```sh
journal-cli delete 103 --live          # soft delete -> Recently Deleted; syncs
journal-cli restore 103 --live         # bring it back; syncs
journal-cli empty --live               # purge never-synced deleted entries
journal-cli delete 103 --live --hard   # full row+file removal (guarded, see below)
```

## Agent-friendly by design

journal-cli is built to be driven by AI agents and scripts as much as by
humans:

- **`--json` on every read command** — stable keys, machine-parseable, no
  ANSI. `list`, `show`, `search`, `journals`, `deleted` all speak JSON.
- **Meaningful exit codes** — `0` success, `1` refusal or error, with a
  one-line reason on stderr prefixed `journal-cli:`.
- **`--help` / `doctor`** — full usage from the binary itself;
  `doctor` reports access state and entry count, exit 1 when setup is needed.
- **Guardrails an agent cannot stumble past** — destructive or risky paths
  (`--live`, `--force`, `--hard`) must be opted into explicitly, and every
  live write auto-backs-up first.
- **Sandboxing as a first-class command** — `sandbox --dir D [--from BACKUP]`
  hands back a disposable copy of the store; every other command accepts
  `--db` (or `$JOURNAL_DB`) to target it. Agents can rehearse a write with
  zero risk, then replay it `--live`.
- **A skill ships in-repo** — `skills/journal-cli/SKILL.md` teaches
  Claude-style agents the command surface, the safety model, and the sharp
  edges.

## Safety model

| Layer | Behavior |
|---|---|
| Reads | temp snapshot of `db`+`-wal`+`-shm`; live store never opened for read |
| `--live` gate | writes to the real store refuse to run without it |
| App check | writes refuse to run while Journal.app is open |
| Auto-backup | every live write snapshots the store to `~/Backups/journal-cli/` first |
| Synced hard-deletes | refused without `--force`: a local row delete does not tombstone the CloudKit record, and the entry **resurrects on the next sync** (observed). Soft delete syncs properly. |
| CRDT text guard | text edits on app-authored entries are refused without `--force` (see below) |
| Sandbox | `sandbox` + `--db` target a throwaway copy; the `--live` gate does not apply there |

## Verified behavior

Every write path has been verified against a real library on macOS 26:
Journal.app renders CLI-written text, photos, Live Photos (labeled as such),
link cards, and location pins (which also feed its Places index); the sync
engine uploads them all to CloudKit — including the attachment files — and a
delete/restore round trip propagates. The read pipeline has been swept over an
entire real store: every entry row and all ~700 asset metadata blobs parse.

The test suite (`tests/test_write.sh`, 110 assertions) runs the whole command
surface against a disposable copy of a store — argument guards, insert
bookkeeping, RTF round-trips, location metadata, media file layout, Live Photo
pairing, Photos linkage, journal targeting, link assets, the delete/restore
lifecycle, and `PRAGMA integrity_check`. Point `JOURNAL_SEED` at a backup to
run it without Full Disk Access. `JOURNAL_CLI` selects the binary under test;
the Python reference implementation in `reference/` passes the identical
suite.

## How it works

Journal's store is a Core Data SQLite database:

```
~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite
```

"moments" is Journal's internal codename, which is why searching for "journal"
never finds it. Entry text is plain RTF in `ZJOURNALENTRYMO.ZTEXT` — not
encrypted. (The encrypted CloudKit records under the app container are only
the sync cache.)

| Data | Storage |
|---|---|
| entries | `ZJOURNALENTRYMO`; text/title as RTF blobs; Core Data epoch timestamps |
| assets | `ZJOURNALENTRYASSETMO` — 12 types (photo, video, livePhoto, multiPinMap, link, audio, drawing, stateOfMind, streakEvent, workoutRoute/Icon, motionActivity) |
| files | `ZJOURNALENTRYASSETFILEATTACHMENTMO` → `Attachments/<entryUUID>/<assetUUID>/…` |
| asset metadata | one version byte `0x01` + JSON; `0x02` + UUID = Core Data external storage in `.moments_SUPPORT/_EXTERNAL_DATA/` |
| links | base64 `NSKeyedArchiver`-archived `LPLinkMetadata` inside the asset metadata |
| audio | asset metadata carries duration, waveform, and a word-level transcript |
| journals | `ZJOURNALMO` (names live in each journal's CRDT blob) + `Z_5JOURNALS` join |
| new-row bookkeeping | fresh `Z_PK`, bumped `Z_PRIMARYKEY.Z_MAX`, 16-byte UUID `ZID`, `ZISUPLOADEDTOCLOUD=0` — Journal's sync engine adopts the row and uploads it |

### The CRDT limitation

A CRDT (Conflict-free Replicated Data Type) is a data structure built so that
several devices can edit the same content offline and still merge to an
identical result, with no server picking winners. Instead of storing "the
string", a text CRDT stores every character with an identity and causal
history, so two devices replaying each other's operations always converge.

Journal keeps such a CRDT in `ZMERGEABLEATTRIBUTES` (magic `crdt`, a protobuf)
— a second, richer copy of the entry text alongside the RTF, present on every
entry whose text was typed in the app. Consequences:

- **`edit` refuses to rewrite text on CRDT-bearing entries** unless `--force`
  is passed: rewriting only the RTF leaves the CRDT holding the old text with
  authoritative history, and sync can revert or duplicate the edit. Location,
  media, links, date, bookmark and journal moves are safe on any entry — none
  of that state lives in the CRDT (verified across a real library).
- **CLI-written entries have no CRDT.** Journal renders and syncs them fine,
  but a simultaneous edit on two devices may not merge like an app-authored
  entry would.
- **Authoring the CRDT is out of scope** — fabricating causal history in a
  reverse-engineered protobuf risks corrupting merge for that entry.

### Not supported

- Creating system-generated assets: streaks, state of mind, workout data,
  motion activity, drawings. Their metadata all decodes on read.
- Writing audio entries (transcripts and duration are read).
- Rendering `PKDrawing` stroke data.
- Whether a purged CloudKit record is tombstoned on *other* devices has not
  been verified from this machine.

## Development

```sh
cd swift && swift build            # debug build
tests/test_write.sh                # full suite against a store copy
```

The `reference/` directory holds the original Python implementation — same
command surface, same test suite, useful for spelunking since it needs no
build step.
