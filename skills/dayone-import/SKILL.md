---
name: dayone-import
description: Move Day One journals into Apple Journal, repair Day One's markdown exports, and correct entry locations from photo EXIF. Use when the user wants to import, migrate, or move entries from Day One into Apple Journal, asks about a Day One export or backup, mentions leaving or replacing Day One, or reports wrong dates, timezones, or locations on Day One or imported entries. macOS only; requires Day One installed and Full Disk Access.
---

# dayone-import

Reads Day One 2's local Core Data store and replays entries into Apple
Journal through `journal-cli`. Also repairs Day One's own markdown export,
which loses information it does not have to.

```sh
S=skills/dayone-import/scripts/dayone-import.py

python3 $S journals                          # what's in Day One
python3 $S plan "Travel Journal"             # what would import, what can't
python3 $S import "Travel Journal" --into "Travel" --target-db "$SANDBOX"
python3 $S import "Travel Journal" --into "Travel" --prune-backups
python3 $S fix-export "Travel Journal" ~/path/to/export --rename --enrich --flag-missing
python3 $S fix-locations "Travel Journal"     # repair locations from photo EXIF
python3 $S fix-text "Travel Journal"          # re-render entries showing raw Markdown
```

Files: `dayone.py` reads the store, `exifgps.py` is a dependency-free JPEG
EXIF reader (GPS + capture time), `photoslib.py` matches photos to the macOS
Photos library for coordinates and Apple's place names.

## Why it reads the SQLite store instead of an export

Day One's markdown export renders **every** timestamp in the exporting
machine's current timezone, not the zone the entry was written in. Entries
written abroad come out hours off, and some land on the wrong calendar day.
The original zone is still in the store (an archived `NSTimeZone` per entry),
so this reads that directly.

The store is unencrypted at
`~/Library/Group Containers/5U8NS4GX82.dayoneapp2/Data/Documents/DayOne.sqlite`.
It is **copied to a temp file before every read**, so Day One can stay open
and is never written to.

## Media is the usual blocker — check `plan` first

Day One keeps media cloud-only until you ask for it: a journal can show every
photo in the app while having almost nothing on disk. `plan` reports this as
*"media not downloaded"*. The fix is **Day One -> Settings -> Sync -> Download
All Media**, wait for it to finish, then re-run.

If you have a markdown export of that journal, pass `--export DIR` and its
`photos/` folder is searched first. Exports often contain bytes the app has
since evicted, so an export plus the store is the strongest combination.

Two kinds of loss are permanent and `plan` names them:
- **"no attachment row"** — the entry text references a moment Day One itself
  no longer has. Nothing can recover these.
- **Audio** — Apple Journal has no write path for audio. Recordings are
  skipped; their transcription usually already appears as the entry text.

## Timezones: pick a clock before importing

Apple Journal has no per-entry timezone column. It stores a bare instant and
renders it in whatever zone the Mac is currently in. So one of two things has
to give, and `--time-mode` chooses which:

- `local` (default) — shift the instant so Journal *displays* the wall clock
  the user actually experienced. A 6am sunrise stays 6am. Trip narratives
  stay on the right day. The stored UTC value is offset, which nothing in
  Journal surfaces.
- `utc` — store the true instant. Correct in the absolute sense, but entries
  written far from home display at the wrong local time and can shift a day.

Default to `local` for travel and photo journals. Only choose `utc` if the
user explicitly wants absolute instants.

## Running an import

Always rehearse first. `journal-cli sandbox --dir DIR` makes a disposable
copy of the real store; `--target-db` points the import at it and no
`--live` or risk acknowledgment is involved.

```sh
DB=$(journal-cli sandbox --dir /tmp/rehearsal)
python3 $S import "Photography" --into "Day One - Photography" \
        --export ~/export/Photography --target-db "$DB"
journal-cli --db "$DB" journals --json      # verify counts, then spot-check
```

Then replay the identical command without `--target-db`.

`--into` is a staging journal on this Mac. Direct Core Data relationships do
not create Journal's per-entry iCloud merge data, so they can look correct on
the Mac while another device places every imported entry in the default
Journal. Audit the staging journal with:

```sh
journal-cli sync-journals --journal "Day One - Photography"
```

Then use the required native finalization workflow:

1. In Journal.app, create a new final journal with a different name, such as
   `Photography`.
2. Open the staging journal, choose **Select Entries**, then **Select All**.
3. Choose **Move / Choose Journals** and select the new final journal.
4. Wait until the staging journal shows 0 entries and iCloud finishes syncing.

The native move creates the merge data that syncs membership to iPhone and
other devices. `sync-journals` is a read-only audit and instruction command.

- **The staging journal must already exist** in Journal.app. Give it a name
  distinct from the final journal, for example `Day One - Photography`.
- **Quit Journal.app** before a live run; `journal-cli` refuses while it runs.
- **Resumable.** Progress is kept in an import ledger keyed by Day One UUID,
  so a re-run skips what already landed and never double-writes. Delete the
  ledger to force a full re-import.

  Nothing can regenerate a ledger, and `fix-text` / `fix-locations` need it
  months later to know which entries are theirs. So the durable copy lives in
  the Plugin Data Worker under `journal-cli/dayone-import/`, with a local
  cache at `~/.local/state/dayone-import/` (override with
  `$DAYONE_IMPORT_STATE`). The cache is authoritative during a run -- writing
  over the network every few entries would stall a large import -- and is
  published when the import finishes. A machine with no local copy pulls it
  back automatically. If the worker is unreachable the import still runs and
  says the local copy is the only one.
- **`--prune-backups`** is close to required for big journals. `journal-cli`
  snapshots the whole store before *every* live write; over a few thousand
  entries that is tens of GB of near-identical copies. This retires them to
  the Trash as it goes, keeping the pre-run snapshot and the newest one.
- Stops after `--max-failures` (default 5) so a systemic problem cannot
  quietly mangle thousands of entries.

## Formatting: Day One writes Markdown, Journal renders rich text

Journal stores entry text as RTF and renders it, but it does not understand
Markdown -- so syntax left in place is shown literally, and an imported
entry reads "###### Reflect on today:" instead of a bold heading. Day One
also escapes punctuation ("1\\." when the author meant a literal "1."),
which surfaces as stray backslashes.

The import passes the original Markdown to `journal-cli --markdown`, which
renders the subset Journal actually supports:

| Markdown | becomes |
|---|---|
| `# ...` through `###### ...` | bold text (Journal has no heading levels) |
| `**bold**`, `*italic*`, `~~struck~~` | bold, italic, strikethrough |
| `- item` / `1. item` | real bulleted and numbered lists |
| `> quote` | an indented paragraph |
| `[text](url)` | `text (url)` |
| `---` rules, ``` fences | removed |
| `\\.` `\\-` escaping | unescaped |

Escaping is why list detection runs *before* unescaping: Day One writes
"1\\. text" precisely when the author did not want a list, so those stay
plain while genuine `1. text` becomes a numbered list.

### Repairing entries imported before this existed

`fix-text` re-renders imported entries from their original Markdown. It
decides what needs work by asking `journal-cli render` what the entry's
source *should* produce and comparing that with what is stored, byte for
byte.

That exactness matters. Sniffing the stored text for leftover syntax cannot
tell a correctly rendered `**literal**` (whose source was escaped) or a
fenced `# comment` from genuinely unrendered markup, so a sniffing check
flags those entries forever and rewrites them on every run.

```sh
python3 $S fix-text "Omar's Journal" --dry-run     # always look first
python3 $S fix-text "Omar's Journal"
```

Safe to re-run: a second pass reports zero entries needing work.

## Fixing wrong locations

Day One stamps an entry with wherever **the app** was when the entry was
written or last edited, not where the photos were taken. Entries written up
later carry the author's home address, and their `timezone` is wrong for the
same reason. `fix-locations` audits imported entries against their photos'
EXIF and rewrites the ones that disagree.

```sh
python3 $S fix-locations "Photography" --export ~/export/Photography --dry-run
python3 $S fix-locations "Photography" --export ~/export/Photography
```

It needs the import state file, so run it **after** `import`. Two rules keep
it from doing harm, both learned the hard way:

- **Anchor on time, not geography.** The entry's location is taken from the
  photo shot closest to the entry's own timestamp, not the geographic centre
  of its photos. An entry covering a flight has frames strung along the
  route; the middle of that line is nowhere meaningful.
- **Corroborate before overriding.** An existing location is only replaced
  when the anchor photo also matches an asset in the Photos library. A camera
  with a stale GPS fix geotags an entire trip from one spot, and those frames
  have no counterpart in Photos — so "EXIF disagrees, but nothing backs it
  up" means leave it alone. Entries that had *no* location just take the EXIF
  coordinates. `--trust-exif` disables this; `--skip ID,ID` vetoes specific
  entries.

Place names come from Photos' reverse-geocode data, which is Apple's own and
matches what Photos shows. Matching is on the photo's **wall clock** against
`ZDATECREATED + ZTIMEZONEOFFSET` plus GPS proximity — never on a timezone
derived from the entry, since that is often the very thing that is wrong.

Report what it left alone as well as what it changed; a skipped entry is a
judgement call the user may want to overrule.

## Repairing a markdown export

`fix-export` rewrites an export in place, matching notes to the store by
their `uuid` frontmatter field. It is **idempotent** — a second run reports
zero changes.

| flag | effect |
|---|---|
| *(default)* | correct `creationDate`/`modifiedDate`, add `timezone:` |
| `--rename` | rename and refile notes whose filename encodes the wrong time |
| `--enrich` | add `place`/`city`/`state`/`country`/`address`/`starred`, and audio transcriptions |
| `--flag-missing` | replace unresolvable image and audio refs with a visible note |
| `--backup DIR` | copy the notes first (default `~/Backups/dayone-export`) |

`--rename` changes file paths, so wiki-links or bookmarks pointing at those
notes will break. Mention that before using it in a live vault. Photos are
never touched — only `.md` files are read or written.

Always `--dry-run` first; it prints every rename it intends to make.

## Sharp edges

- **Confirm the staging journal with the user before a live import.** Entries
  land in the real store and sync, but the staging membership remains Mac-local
  until the user completes the native finalization move. There is no bulk undo
  beyond `journal-cli delete` per entry.
- Photos are copied and resized into Journal's store and then **upload to
  iCloud**. Say roughly how much data that is before starting.
- Day One may be mid-sync; its entry counts can move between runs. Re-run
  `plan` if a count looks off.
- Day One's per-entry `activity`, weather and tags have no home in Apple
  Journal and are dropped. Say so rather than implying
  a lossless move.
- **Do not trust Day One's location or timezone for an entry written after
  the fact.** Both record where the app was, not where the events were. When
  a user says a location looks wrong, reach for `fix-locations` rather than
  assuming the import mishandled it.
- Photo EXIF is not automatically right either. Cameras without a live GPS
  fix reuse a stale position for a whole trip, which is why corroboration
  matters.
