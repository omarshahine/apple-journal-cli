# Changelog

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

It also clears `ZISUPLOADEDTOCLOUD` on the affected entries so the corrected
assets reach your other devices.

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
