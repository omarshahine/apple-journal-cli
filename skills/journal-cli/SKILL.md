---
name: journal-cli
description: Read and write Apple Journal entries from the terminal via the journal-cli binary. Use when the user asks to read, search, export, summarize, create, edit, or delete Apple Journal entries, mentions "my journal", journaling, Journal.app, or wants journal content piped into other workflows. macOS only; requires Full Disk Access.
---

# journal-cli

`journal-cli` reads and writes Apple Journal.app entries directly from its
data store. All read commands take `--json`. Exit code 0 = success, 1 = error
or refusal, with the reason on stderr prefixed `journal-cli:`.

Run `journal-cli --help` for the full surface, `journal-cli doctor` to check
access (exit 1 means Full Disk Access is missing — tell the user to grant it
to the terminal and relaunch).

## Reading (always safe)

Reads copy the store to a temp snapshot first — safe while Journal.app is
open, no locks, no mutation.

```sh
journal-cli list --limit 20 --json          # newest first
journal-cli list --since 2025-01-01 --until 2025-12-31 --json
journal-cli show <id> --json                # full entry + assets + file paths
journal-cli search "query" --json           # substring over title+body
journal-cli export --dir DIR [--format json]
journal-cli stats                           # counts, words, year histogram
journal-cli journals --json                 # journals with entry counts
journal-cli deleted --json                  # Recently Deleted
```

`show --json` asset objects carry `type` (photo, video, livePhoto,
multiPinMap, link, audio, drawing, …), `files[].path` (absolute, on disk),
plus per-type extras: `places[]` with lat/lon/name for locations, `url` and
`link_title` for links, `duration` and `transcript` for audio,
`drawing_text` for drawings.

## Writing (guarded)

Live writes need `--live`, refuse while Journal.app is running (quit it
first: `osascript -e 'tell application "Journal" to quit'`), and auto-backup
to `~/Backups/journal-cli/` before touching anything.

```sh
journal-cli write --live --title T --body B [--date YYYY-MM-DD] [--bookmark]
journal-cli write --live --media a.heic b.mov          # photos auto-resize
journal-cli write --live --live-photo IMG.heic IMG.mov # image+video pair
journal-cli write --live --lat N --lon N --place P --city C
journal-cli write --live --link URL --link-title T
journal-cli write --live --journal "Name" ...          # non-default journal
journal-cli edit <id> --live [same flags; --add-media/--add-link/--remove-media ID/--clear-location/--journal N]
journal-cli delete <id> --live                         # soft; syncs properly
journal-cli restore <id> --live
```

The entry id is printed as `Created entry <id> ...` — parse it with
`grep -oE 'entry [0-9]+'`.

## Rehearse before touching the real store

```sh
DB=$(journal-cli sandbox --dir /tmp/rehearsal)   # disposable copy
journal-cli --db "$DB" write --body "test"       # no --live needed
journal-cli --db "$DB" list --limit 3 --json
```

`--db` (or `$JOURNAL_DB`) points any command at another store. Prefer this
for anything experimental; replay with `--live` once it looks right.

## Sharp edges — do not work around these

- **First live write requires a risk acknowledgment.** If the CLI refuses with
  the risk warning, show the warning to the user and ask them to confirm
  (and to back up via Journal -> Settings -> Export Journal Entries first);
  only pass `--accept-risk` after they explicitly agree. Never pass it
  preemptively.
- **Prefer `--dry-run` first** for any write you compose: it validates inputs
  and prints the plan without touching the store.

- **Never bypass a refusal by adding `--force` on your own.** Two guards
  exist for data-safety reasons and overriding them needs the user's explicit
  ok:
  - `edit --body/--title` on app-authored entries (they carry a CRDT copy of
    the text; a forced RTF edit can be reverted or duplicated by sync).
  - `delete --hard` on synced entries (the CloudKit record is not tombstoned
    and the entry resurrects on the next sync).
- Soft delete (`delete` without `--hard`) is the correct deletion for synced
  entries — it propagates.
- If the user has a designated test journal, write there
  (`--journal "<name>"`); check `journal-cli journals --json` first.
- Dates print in the machine's local timezone; a stale or invalid `TZ` env
  var in your shell will skew displayed times, not stored ones.
