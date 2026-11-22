# Changelog

## 1.5.2

### Fixed

- **Markdown export** percent-encodes `%`, `#` and `?` in attachment paths, so
  a renderer can't read them as URL syntax. Web links keep their own query,
  fragment and escapes.
- **dayone-import** reads EXIF only from the photo's EXIF segment, not past
  its declared end.

## 1.5.1

### Fixed

- **Markdown export** escapes `&` in attachment links and labels, so a path
  containing `&copy;` can't render as ©, and percent-encodes line breaks.
- **dayone-import** accepts a GPS direction only as the EXIF letter-plus-NUL,
  within the data the photo actually has.

## 1.5.0

### Fixed: third review pass

([#30](https://github.com/omarshahine/apple-journal-cli/pull/30),
[#31](https://github.com/omarshahine/apple-journal-cli/pull/31))

- **Markdown rendering:** nested bold (`**a __b__ c**`) stays bold, and text
  using private-use characters is no longer at risk of corruption.
- **dayone-import:** malformed photo GPS no longer produces made-up
  coordinates, location matching works across the 180° meridian, and entries
  recorded in a fixed-offset zone (such as `GMT+0100`) keep it instead of being
  read as UTC. Ledgers written with the old UTC reading still verify.

- **`edit --dry-run` checks what the real edit checks:** the date, the
  Journal-merge text and journal guards, journal names, and the assets named in
  `--remove-media`. It used to report success for edits the real command
  refuses. A non-numeric `--remove-media` id is now an error instead of being
  dropped while the rest of the edit applied.
- **Backups are owner-only** (folder 0700, store 0600), a failed backup leaves
  no partial folder, and the write lock is taken before the backup, so no
  other write can land between a recovery point and the write it protects.
- **A refused read no longer leaves a copy of the journal in the temp folder.**
- **Markdown export** keeps the readable content of link, voice-memo and
  drawing assets, and writes attachment links that survive spaces and
  parentheses in the path.
- **`--db` between a list option and an argument** no longer merges them
  (`edit --remove-media 5 --db X 42`).
- Python reference: `--photos-link` sees Photos records still in its WAL, and
  an entry dated exactly at the Core Data epoch shows its date.
- Docs: the README's reading examples no longer include writes, the
  development recipe runs from the right folder, and the skill lists `edit`'s
  real flags (it cannot attach a Live Photo).

## 1.4.9

### Fixed: dayone-import attachment references

([#29](https://github.com/omarshahine/apple-journal-cli/pull/29)) Every Day One
attachment reference taken out of an entry's text is now reported: a
`pdfAttachment` or unrecognized reference used to vanish without reaching the
missing-media list. `fix-export --flag-missing` flags such references too, and
no longer crashes on one that has no attachment id.

## 1.4.8

### Fixed: second review pass, dayone-import

([#28](https://github.com/omarshahine/apple-journal-cli/pull/28))

- **External image syntax is kept.** Only real Day One attachment references
  (`dayone-moment:` links) are stripped; other `![...](...)` images, ones
  inside fenced code, and escaped ones stay in the text.
- **One time zone must explain a whole legacy ledger.** Each mapping used to
  be accepted under any of several tied zones; now a single (mode, zone) has
  to fit them all, or the ledger is refused.
- **Only the entry's own UUID marks an untitled entry.** Any other 32-hex
  first line is a real title.
- **Fenced code survives preprocessing:** a body that opens with a fence keeps
  it, and its blank lines stay. `fix-text` clears a fence an older version
  promoted to the title.
- **Remote ledger copies are keyed by import**, not by local filename, so two
  imports' `--state` files never overwrite each other's published copy.

### Fixed: second review pass, CLI

([#27](https://github.com/omarshahine/apple-journal-cli/pull/27))

- **A hard link to the real store is the real store.** The live-store check
  compared paths, so `--db` pointed at a hard link skipped `--live`, the risk
  acknowledgment, the Journal.app check and the backup. Both implementations
  now compare file identity.
- **Fenced code keeps its blank lines** and whitespace-only lines in
  `--markdown` rendering; only prose blank lines are collapsed.
- **Animated GIFs are stored unchanged.** Resizing an oversized one kept only
  its first frame.
- **Text with an embedded NUL character** is bound and read by byte length
  instead of being cut off at the NUL.

## 1.4.7

### Fixed: dayone-import legacy ledger identity

([#26](https://github.com/omarshahine/apple-journal-cli/pull/26)) A pre-1.4.4
ledger is now verified by each entry's exact instant under the time zone the
old import ran in, inferred from the ledger itself (daylight saving and later
zone changes included), and every mapping must fit that one zone. Edits made
in Journal since the import no longer block a genuine ledger, which the 1.4.6
content check did. Id-less marks are located by instant, with the words
breaking ties.

## 1.4.6

### Fixed: dayone-import legacy ledgers check content too

([#25](https://github.com/omarshahine/apple-journal-cli/pull/25)) Verifying a
pre-1.4.4 ledger now also requires each recorded entry's title and body to
match the destination entry, raw Markdown or rendered, so an unrelated entry
at a nearby time is never adopted. Old marks without an entry id are looked
up the same way: confirmed ones get their id, the rest are imported instead of
silently skipped.

## 1.4.5

### Fixed: dayone-import skill

([#24](https://github.com/omarshahine/apple-journal-cli/pull/24))

- **A longer fence keeps a shorter one as content.** A four-backtick block
  holding a three-backtick line and `---` used to flatten to nothing, and an
  untitled entry with that body was skipped as empty.
- **Ledgers from before 1.4.4 are checked before use.** Back then a rehearsal
  shared the live ledger's filename. An untagged ledger is now verified against
  the destination (every recorded entry at the instant it was written,
  tolerant of a time-zone change since). A mismatch, or a ledger with no entry
  ids at all, stops the command instead of skipping entries or repairing the
  wrong ones. Ledgers also record their Day One store and refuse another.

## 1.4.4

### Fixed: dayone-import skill

([#23](https://github.com/omarshahine/apple-journal-cli/pull/23))

- **An interrupted import no longer replays its writes.** Each write is marked
  pending before it runs and recorded as done the moment it succeeds. A resumed
  run checks a leftover pending write against the destination by instant
  (time-zone independent), rendered content, and a floor id taken at the start
  of the run, so it never claims an unrelated entry. A nonzero exit after a
  commit is checked the same way, so it isn't written twice.
- **Rehearsal and live imports keep separate ledgers.** A ledger records its
  journal and destination and refuses a mismatch, a sandbox picked with
  `$JOURNAL_DB` counts as a sandbox, and a relative `--state` path works.
- **Consistent, cleaned-up snapshots.** The Day One and Photos stores are copied
  with SQLite's online backup API, and every snapshot is removed when its
  connection closes.
- **Malformed EXIF** in one photo no longer stops a location audit or repair.
- **Text:** fenced content survives flattening, only a real Markdown heading
  marker is stripped from a title, and unreferenced attachments are classified
  like referenced ones.
- The skill now has a unittest suite in CI.

### Fixed: reads, export and Markdown

From the same full Clawpatch review. Swift and the Python reference both,
where both have the code, with regression tests.

- **Failed reads are errors.** A SQLite query that failed part way (busy,
  I/O error, corruption) used to return whatever rows it had, so `list` or
  `export` could look complete when they were not. Now it exits 1. In the
  Python reference, a failed `textutil` RTF conversion is an error instead of
  an entry silently dropped from the output.
- **Export keeps attachment-only entries** (a photo, a map, no words) in both
  Markdown and JSON, and fails with the path when it cannot create the folder or
  write a file, instead of reporting "Wrote N entries".
- **Location names are YAML-escaped** in Markdown export front matter, as
  titles already were. A quote or backslash in a place name broke the YAML.
- **Dates ignore the user's calendar.** Under a Buddhist or Japanese calendar,
  `2026-01-05` came out as `2569-01-05`, and `--date` parsed the same way.
  Fixed formats now use the Gregorian calendar and `en_US_POSIX`, still in the
  local time zone.
- **`--` ends the options**, so `journal-cli search -- --db` searches for the
  text "--db".
- **`--photos-link` checks the size** of a single filename match too, so a
  different photo that happens to share a name like `IMG_0001.JPG` is no longer
  linked.
- **Markdown:** a link destination keeps its `*` and `_`
  (`[x](https://e.com/*a*)` no longer italicizes part of the URL), and a line
  like ```` ```literal ```` inside a fenced block stays content. Only a bare
  fence at least as long as the opening one closes the block.
- **Tests:** the edit sync check now starts from a synced entry, and the CRDT
  guard tests, which ran zero assertions against the synthetic fixture, build
  their own app-authored entry and fail if they can't.

## 1.4.3

### Fixed: data safety for live writes and reads

Found by a full Clawpatch review of the CLI. Every fix lands in both the
Swift build and the Python reference, with regression tests.

- **An unreadable `--body-file` no longer erases an entry's text.** A missing
  file, a permission error or invalid UTF-8 used to become an empty body, and
  `edit` took that as "clear the text". Now it is an error and nothing is
  written. An empty file still clears the text on purpose. The same goes for
  non-UTF-8 stdin.
- **Backups fail closed.** If the backup folder can't be created or the copy
  fails, the write is refused. Each write gets its own folder, so two writes
  in the same second no longer share (and lose) a recovery point.
- **Removed media is recoverable.** `edit --remove-media`, `delete --hard` and
  `empty` used to delete attachment files outright, so the automatic backup
  could not bring them back. They now move into that write's backup under
  `Attachments/`, after the database commit.
- **Failed writes don't strand or lose files.** File removals wait for the
  commit, so an edit that fails part way (say, an unknown journal) no longer
  deletes media whose rows roll back. A failed attachment copy (full disk, an
  unwritable folder) refuses the write instead of committing rows that point at
  missing files, and any attachment folders the write created are removed.
- **Snapshots and backups are consistent.** Reads, backups and `sandbox` used
  to copy `moments.sqlite`, `-wal` and `-shm` one after another, which could mix
  generations if Journal checkpointed in between. They now use SQLite's online
  backup API, which copies inside one read transaction.

## 1.4.2

### Added: `--version`

`journal-cli --version` prints `journal-cli <version>` and exits 0, in both the
Swift build and the Python reference. The test suite fails if either drifts
from `npm/package.json`, and the release workflow refuses a tag that does not
match `Version.swift`.

## 1.4.1

### Fixed: `--db` no longer steals another option's value

The global `--db` pass searched every argument for the literal `--db`, so a
body, title or query that was exactly `--db` became a database selector and
the next argument vanished as its path. `render --body '--db' --plain` read
`--plain` as the store and then failed with "--body needs a value". `--db` is
now recognized only where an option can start; it still works before or after
the command.

### Fixed: release pipeline hardening

- The Homebrew step only hashes a source archive that actually downloaded. A
  run whose five download attempts all failed could hash a partial file and
  commit a bad checksum to the tap; it now fails before touching the formula.
- Two tags released close together used to race on the tap push, and the
  loser stopped before npm. A rejected tap push now re-fetches the tap,
  re-applies the update and retries, and the step never moves the formula to
  an older version.
- Re-running a release whose npm publish already succeeded now skips npm
  instead of failing on the immutable version. Registry errors other than a
  404 fail the step rather than being read as "not published".

## 1.4.0

### Added — an entry can belong to more than one journal

Journal's membership table is many-to-many, and the app lists an entry under
every journal it belongs to. The CLI can now express that
([#11](https://github.com/omarshahine/apple-journal-cli/pull/11), thanks
[@rodchristiansen](https://github.com/rodchristiansen)):

- `write` accepts repeated `--journal` (and `--add-journal`).
- `edit --add-journal NAME` adds a membership and leaves the others alone;
  `edit --remove-journal NAME` drops one. Both repeat.
- `edit --journal` still *moves* the entry, replacing every membership;
  repeat it to land in several. Mixing it with `--add-journal` or
  `--remove-journal` is refused rather than guessed at.
- `edit --add-journal` to the default journal is refused: the default holds
  every entry that is in no other journal, so there is no membership to add.
  (`write` naming the default journal just creates the entry there.)

The journal flags take one name each. `edit --journal Travel 42` reads `42` as
the entry id, not as a second journal.

### Fixed — short journal names

Journal names are now read from the length prefixes of the journal's CRDT blob
instead of a scan for printable runs
([#8](https://github.com/omarshahine/apple-journal-cli/pull/8), thanks
[@adeolonoh](https://github.com/adeolonoh)). A name shorter than three
characters, such as "TV", used to come back as whatever replica-id bytes sat
next to it (and changed between runs), so `--journal TV` could not address it.
Non-ASCII names, which the Swift scan dropped, now decode too.

### Fixed — Python reference dates off by the UTC offset

`reference/journal-cli.py` now stores entry dates as the true instant, as the
Swift build does; it had shifted every date it wrote by the local UTC offset
([#12](https://github.com/omarshahine/apple-journal-cli/pull/12)). CI now runs
both implementations under UTC and America/Los_Angeles, so a timezone bug can
no longer hide behind UTC runners. The shipped binary was not affected.

## 1.3.0

### Fixed — `--location-presentation off` was erasing locations

**If you used `--location-presentation off` on 1.2.0, run
`journal-cli repair-locations --live`.** Your coordinates are not lost.

1.2.0 wrote `off` as `ZISHIDDEN=1` on the map asset. Apple Journal does not
model the map card that way: it reads such an asset as absent entirely, so the
entry ends up with **no map card *and* no Places entry** — the location is
effectively gone from the app.

Journal keeps a map's Off state only in the entry's own CRDT, whose key table
reads `title`, `gridAssetIDs`, `slimAssetID`, `hiddenAssetIDs`,
`assetPlacement`. An Off map is listed under `hiddenAssetIDs` there and its
asset row stays byte-identical to a large one (`ZISSLIM=0, ZISHIDDEN=0`).
Measured against a live store of 5,000+ assets: `ZISHIDDEN` is `0` on every
asset of every type, and on all 39 entries whose CRDT carries `hiddenAssetIDs`
the asset rows still read `ZISHIDDEN=0`.

Authoring CRDTs is out of scope, so `off` is not ours to write.
`--location-presentation` now accepts `small` and `large`; `off` exits 1 with
an explanation instead of silently destroying locations.

Reported by [@tonywalker23](https://x.com/tonywalker23).

### Added — `repair-locations`

Repairs map assets written by 1.2.0's `off`, in place. The coordinates were
only masked, never deleted, so no re-import is needed:

```sh
journal-cli repair-locations --dry-run         # count what is affected
journal-cli repair-locations --live            # restore as small maps
journal-cli repair-locations --to large --live
```

It also clears `ZISUPLOADEDTOCLOUD` on both the repaired assets and their
entries, so the correction reaches your other devices rather than staying
local.

### Fixed — test suite no longer depends on the seed store

`tests/test_write.sh` hardcoded a journal named "Test Journal", so seven
journal-targeting tests failed for anyone running it against a real library
instead of the synthetic fixture. It now resolves the journal's actual name.

## 1.2.0

> [!WARNING]
> `--location-presentation off` in this release **removes the location from
> Journal entirely**, including the Places index. Upgrade to 1.3.0 and run
> `journal-cli repair-locations --live`.

- `--location-presentation` for `write` and `edit` (see the 1.3.0 note above).

## 1.1.0

- `--markdown` renders bodies and titles into Journal's own rich text.
- `render` subcommand: Markdown to RTF on stdout, writes nothing.

## 1.0.x

- Initial release: read, search, export, write, edit, delete/restore,
  journals, media, Live Photos, links, locations, audio transcripts.
