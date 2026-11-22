#!/usr/bin/env bash
# Sandbox write tests. Never touches the real Journal store.
set -uo pipefail
# JOURNAL_CLI overrides which binary is under test. Default: the Swift release
# build if present, else the Python reference implementation.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# There is no silent fallback to the Python reference: a missing Swift build
# would otherwise pass the suite against the wrong implementation.
if [ -n "${JOURNAL_CLI:-}" ]; then CLI="$JOURNAL_CLI"
elif [ -x "$ROOT/swift/.build/release/journal-cli" ]; then CLI="$ROOT/swift/.build/release/journal-cli"
else
  echo "no Swift release build at swift/.build/release/journal-cli." >&2
  echo "Build it: (cd swift && swift build -c release), or test the reference:" >&2
  echo "  JOURNAL_CLI=$ROOT/reference/journal-cli.py tests/test_write.sh" >&2
  exit 2
fi
echo "testing: $CLI"
SB=$(mktemp -d /tmp/journal-sandbox.XXXXXX)
# Seed from $JOURNAL_SEED if given (a backup), else the live store.
if [ -n "${JOURNAL_SEED:-}" ]; then
  DB=$("$CLI" sandbox --dir "$SB" --from "$JOURNAL_SEED")
else
  DB=$("$CLI" sandbox --dir "$SB")
fi
if [ -z "$DB" ] || [ ! -f "$DB" ]; then
  echo "could not seed a sandbox. Grant Full Disk Access, or set JOURNAL_SEED=<backup.sqlite>" >&2
  exit 2
fi
ATT="$SB/Attachments"
pass=0; fail=0
store_state(){ sqlite3 "$DB" "select (select count(*) from ZJOURNALENTRYMO), (select group_concat(Z_PK||':'||coalesce(hex(ZASSETORDERING),'')||':'||coalesce(ZUPDATEDDATE,'')||':'||coalesce(ZFLAGGED,'')||':'||coalesce(ZENTRYDATE,''),',') from ZJOURNALENTRYMO), (select group_concat(Z_PK||':'||ZENTRY||':'||coalesce(ZISHIDDEN,'')||':'||coalesce(ZISSLIM,'')||':'||coalesce(hex(ZASSETMETADATA),''),',') from ZJOURNALENTRYASSETMO), (select count(*) from Z_5JOURNALS);" | shasum | cut -c1-16; }
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
      else echo "  FAIL  $1 (want '$3', got '$2')"; fail=$((fail+1)); fi; }
jq_(){ python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
# Export names a file "<YYYY>-<MM>-<DD>-<id>[-slug].md", so the id is the 4th
# hyphen-separated field. A glob like *-"$PK"*.md is not that test: with PK=31
# it also matches every file dated the 31st, and with PK=1 it matches ids 10-19.
# That is a real failure this suite hit ("media linked for media entry",
# want 1 got 2) on any run where a pk collided with a date component.
entryfiles(){ # entryfiles <dir> <pk>
  local d="$1" pk="$2" f base
  for f in "$d"/*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .md)
    [ "$(echo "$base" | cut -d- -f4)" = "$pk" ] && echo "$f"
  done
}

BEFORE=$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO;")
MAX0=$(sqlite3 "$DB" "select Z_MAX from Z_PRIMARYKEY where Z_NAME='JournalEntryMO';")
AMAX0=$(sqlite3 "$DB" "select Z_MAX from Z_PRIMARYKEY where Z_NAME='JournalEntryAssetMO';")
echo "sandbox: $DB  ($BEFORE rows)"

# a real image + a real movie to attach
IMG="$SB/pic.png"; MOV="$SB/clip.mov"
python3 - "$IMG" <<'PY'
import sys,zlib,struct
def chunk(t,d):
    return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
raw=b"".join(b"\x00"+bytes([255,0,0])*4 for _ in range(4))
png=(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",4,4,8,2,0,0,0))
     +chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b""))
open(sys.argv[1],"wb").write(png)
PY
printf 'not really a movie' > "$MOV"

echo "T0 version"
PKG_VERSION=$(python3 -c "import json;print(json.load(open('$ROOT/npm/package.json'))['version'])")
ok "--version matches npm/package.json" "$("$CLI" --version 2>&1)" "journal-cli $PKG_VERSION"
ok "--version exits 0" "$("$CLI" --version >/dev/null 2>&1; echo $?)" "0"

echo "T1 guards"
env -u JOURNAL_DB "$CLI" write --body x >/dev/null 2>&1; ok "refuses live without --live" "$?" "1"
"$CLI" --db "$DB" write --lat 47.6 >/dev/null 2>&1; ok "lat without lon rejected" "$?" "1"
"$CLI" --db "$DB" write --media /nope/missing.png >/dev/null 2>&1; ok "missing media rejected" "$?" "1"
"$CLI" --db "$DB" write >/dev/null 2>&1; ok "empty write rejected" "$?" "1"

echo "T2 text entry"
OUT=$("$CLI" --db "$DB" write --title "Test Title" --body "Hello from the test suite." --date 2026-08-20 2>&1)
PK=$(echo "$OUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "row added" "$(sqlite3 "$DB" 'select count(*) from ZJOURNALENTRYMO;')" "$((BEFORE+1))"
ok "Z_MAX bumped" "$(sqlite3 "$DB" "select Z_MAX from Z_PRIMARYKEY where Z_NAME='JournalEntryMO';")" "$((MAX0+1))"
ok "ZID 16 bytes" "$(sqlite3 "$DB" "select length(ZID) from ZJOURNALENTRYMO where Z_PK=$PK;")" "16"
ok "unsynced" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=$PK;")" "0"
ok "title round-trips" "$("$CLI" --db "$DB" show $PK --json | jq_ 'd["title"]')" "Test Title"
ok "body round-trips"  "$("$CLI" --db "$DB" show $PK --json | jq_ 'd["text"]')" "Hello from the test suite."

echo "T3 location"
LOUT=$("$CLI" --db "$DB" write --body "At the office." --lat 47.62055 --lon -122.34930 \
        --place "Space Needle" --city Seattle 2>&1)
LPK=$(echo "$LOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "map asset created" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$LPK and ZASSETTYPE='multiPinMap';")" "1"
ok "source locationPicker" "$(sqlite3 "$DB" "select ZSOURCE from ZJOURNALENTRYASSETMO where ZENTRY=$LPK;")" "locationPicker"
ok "isSlim set" "$(sqlite3 "$DB" "select ZISSLIM from ZJOURNALENTRYASSETMO where ZENTRY=$LPK;")" "1"
ok "small location is visible" "$(sqlite3 "$DB" "select ZISHIDDEN from ZJOURNALENTRYASSETMO where ZENTRY=$LPK;")" "0"
ok "metadata version byte" "$(sqlite3 "$DB" "select hex(substr(ZASSETMETADATA,1,1)) from ZJOURNALENTRYASSETMO where ZENTRY=$LPK;")" "01"
ok "lat round-trips" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'round(d["assets"][0]["places"][0]["lat"],5)')" "47.62055"
ok "lon round-trips" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'round(d["assets"][0]["places"][0]["lon"],5)')" "-122.3493"
ok "place name" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'd["assets"][0]["places"][0]["name"]')" "Space Needle"
ok "city" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'd["assets"][0]["places"][0]["city"]')" "Seattle"
ok "asset parented to entry" "$(sqlite3 "$DB" "select hex(a.ZPARENTID)=hex(e.ZID) from ZJOURNALENTRYASSETMO a join ZJOURNALENTRYMO e on e.Z_PK=a.ZENTRY where a.ZENTRY=$LPK;")" "1"

echo "T3a location presentation"
# Journal keeps a map's Off state in the entry CRDT (hiddenAssetIDs), never in
# the asset row, and reads ZISHIDDEN=1 as "no such asset" -- which loses the
# location from Places too. So `off` must be refused, not approximated.
OFF0=$(store_state)
POUT=$("$CLI" --db "$DB" write --body "Private location." --lat 47.6 --lon -122.3 \
       --location-presentation off 2>&1); PRC=$?
ok "off is rejected" "$PRC" "1"
ok "off explains itself" "$(printf '%s' "$POUT" | grep -c 'not supported')" "1"
ok "off wrote nothing" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZISHIDDEN=1;")" "0"
ok "off left the store unchanged" "$(store_state)" "$OFF0"
LOUT2=$("$CLI" --db "$DB" write --body "Big map." --lat 47.6 --lon -122.3 --location-presentation large 2>&1)
LPK2=$(echo "$LOUT2" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "large location is visible" "$(sqlite3 "$DB" "select ZISHIDDEN from ZJOURNALENTRYASSETMO where ZENTRY=$LPK2;")" "0"
ok "large location is not slim" "$(sqlite3 "$DB" "select ZISSLIM from ZJOURNALENTRYASSETMO where ZENTRY=$LPK2;")" "0"
ok "no asset is ever hidden" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZISHIDDEN=1;")" "0"

echo "T3b repair-locations"
# Simulate a 1.2.0 import, then repair it in place.
RPK=$(sqlite3 "$DB" "select ZENTRY from ZJOURNALENTRYASSETMO where ZASSETTYPE='multiPinMap' limit 1;")
# Mark both rows as already synced, the way a 1.2.0 import looks once Journal
# has uploaded it -- otherwise the re-upload assertions below prove nothing.
sqlite3 "$DB" "update ZJOURNALENTRYASSETMO set ZISHIDDEN=1, ZISSLIM=0, ZISUPLOADEDTOCLOUD=1 where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';"
sqlite3 "$DB" "update ZJOURNALENTRYMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$RPK;"
ok "setup: asset starts synced" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYASSETMO where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';")" "1"
ok "dry run reports the damage" "$("$CLI" --db "$DB" repair-locations --dry-run 2>&1 | grep -c 'would repair 1 hidden map asset')" "1"
ok "dry run wrote nothing" "$(sqlite3 "$DB" "select ZISHIDDEN from ZJOURNALENTRYASSETMO where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';")" "1"
"$CLI" --db "$DB" repair-locations >/dev/null 2>&1
ok "repair clears hidden" "$(sqlite3 "$DB" "select ZISHIDDEN from ZJOURNALENTRYASSETMO where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';")" "0"
ok "repair defaults to small" "$(sqlite3 "$DB" "select ZISSLIM from ZJOURNALENTRYASSETMO where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';")" "1"
ok "repair re-uploads the entry" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=$RPK;")" "0"
# The asset syncs on its own flag; clearing only the entry's leaves the repair
# local and other devices keep the hidden map.
ok "repair re-uploads the asset" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYASSETMO where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';")" "0"
ok "repair keeps the coordinates" "$("$CLI" --db "$DB" show $RPK --json | jq_ '[p for a in d["assets"] for p in a.get("places",[])] != []')" "True"
ok "repair is idempotent" "$("$CLI" --db "$DB" repair-locations 2>&1 | grep -c 'Nothing to repair')" "1"
sqlite3 "$DB" "update ZJOURNALENTRYASSETMO set ZISHIDDEN=1 where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';"
"$CLI" --db "$DB" repair-locations --to large >/dev/null 2>&1
ok "repair --to large" "$(sqlite3 "$DB" "select ZISSLIM || ZISHIDDEN from ZJOURNALENTRYASSETMO where ZENTRY=$RPK and ZASSETTYPE='multiPinMap';")" "00"

echo "T4 media"
MOUT=$("$CLI" --db "$DB" write --body "With pictures." --media "$IMG" "$MOV" 2>&1)
MPK=$(echo "$MOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "two assets" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$MPK;")" "2"
ok "photo asset" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$MPK and ZASSETTYPE='photo';")" "1"
ok "video asset" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$MPK and ZASSETTYPE='video';")" "1"
ok "two file rows" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$MPK;")" "2"
ok "ZNAME image" "$(sqlite3 "$DB" "select fa.ZNAME from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$MPK and a.ZASSETTYPE='photo';")" "image"
ok "ZNAME video" "$(sqlite3 "$DB" "select fa.ZNAME from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$MPK and a.ZASSETTYPE='video';")" "video"
ok "files exist on disk" "$("$CLI" --db "$DB" show $MPK --json | jq_ 'sum(1 for a in d["assets"] for f in a["files"] if f["exists"])')" "2"
EUUID=$("$CLI" --db "$DB" show $MPK --json | jq_ 'd["uuid"]')
ok "attachment dir named by entry uuid" "$([ -d "$ATT/$EUUID" ] && echo yes || echo no)" "yes"
ok "path is entryuuid/assetuuid/file" "$("$CLI" --db "$DB" show $MPK --json | jq_ 'len(d["assets"][0]["files"][0]["path"].replace("'"$ATT"'/","").split("/"))')" "3"
ok "asset ordering written" "$(sqlite3 "$DB" "select json_array_length(ZASSETORDERING) from ZJOURNALENTRYMO where Z_PK=$MPK;")" "4"
ok "attachments stayed in sandbox" "$(find "$ATT" -type f | wc -l | tr -d ' ')" "2"

echo "T5 media + location together"
BOUT=$("$CLI" --db "$DB" write --body "Trip." --media "$IMG" --lat 21.3 --lon -157.8 --place Waikiki 2>&1)
BPK=$(echo "$BOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "photo + map assets" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$BPK;")" "2"
ok "photo carries coords" "$("$CLI" --db "$DB" show $BPK --json | jq_ 'round([a for a in d["assets"] if a["type"]=="photo"][0]["place"]["lat"],1)')" "21.3"
ok "ordering has both" "$(sqlite3 "$DB" "select json_array_length(ZASSETORDERING) from ZJOURNALENTRYMO where Z_PK=$BPK;")" "4"

echo "T6 export includes media + location"
EXP="$SB/exp"; "$CLI" --db "$DB" export --dir "$EXP" >/dev/null 2>&1
ok "location in frontmatter" "$(entryfiles "$EXP" "$LPK" | xargs -r grep -l 'Space Needle' 2>/dev/null | wc -l | tr -d ' ')" "1"
ok "export wrote files" "$([ "$(ls "$EXP" | wc -l | tr -d ' ')" -ge 3 ] && echo yes || echo no)" "yes"
ok "media linked for media entry" "$(entryfiles "$EXP" "$MPK" | xargs -r grep -l '_resized' 2>/dev/null | wc -l | tr -d ' ')" "1"
ok "media linked for combo entry" "$(entryfiles "$EXP" "$BPK" | xargs -r grep -l '_resized' 2>/dev/null | wc -l | tr -d ' ')" "1"
ok "location scoped to its entry" "$(entryfiles "$EXP" "$LPK" | xargs -r grep -l 'Space Needle' 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "T7 edit"
EOUT=$("$CLI" --db "$DB" write --body "Original body." --title "Original" 2>&1)
EPK=$(echo "$EOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
# Start from a synced entry, or the "marked unsynced" check below proves nothing.
sqlite3 "$DB" "update ZJOURNALENTRYMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$EPK;"
ok "edit starts from a synced entry" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=$EPK;")" "1"
"$CLI" --db "$DB" edit $EPK --body "Rewritten body." --title "Rewritten" >/dev/null 2>&1
ok "body updated" "$("$CLI" --db "$DB" show $EPK --json | jq_ 'd["text"]')" "Rewritten body."
ok "title updated" "$("$CLI" --db "$DB" show $EPK --json | jq_ 'd["title"]')" "Rewritten"
ok "marked unsynced again" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=$EPK;")" "0"
"$CLI" --db "$DB" edit $EPK --bookmark >/dev/null 2>&1
ok "bookmark on" "$(sqlite3 "$DB" "select ZFLAGGED from ZJOURNALENTRYMO where Z_PK=$EPK;")" "1"
"$CLI" --db "$DB" edit $EPK --no-bookmark >/dev/null 2>&1
ok "bookmark off" "$(sqlite3 "$DB" "select ZFLAGGED from ZJOURNALENTRYMO where Z_PK=$EPK;")" "0"
"$CLI" --db "$DB" edit $EPK --date 2024-03-05 >/dev/null 2>&1
ok "date updated" "$("$CLI" --db "$DB" show $EPK --json | jq_ 'd["date"][:10]')" "2024-03-05"
# Wall clock must round-trip in the caller's timezone, and the stored value must
# be the true instant (the Swift build's encoding), so both implementations read
# each other's writes. CI repeats the suite under a non-UTC TZ; under UTC alone
# an offset applied on write but not on read cancels out and hides.
"$CLI" --db "$DB" edit $EPK --date "2024-03-05 23:30" >/dev/null 2>&1
ok "date+time round-trips" "$("$CLI" --db "$DB" show $EPK --json | jq_ 'd["date"]')" "2024-03-05 23:30:00"
ok "date stored as the true instant" "$(sqlite3 "$DB" "select cast(ZENTRYDATE as integer) from ZJOURNALENTRYMO where Z_PK=$EPK;")" \
  "$(python3 -c 'import datetime;print(int(datetime.datetime(2024,3,5,23,30).timestamp())-978307200)')"
"$CLI" --db "$DB" edit $EPK --lat 51.5007 --lon -0.1246 --place "Big Ben" --city London >/dev/null 2>&1
ok "location added" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "1"
ok "location reads back" "$("$CLI" --db "$DB" show $EPK --json | jq_ '[p for a in d["assets"] for p in a.get("places",[])][0]["name"]')" "Big Ben"
"$CLI" --db "$DB" edit $EPK --lat 48.8584 --lon 2.2945 --place "Eiffel Tower" >/dev/null 2>&1
ok "location replaced not duplicated" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "1"
EOFF0=$(store_state)
"$CLI" --db "$DB" edit $EPK --lat 48.8584 --lon 2.2945 --location-presentation off >/dev/null 2>&1
ok "edit off is rejected" "$?" "1"
ok "edit refuses to hide location" "$(sqlite3 "$DB" "select ZISHIDDEN from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "0"
ok "edit off left the store unchanged" "$(store_state)" "$EOFF0"
"$CLI" --db "$DB" edit $EPK --lat 48.8584 --lon 2.2945 --location-presentation small >/dev/null 2>&1
ok "edit can shrink location" "$(sqlite3 "$DB" "select ZISSLIM from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "1"
"$CLI" --db "$DB" edit $EPK --lat 48.8584 --lon 2.2945 --location-presentation large >/dev/null 2>&1
ok "edit can enlarge location" "$(sqlite3 "$DB" "select ZISSLIM || ZISHIDDEN from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "00"
"$CLI" --db "$DB" edit $EPK --add-media "$IMG" >/dev/null 2>&1
ok "media added to existing entry" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='photo';")" "1"
ok "ordering covers both assets" "$(sqlite3 "$DB" "select json_array_length(ZASSETORDERING) from ZJOURNALENTRYMO where Z_PK=$EPK;")" "4"
"$CLI" --db "$DB" edit $EPK --clear-location >/dev/null 2>&1
ok "location cleared" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "0"
ok "photo survived clear" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='photo';")" "1"
ok "ordering pruned" "$(sqlite3 "$DB" "select json_array_length(ZASSETORDERING) from ZJOURNALENTRYMO where Z_PK=$EPK;")" "2"
"$CLI" --db "$DB" edit $EPK >/dev/null 2>&1; ok "no-op edit rejected" "$?" "1"

echo "T7a media removal"
ROUT=$("$CLI" --db "$DB" write --body "Two pics." --media "$IMG" "$MOV" 2>&1)
RPK=$(echo "$ROUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
RUUID=$("$CLI" --db "$DB" show $RPK --json | jq_ 'd["uuid"]')
AID=$("$CLI" --db "$DB" show $RPK --json | jq_ '[a for a in d["assets"] if a["type"]=="photo"][0]["id"]')
VID=$("$CLI" --db "$DB" show $RPK --json | jq_ '[a for a in d["assets"] if a["type"]=="video"][0]["id"]')
"$CLI" --db "$DB" edit $RPK --remove-media $AID >/dev/null 2>&1
ok "one asset removed" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$RPK;")" "1"
ok "video kept" "$(sqlite3 "$DB" "select ZASSETTYPE from ZJOURNALENTRYASSETMO where ZENTRY=$RPK;")" "video"
ok "file rows pruned" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$RPK;")" "1"
ok "ordering pruned to one" "$(sqlite3 "$DB" "select json_array_length(ZASSETORDERING) from ZJOURNALENTRYMO where Z_PK=$RPK;")" "2"
ok "files on disk reduced" "$(find "$ATT/$RUUID" -type f 2>/dev/null | wc -l | tr -d ' ')" "1"
"$CLI" --db "$DB" edit $RPK --remove-media 99999 >/dev/null 2>&1
ok "unknown asset id rejected" "$?" "1"
NONMEDIA=$(sqlite3 "$DB" "select Z_PK from ZJOURNALENTRYASSETMO where ZASSETTYPE not in ('photo','video','livePhoto') limit 1;")
if [ -n "$NONMEDIA" ]; then
  NMENTRY=$(sqlite3 "$DB" "select ZENTRY from ZJOURNALENTRYASSETMO where Z_PK=$NONMEDIA;")
  "$CLI" --db "$DB" edit $NMENTRY --remove-media $NONMEDIA >/dev/null 2>&1
  ok "non-media asset refused" "$?" "1"
fi
"$CLI" --db "$DB" edit $RPK --remove-all-media >/dev/null 2>&1
ok "remove-all cleared assets" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$RPK;")" "0"
ok "remove-all cleared files" "$([ -z "$(find "$ATT/$RUUID" -type f 2>/dev/null)" ] && echo yes || echo no)" "yes"
"$CLI" --db "$DB" delete $RPK --hard >/dev/null 2>&1

echo "T7b CRDT guard"
CPK=$(sqlite3 "$DB" "select Z_PK from ZJOURNALENTRYMO where ZMERGEABLEATTRIBUTES is not null limit 1;")
if [ -z "$CPK" ]; then
  # The synthetic fixture has no app-authored entries. Make one: Journal.app
  # writes a CRDT merge copy into ZMERGEABLEATTRIBUTES, which is all the guard
  # keys on. Without this the block below used to run zero assertions in CI.
  COUT=$("$CLI" --db "$DB" write --body "app authored" 2>&1)
  CPK=$(echo "$COUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  sqlite3 "$DB" "update ZJOURNALENTRYMO set ZMERGEABLEATTRIBUTES=x'6372647407000000' where Z_PK=$CPK;"
fi
ok "CRDT entry available" "$([ -n "$CPK" ] && echo yes || echo no)" "yes"
if [ -n "$CPK" ]; then
  "$CLI" --db "$DB" edit $CPK --body "should be refused" >/dev/null 2>&1
  ok "text edit refused on CRDT entry" "$?" "1"
  "$CLI" --db "$DB" edit $CPK --lat 1.0 --lon 2.0 --place Somewhere >/dev/null 2>&1
  ok "location edit allowed on CRDT entry" "$?" "0"
  "$CLI" --db "$DB" edit $CPK --body "forced" --force >/dev/null 2>&1
  ok "--force overrides guard" "$("$CLI" --db "$DB" show $CPK --json | jq_ 'd["text"]')" "forced"
fi

echo "T7c delete"
"$CLI" --db "$DB" delete $PK >/dev/null 2>&1
ok "soft: row kept" "$(sqlite3 "$DB" "select ZRECENTLYDELETED from ZJOURNALENTRYMO where Z_PK=$PK;")" "1"
ok "soft: hidden" "$("$CLI" --db "$DB" search 'test suite' --json | jq_ 'len(d)')" "0"
"$CLI" --db "$DB" delete $MPK --hard >/dev/null 2>&1
ok "hard: entry gone" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO where Z_PK=$MPK;")" "0"
ok "hard: assets gone" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$MPK;")" "0"
ok "hard: files removed" "$([ -d "$ATT/$EUUID" ] && echo yes || echo no)" "no"

echo "T9 resize"
BIG="$SB/big.png"
python3 - "$BIG" <<'PZ'
import sys,zlib,struct
W,H=4000,3000
def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
raw=b"".join(b"\x00"+bytes([120,140,160])*W for _ in range(H))
png=(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",W,H,8,2,0,0,0))
     +chunk(b"IDAT",zlib.compress(raw,1))+chunk(b"IEND",b""))
open(sys.argv[1],"wb").write(png)
PZ
ZOUT=$("$CLI" --db "$DB" write --body "Big image." --media "$BIG" 2>&1)
ZPK=$(echo "$ZOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ZF=$("$CLI" --db "$DB" show $ZPK --json | jq_ 'd["assets"][0]["files"][0]["path"]')
ZW=$(sips -g pixelWidth "$ZF" 2>/dev/null | awk '/pixelWidth/{print $2}')
ok "big image downscaled to Journal cap" "$ZW" "2830"
NOUT=$("$CLI" --db "$DB" write --body "Big image raw." --media "$BIG" --no-resize 2>&1)
NPK=$(echo "$NOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
NF=$("$CLI" --db "$DB" show $NPK --json | jq_ 'd["assets"][0]["files"][0]["path"]')
NW=$(sips -g pixelWidth "$NF" 2>/dev/null | awk '/pixelWidth/{print $2}')
ok "--no-resize keeps original size" "$NW" "4000"
SOUT=$("$CLI" --db "$DB" write --body "Small image." --media "$IMG" 2>&1)
SPK=$(echo "$SOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
SF=$("$CLI" --db "$DB" show $SPK --json | jq_ 'd["assets"][0]["files"][0]["path"]')
SW=$(sips -g pixelWidth "$SF" 2>/dev/null | awk '/pixelWidth/{print $2}')
ok "small image untouched" "$SW" "4"
"$CLI" --db "$DB" delete $ZPK --hard >/dev/null 2>&1
"$CLI" --db "$DB" delete $NPK --hard >/dev/null 2>&1
"$CLI" --db "$DB" delete $SPK --hard >/dev/null 2>&1

echo "T10 live photo"
LPOUT=$("$CLI" --db "$DB" write --body "Live one." --live-photo "$IMG" "$MOV" 2>&1)
LPPK=$(echo "$LPOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "livePhoto asset" "$(sqlite3 "$DB" "select ZASSETTYPE from ZJOURNALENTRYASSETMO where ZENTRY=$LPPK;")" "livePhoto"
ok "two file rows on one asset" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$LPPK;")" "2"
ok "names image+video" "$(sqlite3 "$DB" "select group_concat(fa.ZNAME) from (select ZNAME from ZJOURNALENTRYASSETFILEATTACHMENTMO fa2 join ZJOURNALENTRYASSETMO a on a.Z_PK=fa2.ZASSET where a.ZENTRY=$LPPK order by fa2.ZNAME) fa;")" "image,video"
ok "both index 0" "$(sqlite3 "$DB" "select group_concat(distinct fa.ZINDEX) from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$LPPK;")" "0"
ok "plain filenames (no _resized)" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$LPPK and fa.ZFILEPATH like '%_resized%';")" "0"
"$CLI" --db "$DB" write --body x --live-photo "$MOV" "$IMG" >/dev/null 2>&1
ok "wrong pair order rejected" "$?" "1"
"$CLI" --db "$DB" delete $LPPK --hard >/dev/null 2>&1

echo "T11 photos-link path heuristic"
PL="$SB/fake.photoslibrary/originals/A/AABBCCDD-1111-2222-3333-444455556666.jpg"
mkdir -p "$(dirname "$PL")"; cp "$IMG" "$PL" 2>/dev/null || sips -s format jpeg "$IMG" --out "$PL" >/dev/null 2>&1
PLOUT=$("$CLI" --db "$DB" write --body "Linked." --media "$PL" --photos-link 2>&1)
PLPK=$(echo "$PLOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "assetIdentifier written" "$("$CLI" --db "$DB" show $PLPK --json >/dev/null 2>&1; sqlite3 "$DB" "select instr(ZASSETMETADATA,'AABBCCDD-1111-2222-3333-444455556666/L0/001')>1 from ZJOURNALENTRYASSETMO where ZENTRY=$PLPK;")" "1"
"$CLI" --db "$DB" delete $PLPK --hard >/dev/null 2>&1

echo "T12 journals"
NJ=$(sqlite3 "$DB" "select count(*) from ZJOURNALMO where coalesce(ZUSERDELETED,0)=0;")
if [ "$NJ" -ge 2 ]; then
  TJPK=$(sqlite3 "$DB" "select Z_PK from ZJOURNALMO where ZMERGEABLEATTRIBUTES is not null limit 1;")
  TJOPT=$(sqlite3 "$DB" "select Z_OPT from ZJOURNALMO where Z_PK=$TJPK;")
  ok "journals lists both" "$("$CLI" --db "$DB" journals --json | jq_ 'len(d)')" "$NJ"
  # The name lives inside the journal's CRDT blob, not in a column, so the only
  # thing we can assert seed-independently is that one came back. The synthetic
  # fixture calls it "Test Journal"; a real store calls it whatever you named it.
  TJ=$("$CLI" --db "$DB" journals --json | jq_ '[j for j in d if j["pk"]=='$TJPK'][0]["name"]')
  ok "name resolved from CRDT" "$([ -n "$TJ" ] && [ "$TJ" != "None" ] && echo resolved || echo "empty")" "resolved"
  # A two-character name is the case the old printable-run scan lost: too
  # short to survive its minimum run length, so the name came back as
  # whichever replica-id bytes happened to be printable -- and those change
  # as iCloud touches the record, so it was not even stable between runs.
  # Find it by its encoded value/key pair ("TV", "title") so the check stays
  # seed-independent; a store without such a journal skips it.
  SJPK=$(sqlite3 "$DB" "select Z_PK from ZJOURNALMO where instr(ZMERGEABLEATTRIBUTES, X'1202545612057469746C65')>0 limit 1;")
  if [ -n "$SJPK" ]; then
    ok "short name resolved from CRDT" "$("$CLI" --db "$DB" journals --json | jq_ '[j for j in d if j["pk"]=='$SJPK'][0]["name"]')" "TV"
    "$CLI" --db "$DB" write --body "In the short-named journal." --journal "TV" >/dev/null 2>&1
    ok "short name addressable by write" "$?" "0"
  fi
  JOUT=$("$CLI" --db "$DB" write --body "In the test journal." --journal "$TJ" 2>&1)
  JPK=$(echo "$JOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "join row written" "$(sqlite3 "$DB" "select Z_6JOURNALS from Z_5JOURNALS where Z_5ENTRIES=$JPK;")" "$TJPK"
  ok "write warns membership is local staging" "$(echo "$JOUT" | grep -c 'Mac-local staging membership')" "1"
  ok "staging write does not fake a journal upload" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "1"
  ok "staging write leaves journal version unchanged" "$(sqlite3 "$DB" "select Z_OPT from ZJOURNALMO where Z_PK=$TJPK;")" "$TJOPT"
  DOUT=$("$CLI" --db "$DB" write --body "In the default journal." 2>&1)
  DPK=$(echo "$DOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "default write has no join row" "$(sqlite3 "$DB" "select count(*) from Z_5JOURNALS where Z_5ENTRIES=$DPK;")" "0"
  ok "default write has no staging warning" "$(echo "$DOUT" | grep -c 'Mac-local staging membership')" "0"
  sqlite3 "$DB" "update ZJOURNALMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$TJPK;"
  EOUT=$("$CLI" --db "$DB" edit $DPK --journal "$TJ" 2>&1)
  ok "edit stages an unsynced entry in journal" "$(sqlite3 "$DB" "select Z_6JOURNALS from Z_5JOURNALS where Z_5ENTRIES=$DPK;")" "$TJPK"
  ok "edit warns membership is local staging" "$(echo "$EOUT" | grep -c 'Mac-local staging membership')" "1"
  ok "staged move does not fake a journal upload" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "1"
  "$CLI" --db "$DB" edit $DPK --journal 1 >/dev/null 2>&1
  ok "edit moves back to default (join row dropped)" "$(sqlite3 "$DB" "select count(*) from Z_5JOURNALS where Z_5ENTRIES=$DPK;")" "0"
  sqlite3 "$DB" "update ZJOURNALENTRYMO set ZMERGEABLEATTRIBUTES=X'01' where Z_PK=$DPK;"
  "$CLI" --db "$DB" edit $DPK --journal "$TJ" >/dev/null 2>&1
  ok "direct journal move refused for CRDT entry" "$?" "1"
  ok "refused CRDT move is unchanged" "$(sqlite3 "$DB" "select count(*) from Z_5JOURNALS where Z_5ENTRIES=$DPK;")" "0"
  sqlite3 "$DB" "update ZJOURNALENTRYMO set ZMERGEABLEATTRIBUTES=NULL where Z_PK=$DPK;"
  AUDIT=$("$CLI" --db "$DB" sync-journals --journal "$TJ" 2>&1)
  ok "sync-journals finds local-only membership" "$(echo "$AUDIT" | grep -F "$TJ:" | grep -Ec '[1-9][0-9]* entr(y|ies)')" "1"
  ok "sync-journals gives native move instructions" "$(echo "$AUDIT" | grep -c 'Select Entries > Select All')" "1"
  ok "sync-journals is read-only" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "1"
  "$CLI" --db "$DB" write --body x --journal "No Such Journal" >/dev/null 2>&1
  ok "unknown journal rejected" "$?" "1"
  "$CLI" --db "$DB" delete $JPK --hard >/dev/null 2>&1
  ok "hard delete leaves journal sync state unchanged" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "1"
  "$CLI" --db "$DB" delete $DPK --hard >/dev/null 2>&1
else
  echo "  SKIP  (seed has one journal)"
fi

echo "T12b multi-journal membership"
# Membership is many-to-many (Z_5JOURNALS); the app lists an entry under every
# journal it belongs to. Needs two custom journals; addressed by id so the
# checks don't depend on what the seed calls them.
J1=$(sqlite3 "$DB" "select Z_PK from ZJOURNALMO where ZMERGEABLEATTRIBUTES is not null and coalesce(ZUSERDELETED,0)=0 order by Z_PK limit 1;")
J2=$(sqlite3 "$DB" "select Z_PK from ZJOURNALMO where ZMERGEABLEATTRIBUTES is not null and coalesce(ZUSERDELETED,0)=0 order by Z_PK limit 1 offset 1;")
DEFPK=$(sqlite3 "$DB" "select Z_PK from ZJOURNALMO where ZMERGEABLEATTRIBUTES is null and ZSORTCATEGORY<0 limit 1;")
if [ -n "$J1" ] && [ -n "$J2" ]; then
  mj(){ sqlite3 "$DB" "select group_concat(Z_6JOURNALS) from (select Z_6JOURNALS from Z_5JOURNALS where Z_5ENTRIES=$1 order by Z_6JOURNALS);"; }
  MOUT=$("$CLI" --db "$DB" write --body "In two journals." --journal $J1 --add-journal $J2 2>&1)
  MPK=$(echo "$MOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "write --journal + --add-journal joins both" "$(mj $MPK)" "$J1,$J2"
  ok "write warns membership is local staging" "$(echo "$MOUT" | grep -c 'Mac-local staging membership')" "1"
  M2PK=$("$CLI" --db "$DB" write --body "Repeated flag." --journal $J1 --journal $J2 2>&1 | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "write repeats --journal" "$(mj $M2PK)" "$J1,$J2"
  "$CLI" --db "$DB" edit $M2PK --remove-journal $J2 >/dev/null 2>&1
  ok "edit --remove-journal drops only that one" "$(mj $M2PK)" "$J1"
  "$CLI" --db "$DB" edit $M2PK --add-journal $J2 >/dev/null 2>&1
  ok "edit --add-journal keeps the others" "$(mj $M2PK)" "$J1,$J2"
  "$CLI" --db "$DB" edit $M2PK --add-journal $J2 >/dev/null 2>&1
  ok "edit --add-journal is idempotent" "$(mj $M2PK)" "$J1,$J2"
  "$CLI" --db "$DB" edit $M2PK --journal $J1 >/dev/null 2>&1
  ok "edit --journal still moves (replaces all)" "$(mj $M2PK)" "$J1"
  "$CLI" --db "$DB" edit --journal $J2 --journal $J1 $M2PK >/dev/null 2>&1
  ok "edit repeated --journal; id after the flags" "$(mj $M2PK)" "$J1,$J2"
  "$CLI" --db "$DB" edit $M2PK --journal $J1 --add-journal $J2 >/dev/null 2>&1
  ok "--journal mixed with --add-journal refused" "$?" "1"
  ok "refused mix leaves memberships unchanged" "$(mj $M2PK)" "$J1,$J2"
  if [ -n "$DEFPK" ]; then
    "$CLI" --db "$DB" edit $M2PK --add-journal $DEFPK >/dev/null 2>&1
    ok "--add-journal to the default journal refused" "$?" "1"
  fi
  "$CLI" --db "$DB" edit $M2PK --add-journal $J1 --add-journal "No Such Journal" >/dev/null 2>&1
  ok "unknown --add-journal refused" "$?" "1"
  ok "refused add leaves memberships unchanged" "$(mj $M2PK)" "$J1,$J2"
  "$CLI" --db "$DB" edit $M2PK --remove-journal $J1 --remove-journal $J2 >/dev/null 2>&1
  ok "removing every membership returns it to the default" "$(sqlite3 "$DB" "select count(*) from Z_5JOURNALS where Z_5ENTRIES=$M2PK;")" "0"
  "$CLI" --db "$DB" delete $MPK --hard >/dev/null 2>&1
  "$CLI" --db "$DB" delete $M2PK --hard >/dev/null 2>&1
else
  echo "  SKIP  (seed has fewer than two custom journals)"
fi

echo "T14 links"
if command -v swift >/dev/null; then
  KOUT=$("$CLI" --db "$DB" write --body "With a link." --link "https://example.com/post" --link-title "Example Post" 2>&1)
  KPK=$(echo "$KOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "link asset row" "$(sqlite3 "$DB" "select ZASSETTYPE from ZJOURNALENTRYASSETMO where ZENTRY=$KPK;")" "link"
  ok "source shareSheet" "$(sqlite3 "$DB" "select ZSOURCE from ZJOURNALENTRYASSETMO where ZENTRY=$KPK;")" "shareSheet"
  ok "contenttype unknown" "$(sqlite3 "$DB" "select ZCONTENTTYPE from ZJOURNALENTRYASSETMO where ZENTRY=$KPK;")" "unknown"
  ok "no file attachments" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETFILEATTACHMENTMO fa join ZJOURNALENTRYASSETMO a on a.Z_PK=fa.ZASSET where a.ZENTRY=$KPK;")" "0"
  ok "url round-trips" "$("$CLI" --db "$DB" show $KPK --json | jq_ 'd["assets"][0]["url"]')" "https://example.com/post"
  ok "title round-trips" "$("$CLI" --db "$DB" show $KPK --json | jq_ 'd["assets"][0]["link_title"]')" "Example Post"
  ok "in ordering" "$(sqlite3 "$DB" "select json_array_length(ZASSETORDERING) from ZJOURNALENTRYMO where Z_PK=$KPK;")" "2"
  "$CLI" --db "$DB" write --body x --link "notaurl" >/dev/null 2>&1
  ok "bad url rejected" "$?" "1"
  "$CLI" --db "$DB" edit $KPK --add-link "https://example.org/second" >/dev/null 2>&1
  ok "edit adds second link" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$KPK and ZASSETTYPE='link';")" "2"
  "$CLI" --db "$DB" delete $KPK --hard >/dev/null 2>&1
else
  echo "  SKIP  (no swift)"
fi

echo "T13 synced hard-delete guard"
SPKS=$(sqlite3 "$DB" "select Z_PK from ZJOURNALENTRYMO where ZISUPLOADEDTOCLOUD=1 and coalesce(ZRECENTLYDELETED,0)=0 limit 1;")
if [ -n "$SPKS" ]; then
  "$CLI" --db "$DB" delete $SPKS --hard >/dev/null 2>&1
  ok "hard delete refused on synced entry" "$?" "1"
  ok "row survived" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO where Z_PK=$SPKS;")" "1"
  "$CLI" --db "$DB" delete $SPKS --hard --force >/dev/null 2>&1
  ok "--force overrides" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO where Z_PK=$SPKS;")" "0"
fi
SOFTPK=$(sqlite3 "$DB" "select Z_PK from ZJOURNALENTRYMO where ZISUPLOADEDTOCLOUD=1 and coalesce(ZRECENTLYDELETED,0)=0 limit 1;")
if [ -n "$SOFTPK" ]; then
  "$CLI" --db "$DB" delete $SOFTPK >/dev/null 2>&1
  ok "soft delete marks unsynced" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=$SOFTPK;")" "0"
fi

echo "T15 recently deleted lifecycle"
LOUT2=$("$CLI" --db "$DB" write --body "To be deleted and restored." 2>&1)
LPK2=$(echo "$LOUT2" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
"$CLI" --db "$DB" delete $LPK2 >/dev/null 2>&1
ok "listed in deleted" "$("$CLI" --db "$DB" deleted --json | jq_ 'sum(1 for e in d if e["id"]=='$LPK2')')" "1"
"$CLI" --db "$DB" restore $LPK2 >/dev/null 2>&1
ok "restore clears flag" "$(sqlite3 "$DB" "select coalesce(ZRECENTLYDELETED,0) from ZJOURNALENTRYMO where Z_PK=$LPK2;")" "0"
ok "restore marks unsynced" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=$LPK2;")" "0"
ok "restored entry searchable" "$("$CLI" --db "$DB" search 'deleted and restored' --json | jq_ 'len(d)')" "1"
"$CLI" --db "$DB" restore $LPK2 >/dev/null 2>&1
ok "restore of non-deleted rejected" "$?" "1"
"$CLI" --db "$DB" delete $LPK2 >/dev/null 2>&1
sqlite3 "$DB" "update ZJOURNALENTRYMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$LPK2;"
EOUT2=$("$CLI" --db "$DB" empty 2>&1)
ok "empty skips synced" "$(echo "$EOUT2" | grep -cE 'Skipped [0-9]+ synced')" "1"
ok "synced row survived empty" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO where Z_PK=$LPK2;")" "1"
"$CLI" --db "$DB" empty --force >/dev/null 2>&1
ok "empty --force purges" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO where Z_PK=$LPK2;")" "0"

echo "T16 dry run"
BEFORE_DR=$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO;")
DR=$("$CLI" --db "$DB" write --body "never lands" --dry-run 2>&1)
ok "write dry-run says so" "$(echo "$DR" | grep -c 'DRY RUN')" "1"
ok "write dry-run wrote nothing" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO;")" "$BEFORE_DR"
DROUT=$("$CLI" --db "$DB" write --body "dr target" 2>&1); DRPK=$(echo "$DROUT"|grep -oE 'entry [0-9]+'|grep -oE '[0-9]+')
"$CLI" --db "$DB" edit $DRPK --body "changed" --dry-run >/dev/null 2>&1
ok "edit dry-run left body" "$("$CLI" --db "$DB" show $DRPK --json | jq_ 'd["text"]')" "dr target"
"$CLI" --db "$DB" delete $DRPK --dry-run >/dev/null 2>&1
ok "delete dry-run left row" "$(sqlite3 "$DB" "select coalesce(ZRECENTLYDELETED,0) from ZJOURNALENTRYMO where Z_PK=$DRPK;")" "0"
"$CLI" --db "$DB" edit 999999 --body x --dry-run >/dev/null 2>&1
ok "edit dry-run validates id" "$?" "1"
"$CLI" --db "$DB" delete $DRPK --hard >/dev/null 2>&1

# Probe the capability rather than parsing help text: --dry-run writes
# nothing, so this just asks whether this CLI understands --markdown at all.
# The Python reference in CI does not, and skips the block.
"$CLI" --db "$DB" write --body probe --markdown --dry-run >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "T17 markdown rendering"
  MD=$(printf '###### Reflect on today:\n1\\. first thing\n\n---\n\nIt was **hard**\\. See [my site](https://example.com)\n\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e \xf0\x9f\x9a\x95')
  MDOUT=$(printf '%s' "$MD" | "$CLI" --db "$DB" write --title 'Day 9 \- Naoshima' --markdown 2>&1)
  MDPK=$(echo "$MDOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  MDTEXT=$("$CLI" --db "$DB" show $MDPK --json | jq_ 'd["text"]')
  ok "heading marker stripped"  "$(printf '%s' "$MDTEXT" | grep -c '#')" "0"
  ok "escapes removed"          "$(printf '%s' "$MDTEXT" | grep -c '\\\\\.')" "0"
  ok "horizontal rule dropped"  "$(printf '%s' "$MDTEXT" | grep -cE '^---$')" "0"
  ok "emphasis markers gone"    "$(printf '%s' "$MDTEXT" | grep -c '\*\*')" "0"
  ok "heading text kept"        "$(printf '%s' "$MDTEXT" | grep -c 'Reflect on today:')" "1"
  ok "link flattened"           "$(printf '%s' "$MDTEXT" | grep -c 'my site (https://example.com)')" "1"
  JP=$(printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e')
  ok "unicode preserved"        "$(printf '%s' "$MDTEXT" | grep -cF "$JP")" "1"
  ok "title de-escaped"         "$("$CLI" --db "$DB" show $MDPK --json | jq_ 'd["title"]')" "Day 9 - Naoshima"
  ok "bold run in RTF"          "$(sqlite3 "$DB" "select instr(cast(ZTEXT as text),'\\b')>0 from ZJOURNALENTRYMO where Z_PK=$MDPK;")" "1"
  ok "bold font in RTF"         "$(sqlite3 "$DB" "select instr(cast(ZTEXT as text),'Bold')>0 from ZJOURNALENTRYMO where Z_PK=$MDPK;")" "1"
  LMD=$(printf -- '- alpha\n- beta\n\n1. one\n2. two\n\n~~gone~~ and *slanted*')
  LOUT=$(printf '%s' "$LMD" | "$CLI" --db "$DB" write --markdown 2>&1)
  LPK3=$(echo "$LOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  rtfhas() { sqlite3 "$DB" "select instr(cast(ZTEXT as text),'$2')>0 from ZJOURNALENTRYMO where Z_PK=$1;"; }
  ok "bulleted list in RTF"  "$(rtfhas $LPK3 disc)" "1"
  ok "numbered list in RTF"  "$(rtfhas $LPK3 decimal)" "1"
  ok "list markers emitted"  "$(rtfhas $LPK3 listtext)" "1"
  ok "strikethrough in RTF"  "$(rtfhas $LPK3 strike)" "1"
  ok "italic in RTF"         "$(rtfhas $LPK3 '\i ')" "1"
  ok "list bullets stripped" "$("$CLI" --db "$DB" show $LPK3 --json | jq_ 'd["text"]' | grep -c '^- ')" "0"
  ESC=$(printf -- '1\\. literal not a list')
  EOUT3=$(printf '%s' "$ESC" | "$CLI" --db "$DB" write --markdown 2>&1)
  EPK3=$(echo "$EOUT3" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "escaped number stays plain" "$("$CLI" --db "$DB" show $EPK3 --json | jq_ 'd["text"]')" "1. literal not a list"
  ok "escaped number is not a list" "$(sqlite3 "$DB" "select instr(cast(ZTEXT as text),'listtext') from ZJOURNALENTRYMO where Z_PK=$EPK3;")" "0"

  ESC2=$(printf -- 'a \\*literal\\* pair and \\_under\\_ too')
  E2OUT=$(printf '%s' "$ESC2" | "$CLI" --db "$DB" write --markdown 2>&1)
  E2PK=$(echo "$E2OUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "escaped emphasis stays literal" "$("$CLI" --db "$DB" show $E2PK --json | jq_ 'd["text"]')" "a *literal* pair and _under_ too"
  ok "escaped emphasis not italic"    "$(sqlite3 "$DB" "select instr(cast(ZTEXT as text),'Italic') from ZJOURNALENTRYMO where Z_PK=$E2PK;")" "0"
  # fix-text decides what to repair by comparing an entry's stored bytes with
  # `render` output, so that equality is load-bearing.
  rt_check() {
    RTO=$(printf '%s' "$1" | "$CLI" --db "$DB" write --markdown 2>&1)
    RTP=$(echo "$RTO" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
    STORED=$(sqlite3 "$DB" "select hex(ZTEXT) from ZJOURNALENTRYMO where Z_PK=$RTP;")
    WANT=$(printf '%s' "$1" | "$CLI" render | xxd -p | tr -d '\n' | tr 'a-f' 'A-F')
    [ "$STORED" = "$WANT" ] && echo 1 || echo 0
  }
  ok "render matches stored: italic"  "$(rt_check '*all italic here*')" "1"
  ok "render matches stored: escaped" "$(rt_check '\*\*literal\*\* stays')" "1"
  ok "render matches stored: fenced"  "$(rt_check '```
# comment inside code
```')" "1"
  ok "render --plain works"           "$(printf '###### H' | "$CLI" render --plain)" "H"
  ok "inline code kept verbatim"      "$(printf 'Use `**lit**` here' | "$CLI" render --plain)" "Use \`**lit**\` here"
  ok "title keeps list-like text"     "$(printf '1. first' | "$CLI" render --inline)" "1. first"
  ok "image syntax untouched"         "$(printf '![alt](https://e.com/i.png)' | "$CLI" render --plain)" '![alt](https://e.com/i.png)'
  ok "link destination kept literal"  "$("$CLI" render --body '[link](https://example.com/*item*)' --plain)" "link (https://example.com/*item*)"
  ok "fenced blank lines kept"          "$(printf '```\na\n\n\nb\n  \nc\n```' | "$CLI" render --plain | python3 -c 'import sys;print(repr(sys.stdin.read()))')" "'a\\n\\n\\nb\\n  \\nc'"
  ok "trailing fenced blank lines kept" "$(printf '```\na\n\n\n```' | "$CLI" render | python3 -c 'import sys;r=sys.stdin.read();print(r[r.rindex(" a")+2:].count(chr(92)+chr(10)))')" "2"
  BOUT=$("$CLI" --db "$DB" write --body "boundary" --media "$IMG" 2>&1)
  BPK2=$(echo "$BOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  BAID=$("$CLI" --db "$DB" show $BPK2 --json | jq_ '[a for a in d["assets"] if a["type"]=="photo"][0]["id"]')
  "$CLI" edit --remove-media $BAID --db "$DB" $BPK2 >/dev/null 2>&1
  ok "--db ends a list option's values" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$BPK2;")" "0"
  ok "fence-like line inside a block"  "$(printf '```\n```literal\n**x**\n```\nafter' | "$CLI" render --plain)" "$(printf '```literal\n**x**\nafter')"
  # --- third review pass (Markdown): nested emphasis and private-use text ---
  ok "nested bold stays bold"          "$("$CLI" render --body '**outer __inner__ outer**' | grep -c 'b0')" "0"
  PUAFILE="$SB/pua.md"
  python3 "$ROOT/tests/make-pua.py" "$PUAFILE"
  PUAWANT=$(python3 "$ROOT/tests/make-pua.py" --expect)
  ok "private-use text survives a full BMP window" "$("$CLI" render --body-file "$PUAFILE" --plain)" "$PUAWANT"
  ok "control characters do not end italics" "$(printf '*a\002b\007c*' | "$CLI" render | grep -c 'i0')" "0"
  ok "control characters are kept as text"  "$(printf '*a\002b\007c*' | "$CLI" render --plain | od -An -c | tr -s ' ')" "$(printf 'a\002b\007c' | od -An -c | tr -s ' ')"
  # --- end third review pass (Markdown) ---
  # Fixed-format dates ignore the user's calendar (-AppleLocale is a
  # Foundation argument-domain default, honored per process).
  BUD="th_TH@calendar=buddhist"
  CALOUT=$("$CLI" --db "$DB" write --body "calendar" --date 2026-01-05 -AppleLocale "$BUD" 2>&1)
  CALPK=$(echo "$CALOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "--date parses as Gregorian under a Buddhist calendar" "$("$CLI" --db "$DB" show $CALPK --json | jq_ 'd["date"][:10]')" "2026-01-05"
  ok "write reports a Gregorian date" "$(echo "$CALOUT" | grep -c 'dated 2026-01-05')" "1"
  ok "show prints Gregorian under a Buddhist calendar" "$("$CLI" --db "$DB" show $CALPK --json -AppleLocale "$BUD" | jq_ 'd["date"][:10]')" "2026-01-05"

  # The global --db pass must not take an option's value for itself. It used
  # to treat `--body --db` as a database selector and eat the next argument.
  ok "--db as a --body value is text" "$("$CLI" render --body '--db' --plain 2>&1)" "--db"
  DBV=$("$CLI" --db "$DB" write --title '--db' --body "$SB/not-a-store" 2>&1)
  DBVPK=$(echo "$DBV" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "--db as a --title value is kept" "$("$CLI" --db "$DB" show $DBVPK --json | jq_ 'd["title"]')" "--db"
  ok "--db after the command still selects" "$("$CLI" show $DBVPK --db "$DB" --json | jq_ 'd["text"]')" "$SB/not-a-store"
  ok "real link still flattened"      "$(printf '[real](https://x.com)' | "$CLI" render --plain)" 'real (https://x.com)'
  TOOUT=$("$CLI" --db "$DB" write --markdown --title 'Summary check' 2>&1)
  ok "title-only summary not empty"   "$(printf '%s' "$TOOUT" | grep -c 'empty')" "0"
  ok "backslash before non-escapable" "$(printf 'C:\\Users\\omar' | "$CLI" render --plain)" 'C:\Users\omar'
  ok "unterminated code stays literal" "$(printf 'a `**x** b' | "$CLI" render --plain)" 'a `**x** b'
  ok "unterminated code not bolded"   "$(printf 'a `**x** b' | "$CLI" render | grep -c 'Bold')" "0"
  TRI=$(printf '***both***' | "$CLI" render)
  ok "triple emphasis is bold"        "$(printf '%s' "$TRI" | grep -c 'Bold')" "1"
  ok "triple emphasis is italic"      "$(printf '%s' "$TRI" | grep -c 'Italic')" "1"
  ok "escapes verbatim in code"       "$(printf 'a `\\*x\\*` b' | "$CLI" render --plain)" "a \`\\*x\\*\` b"
  ok "escapes applied outside code"   "$(printf 'a \\*x\\* b' | "$CLI" render --plain)" "a *x* b"
  PUA=$(python3 -c 'import sys;sys.stdout.write("a\ue000b")')
  ok "private-use scalar survives"    "$(printf '%s' "$PUA" | "$CLI" render --plain)" "$PUA"
  "$CLI" --db "$DB" write --markdown --title '   ' >/dev/null 2>&1
  ok "blank title rejected"           "$?" "1"
  ok "title keeps rule-like text"     "$(printf -- '---' | "$CLI" render --inline)" "---"
  ok "title de-escapes"               "$(printf 'Day 9 \\- N' | "$CLI" render --inline)" "Day 9 - N"
  # Whether an RTF round trip keeps generated list markers differs by macOS
  # release, so assert the invariant fix-text relies on -- that a stored entry
  # reads back exactly as `render --plain` says it will -- not a literal.
  LSRC=$(printf -- '- alpha\n- beta')
  LWOUT=$(printf '%s' "$LSRC" | "$CLI" --db "$DB" write --markdown 2>&1)
  LWPK=$(echo "$LWOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "stored list text matches render" "$("$CLI" --db "$DB" show $LWPK --json | jq_ 'd["text"]')" "$(printf '%s' "$LSRC" | "$CLI" render --plain)"
  LWTEXT=$("$CLI" --db "$DB" show $LWPK --json | jq_ 'd["text"]')
  ok "list length matches visible"    "$(sqlite3 "$DB" "select ZTEXTLENGTH from ZJOURNALENTRYMO where Z_PK=$LWPK;")" "$(printf '%s' "$LWTEXT" | wc -m | tr -d ' ')"
  TOUT=$("$CLI" --db "$DB" write --markdown --title 'Only a title' 2>&1)
  TPK=$(echo "$TOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "title-only entry allowed"       "$("$CLI" --db "$DB" show $TPK --json | jq_ 'd["title"]')" "Only a title"
  ok "title-only stored list-title"   "$("$CLI" --db "$DB" write --markdown --title '1. first' 2>&1 | grep -c 'Created entry')" "1"
  ok "inline code not bolded"         "$(printf 'Use `**lit**` here' | "$CLI" render | grep -c 'Bold')" "0"
  ok "code span does not block bold"  "$(printf '`x` and **b**' | "$CLI" render | grep -c 'Bold')" "1"

  UOUT=$(printf 'foo__bar__baz and __real bold__' | "$CLI" --db "$DB" write --markdown 2>&1)
  UPK=$(echo "$UOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "intraword __ stays literal" "$("$CLI" --db "$DB" show $UPK --json | jq_ 'd["text"]')" "foo__bar__baz and real bold"

  CRLF=$(printf 'first\r\nsecond\r\nthird')
  COUT=$(printf '%s' "$CRLF" | "$CLI" --db "$DB" write --markdown 2>&1)
  CPK=$(echo "$COUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "CRLF does not double-space" "$("$CLI" --db "$DB" show $CPK --json | jq_ 'd["text"]' | grep -c '^$')" "0"
  ok "CRLF keeps all lines"       "$("$CLI" --db "$DB" show $CPK --json | jq_ 'd["text"]' | grep -c .)" "3"

  PLAINOUT=$("$CLI" --db "$DB" write --body '## not markdown mode' 2>&1)
  PLAINPK=$(echo "$PLAINOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "plain mode leaves text alone" "$("$CLI" --db "$DB" show $PLAINPK --json | jq_ 'd["text"]')" "## not markdown mode"

else
  echo "T17 markdown rendering (skipped: this CLI has no --markdown)"
fi

echo "T18 data safety"
ent_count(){ sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO;"; }
SOUT=$("$CLI" --db "$DB" write --body "Keep this text." 2>&1)
SPK=$(echo "$SOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
# An unreadable --body-file must refuse the edit, not clear the body.
"$CLI" --db "$DB" edit $SPK --body-file "$SB/no-such-file.txt" >/dev/null 2>&1
ok "missing --body-file refused" "$?" "1"
ok "missing --body-file keeps text" "$("$CLI" --db "$DB" show $SPK --json | jq_ 'd["text"]')" "Keep this text."
printf '\xff\xfe bad bytes' > "$SB/bad.txt"
"$CLI" --db "$DB" edit $SPK --body-file "$SB/bad.txt" >/dev/null 2>&1
ok "non-UTF-8 --body-file refused" "$?" "1"
ok "non-UTF-8 --body-file keeps text" "$("$CLI" --db "$DB" show $SPK --json | jq_ 'd["text"]')" "Keep this text."

# Backups: one folder per write, a usable store in each, and fail closed.
BK="$SB/backups"
JOURNAL_BACKUP_DIR="$BK" "$CLI" --db "$DB" write --body "backup one" >/dev/null 2>&1
JOURNAL_BACKUP_DIR="$BK" "$CLI" --db "$DB" write --body "backup two" >/dev/null 2>&1
ok "each write gets its own backup" "$(find "$BK" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "2"
ok "backups are valid stores" "$(for f in "$BK"/*/moments.sqlite; do sqlite3 "$f" 'PRAGMA integrity_check;'; done | sort -u)" "ok"
: > "$SB/not-a-dir"
N0=$(ent_count)
JOURNAL_BACKUP_DIR="$SB/not-a-dir" "$CLI" --db "$DB" write --body "no backup, no write" >/dev/null 2>&1
ok "failed backup refuses the write" "$?" "1"
ok "failed backup wrote nothing" "$(ent_count)" "$N0"

# Removed media moves into that write's backup instead of being deleted.
QOUT=$("$CLI" --db "$DB" write --body "Recoverable pic." --media "$IMG" 2>&1)
QPK=$(echo "$QOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
QUUID=$("$CLI" --db "$DB" show $QPK --json | jq_ 'd["uuid"]')
QAID=$("$CLI" --db "$DB" show $QPK --json | jq_ '[a for a in d["assets"] if a["type"]=="photo"][0]["id"]')
# A failed edit must not delete files whose rows roll back.
"$CLI" --db "$DB" edit $QPK --remove-media $QAID --add-journal "No Such Journal $$" >/dev/null 2>&1
ok "failed edit refused" "$?" "1"
ok "failed edit keeps the asset row" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$QPK;")" "1"
ok "failed edit keeps the files" "$(find "$ATT/$QUUID" -type f 2>/dev/null | wc -l | tr -d ' ')" "1"
BK2="$SB/backups2"
JOURNAL_BACKUP_DIR="$BK2" "$CLI" --db "$DB" edit $QPK --remove-media $QAID >/dev/null 2>&1
ok "removed media leaves the store" "$(find "$ATT/$QUUID" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
ok "removed media is in the backup" "$(find "$BK2" -path "*/Attachments/$QUUID/*" -type f | wc -l | tr -d ' ')" "1"
HOUT=$("$CLI" --db "$DB" write --body "Hard delete me." --media "$IMG" 2>&1)
HPK=$(echo "$HOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
HUUID=$("$CLI" --db "$DB" show $HPK --json | jq_ 'd["uuid"]')
BK3="$SB/backups3"
JOURNAL_BACKUP_DIR="$BK3" "$CLI" --db "$DB" delete $HPK --hard >/dev/null 2>&1
ok "hard delete keeps media in the backup" "$(find "$BK3" -path "*/Attachments/$HUUID/*" -type f | wc -l | tr -d ' ')" "1"

# A write whose attachment copy fails commits nothing and leaves no folders.
SB2=$(mktemp -d /tmp/journal-sandbox2.XXXXXX)
DB2=$("$CLI" sandbox --dir "$SB2" --from "$DB")
ok "sandbox copy is a valid store" "$(sqlite3 "$DB2" 'PRAGMA integrity_check;')" "ok"
N2A=$(sqlite3 "$DB2" "select count(*) from ZJOURNALENTRYMO;")
"$CLI" sandbox --dir "$SB2" --from "$DB2" >/dev/null 2>&1
ok "sandbox onto its own source refused" "$?" "1"
ok "sandbox onto its own source keeps it" "$(sqlite3 "$DB2" "select count(*) from ZJOURNALENTRYMO;")" "$N2A"
"$CLI" sandbox --dir "$SB2" --from "$SB2/no-such.sqlite" >/dev/null 2>&1
ok "failed sandbox copy keeps the old store" "$(sqlite3 "$DB2" "select count(*) from ZJOURNALENTRYMO;")" "$N2A"
trash "$SB2/Attachments" 2>/dev/null || mv "$SB2/Attachments" "$SB2/Attachments.old"
: > "$SB2/Attachments"
N2=$(sqlite3 "$DB2" "select count(*) from ZJOURNALENTRYMO;")
"$CLI" --db "$DB2" write --body "copy fails" --media "$IMG" >/dev/null 2>&1
ok "attachment failure refuses the write" "$?" "1"
ok "attachment failure wrote nothing" "$(sqlite3 "$DB2" "select count(*) from ZJOURNALENTRYMO;")" "$N2"
trash "$SB2" 2>/dev/null
DIRS0=$(find "$ATT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
N3=$(ent_count)
"$CLI" --db "$DB" write --body "aborted" --media "$IMG" --journal "No Such Journal $$" >/dev/null 2>&1
ok "aborted write refused" "$?" "1"
ok "aborted write wrote nothing" "$(ent_count)" "$N3"
ok "aborted write leaves no folders" "$(find "$ATT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "$DIRS0"

echo "T19 reads and export"
# `--` ends the options, so a query can be a literal "--db".
DOUT=$("$CLI" --db "$DB" write --body "flag text --db in a body" 2>&1)
DPK=$(echo "$DOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "search -- --db finds the text" "$("$CLI" --db "$DB" search --json -- --db | jq_ '[e["id"] for e in d].count('"$DPK"')')" "1"

# Attachment-only entries are entries: export used to drop them.
AOUT=$("$CLI" --db "$DB" write --media "$IMG" 2>&1)
APK=$(echo "$AOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
EXP2="$SB/exp2"; "$CLI" --db "$DB" export --dir "$EXP2" >/dev/null 2>&1
ok "export keeps an attachment-only entry (md)" "$(entryfiles "$EXP2" "$APK" | wc -l | tr -d ' ')" "1"
EXP3="$SB/exp3"; "$CLI" --db "$DB" export --dir "$EXP3" --format json >/dev/null 2>&1
ok "export keeps an attachment-only entry (json)" "$(jq_ '[e["id"] for e in d].count('"$APK"')' < "$EXP3/journal.json")" "1"

# Location names are YAML-escaped, like titles.
NASTY='Joe'"'"'s "Bar" \ Grill'
YOUT=$("$CLI" --db "$DB" write --body "Quoted place." --lat 47.6 --lon -122.3 --place "$NASTY" 2>&1)
YPK=$(echo "$YOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
EXP4="$SB/exp4"; "$CLI" --db "$DB" export --dir "$EXP4" >/dev/null 2>&1
YFILE=$(entryfiles "$EXP4" "$YPK")
ok "location name round-trips through YAML" "$(python3 -c '
import json,sys
for line in open(sys.argv[1]):
    if line.startswith("  - name: "): print(json.loads(line[len("  - name: "):])); break
' "$YFILE")" "$NASTY"

# Export failures are errors, not "Wrote N entries".
: > "$SB/export-target-is-a-file"
"$CLI" --db "$DB" export --dir "$SB/export-target-is-a-file" >/dev/null 2>&1
ok "export to a file path fails (md)" "$?" "1"
"$CLI" --db "$DB" export --dir "$SB/export-target-is-a-file" --format json >/dev/null 2>&1
ok "export to a file path fails (json)" "$?" "1"

# A query that fails while stepping is an error, not an empty result.
SB3=$(mktemp -d /tmp/journal-sandbox3.XXXXXX)
DB3=$("$CLI" sandbox --dir "$SB3" --from "$DB")
sqlite3 "$DB3" "alter table ZJOURNALENTRYMO rename to ZREAL;
  create view ZJOURNALENTRYMO as select Z_PK, ZID, abs(-9223372036854775807-1) as ZENTRYDATE,
    ZTEXTLENGTH, ZFLAGGED, ZISDRAFT, ZISUPLOADEDTOCLOUD, ZTITLE, ZTEXT, ZISFULLYREMOVED,
    ZRECENTLYDELETED from ZREAL;"
"$CLI" --db "$DB3" list --json >/dev/null 2>&1
ok "step error fails the read" "$?" "1"
trash "$SB3" 2>/dev/null

# --photos-link needs the size to match, even for a single filename hit.
PHDB="$SB/Photos.sqlite"
cp "$IMG" "$SB/IMG_0001.png"
SIZE=$(stat -f %z "$SB/IMG_0001.png")
sqlite3 "$PHDB" "create table ZASSET (Z_PK integer primary key, ZUUID text);
  create table ZADDITIONALASSETATTRIBUTES (Z_PK integer primary key, ZASSET integer,
    ZORIGINALFILENAME text, ZORIGINALFILESIZE integer);
  insert into ZASSET values (1, '11111111-2222-3333-4444-555555555555');
  insert into ZADDITIONALASSETATTRIBUTES values (1, 1, 'IMG_0001.png', $((SIZE + 1)));"
POUT=$(JOURNAL_PHOTOS_DB="$PHDB" "$CLI" --db "$DB" write --body "Not that photo." --media "$SB/IMG_0001.png" --photos-link 2>&1)
PPK=$(echo "$POUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "different-sized namesake is not linked" "$(sqlite3 "$DB" "select max(instr(coalesce(ZASSETMETADATA,''),'11111111-2222-3333-4444-555555555555')>0) from ZJOURNALENTRYASSETMO where ZENTRY=$PPK;")" "0"
sqlite3 "$PHDB" "update ZADDITIONALASSETATTRIBUTES set ZORIGINALFILESIZE=$SIZE;"
POUT=$(JOURNAL_PHOTOS_DB="$PHDB" "$CLI" --db "$DB" write --body "That photo." --media "$SB/IMG_0001.png" --photos-link 2>&1)
PPK=$(echo "$POUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "same-sized namesake is linked" "$(sqlite3 "$DB" "select max(instr(coalesce(ZASSETMETADATA,''),'11111111-2222-3333-4444-555555555555')>0) from ZJOURNALENTRYASSETMO where ZENTRY=$PPK;")" "1"

echo "T20 content survives"
# An animated GIF over the resize limit is stored unchanged: thumbnailing
# would keep frame 0 only.
GIF="$SB/anim.gif"
python3 "$ROOT/tests/make-gif.py" "$GIF"
GOUT=$("$CLI" --db "$DB" write --body "Animated." --media "$GIF" 2>&1)
GPK=$(echo "$GOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
GSTORED=$("$CLI" --db "$DB" show $GPK --json | jq_ '[f["path"] for a in d["assets"] for f in a["files"]][0]')
ok "animated GIF stored unchanged" "$(cmp -s "$GIF" "$GSTORED" && echo same || echo changed)" "same"
# Embedded NUL in a text column survives a read.
sqlite3 "$DB" "update ZJOURNALENTRYASSETFILEATTACHMENTMO set ZFILEPATH = ZFILEPATH || char(0) || 'tail' where ZASSET in (select Z_PK from ZJOURNALENTRYASSETMO where ZENTRY=$GPK);"
ok "embedded NUL survives a read" "$("$CLI" --db "$DB" show $GPK --json | jq_ '[f["path"] for a in d["assets"] for f in a["files"]][0].endswith(chr(0)+"tail")')" "True"

echo "T21 refusals, exports and backups"
# --dry-run runs the same refusals as the real edit.
DRY=$("$CLI" --db "$DB" write --body "dry target" 2>&1)
DPK2=$(echo "$DRY" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
"$CLI" --db "$DB" edit $DPK2 --date not-a-date --dry-run >/dev/null 2>&1
ok "dry-run rejects a bad --date" "$?" "1"
"$CLI" --db "$DB" edit $DPK2 --add-journal "No Such Journal $$" --dry-run >/dev/null 2>&1
ok "dry-run rejects an unknown journal" "$?" "1"
"$CLI" --db "$DB" edit $DPK2 --remove-media 999999 --dry-run >/dev/null 2>&1
ok "dry-run rejects an unknown asset" "$?" "1"
"$CLI" --db "$DB" edit $DPK2 --add-link not-a-url --dry-run >/dev/null 2>&1
ok "dry-run rejects a bad link" "$?" "1"
printf 'text' > "$SB/notes.txt"
"$CLI" --db "$DB" edit $DPK2 --add-media "$SB/notes.txt" --dry-run >/dev/null 2>&1
ok "dry-run rejects an unsupported media file" "$?" "1"
"$CLI" --db "$DB" write --body x --link not-a-url --dry-run >/dev/null 2>&1
ok "write dry-run rejects a bad link" "$?" "1"
sqlite3 "$DB" "update ZJOURNALENTRYMO set ZMERGEABLEATTRIBUTES=x'6372647407000000' where Z_PK=$DPK2;"
"$CLI" --db "$DB" edit $DPK2 --body "x" --dry-run >/dev/null 2>&1
ok "dry-run rejects a text edit on a CRDT entry" "$?" "1"
"$CLI" --db "$DB" edit $DPK2 --journal "Test Journal" --dry-run >/dev/null 2>&1
ok "dry-run rejects a journal move on a CRDT entry" "$?" "1"
sqlite3 "$DB" "update ZJOURNALENTRYMO set ZMERGEABLEATTRIBUTES=NULL where Z_PK=$DPK2;"

# A malformed media id refuses the whole edit.
MM0=$(store_state)
"$CLI" --db "$DB" edit $DPK2 --bookmark --remove-media abc >/dev/null 2>&1
ok "malformed --remove-media id refused" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"
ok "malformed id applied nothing" "$(store_state)" "$MM0"
ok "malformed id left the bookmark alone" "$(sqlite3 "$DB" "select coalesce(ZFLAGGED,0) from ZJOURNALENTRYMO where Z_PK=$DPK2;")" "0"

# Backups are private to their owner.
BKP="$SB/backups-private"
JOURNAL_BACKUP_DIR="$BKP" "$CLI" --db "$DB" edit $DPK2 --bookmark >/dev/null 2>&1
BKDIR=$(find "$BKP" -mindepth 1 -maxdepth 1 -type d | head -1)
ok "backup folder is owner-only" "$(stat -f %Lp "$BKDIR")" "700"
ok "backup store is owner-only" "$(stat -f %Lp "$BKDIR/moments.sqlite")" "600"

# A read that refuses still removes its temp snapshot.
# The dry-run's unknown-journal refusal fires inside the snapshot. Count in
# the real temp folder: NSTemporaryDirectory() ignores an overridden TMPDIR.
TDIR="${TMPDIR:-/tmp}"
SNAP0=$(find "$TDIR" -mindepth 1 -maxdepth 1 -name 'journal-cli.*' 2>/dev/null | wc -l | tr -d ' ')
"$CLI" --db "$DB" edit $DPK2 --add-journal "No Such Journal $$" --dry-run >/dev/null 2>&1
ok "refused read leaves no snapshot" "$(find "$TDIR" -mindepth 1 -maxdepth 1 -name 'journal-cli.*' 2>/dev/null | wc -l | tr -d ' ')" "$SNAP0"

# Markdown export: link-only entries keep their link, and attachment paths
# with spaces and parentheses stay valid link destinations.
KOUT=$("$CLI" --db "$DB" write --link 'https://example.org/page?q=cats&n=2#top%20x' --link-title "Example (page)" 2>&1)
KPK=$(echo "$KOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
SBX=$(mktemp -d "/tmp/journal sandbox &copy; (x).XXXXXX")
DBX=$("$CLI" sandbox --dir "$SBX" --from "$DB")
XOUT=$("$CLI" --db "$DBX" write --body "Spaced path." --media "$IMG" 2>&1)
XPK=$(echo "$XOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
EXX="$SBX/exp"; "$CLI" --db "$DBX" export --dir "$EXX" >/dev/null 2>&1
ok "link-only entry exports its link, query and fragment intact" "$(entryfiles "$EXX" "$KPK" | while IFS= read -r f; do cat "$f"; done | grep -cF 'Example (page)](<https://example.org/page?q=cats\&n=2#top%20x>)')" "1"
# The Core Data epoch (ZENTRYDATE 0) is a real date: show and list agree.
sqlite3 "$DB" "update ZJOURNALENTRYMO set ZENTRYDATE=0 where Z_PK=$KPK;"
ok "epoch date shows" "$("$CLI" --db "$DB" show $KPK --json | jq_ 'd["date"]')" "$("$CLI" --db "$DB" list --json --include-empty --limit 100000 | jq_ '[e["date"] for e in d if e["id"]=='"$KPK"'][0]')"
ok "spaced attachment path is a valid destination" "$(python3 -c '
import glob,os,re,sys
hits=[]
for f in glob.glob(sys.argv[1]+"/*-"+sys.argv[2]+".md")+glob.glob(sys.argv[1]+"/*-"+sys.argv[2]+"-*.md"):
    for m in re.finditer(r"!\[[^\]]*\]\(<((?:[^<>\\]|\\.)*)>\)", open(f).read()):
        hits.append(os.path.exists(re.sub(r"\\(.)", r"\1", m.group(1))))
print(bool(hits) and all(hits))' "$EXX" "$XPK")" "True"
ok "& in a path cannot start an entity" "$(python3 -c '
import glob,re,sys
f=(glob.glob(sys.argv[1]+"/*-"+sys.argv[2]+".md")+glob.glob(sys.argv[1]+"/*-"+sys.argv[2]+"-*.md"))[0]
links=[l for l in open(f) if l.startswith("![")]
print(bool(links) and all("\\&copy;" in l and not re.search(r"(?<!\\)&", l) for l in links))' "$EXX" "$XPK")" "True"
trash "$SBX" 2>/dev/null

# Line breaks in an attachment path (LF, CR and CRLF; Swift treats CRLF as
# one character) are percent-encoded, and the link decodes to the real file.
SBN=$(mktemp -d "/tmp/journal-nl.XXXXXX")/$(printf 'a\nb\rc\r\nd%%20e#f?g')
mkdir -p "$SBN"
DBN=$("$CLI" sandbox --dir "$SBN" --from "$DB")
NOUT=$("$CLI" --db "$DBN" write --body "Line breaks." --media "$IMG" 2>&1)
NPK=$(echo "$NOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
EXN="$(dirname "$SBN")/exp"; "$CLI" --db "$DBN" export --dir "$EXN" >/dev/null 2>&1
ok "line breaks, %, # and ? in a path stay one valid link" "$(python3 -c '
import glob,os,re,sys
f=(glob.glob(sys.argv[1]+"/*-"+sys.argv[2]+".md")+glob.glob(sys.argv[1]+"/*-"+sys.argv[2]+"-*.md"))[0]
links=[m.group(1) for m in re.finditer(r"!\[[^\]\n]*\]\(<([^\n>]*(?:\\>[^\n>]*)*)>\)", open(f, newline="").read())]
def dec(d):
    from urllib.parse import unquote
    return unquote(re.sub(r"\\(.)", r"\1", d))
print(bool(links) and all(("%0A" in l and "%0D" in l) and os.path.exists(dec(l)) for l in links))' "$EXN" "$NPK")" "True"
trash "$(dirname "$SBN")" 2>/dev/null

echo "T22 reads, ordering and locking"
# Journal's built-in tips are not entries.
TOUT=$("$CLI" --db "$DB" write --body "a tip" 2>&1)
TPK=$(echo "$TOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
sqlite3 "$DB" "update ZJOURNALENTRYMO set ZISTIP=1 where Z_PK=$TPK;"
ok "tip rows are not listed" "$("$CLI" --db "$DB" list --json --include-empty --limit 100000 | jq_ '[e["id"] for e in d].count('"$TPK"')')" "0"

# Coordinates export as numbers.
COUT=$("$CLI" --db "$DB" write --body "coords" --lat 47.6 --lon -122.3 --place P 2>&1)
CPK2=$(echo "$COUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
EXC="$SB/exp-coords"; "$CLI" --db "$DB" export --dir "$EXC" >/dev/null 2>&1
ok "exported coordinates are numeric YAML" "$(entryfiles "$EXC" "$CPK2" | while IFS= read -r f; do grep -E '^    (lat|lon): ' "$f"; done | tr '\n' ' ')" "    lat: 47.6     lon: -122.3 "

# Assets read in Journal's saved order; removed ones drop out, hidden ones are flagged.
OOUT=$("$CLI" --db "$DB" write --body "order" --media "$IMG" "$MOV" 2>&1)
OPK=$(echo "$OOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
FIRST=$("$CLI" --db "$DB" show $OPK --json | jq_ 'd["assets"][0]["type"]')
python3 - "$DB" "$OPK" <<'PYORD'
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); pk=int(sys.argv[2])
o=json.loads(c.execute("select ZASSETORDERING from ZJOURNALENTRYMO where Z_PK=?",(pk,)).fetchone()[0])
c.execute("update ZJOURNALENTRYMO set ZASSETORDERING=? where Z_PK=?",(json.dumps([o[2],0,o[0],1]).encode(),pk)); c.commit()
PYORD
ok "assets follow the saved ordering" "$("$CLI" --db "$DB" show $OPK --json | jq_ 'd["assets"][0]["type"]!="'"$FIRST"'"')" "True"
RAID=$("$CLI" --db "$DB" show $OPK --json | jq_ 'd["assets"][0]["id"]')
sqlite3 "$DB" "update ZJOURNALENTRYASSETMO set ZISFULLYREMOVED=1 where Z_PK=$RAID;"
ok "removed assets are not read" "$("$CLI" --db "$DB" show $OPK --json | jq_ 'len(d["assets"])')" "1"
HAID=$("$CLI" --db "$DB" show $OPK --json | jq_ 'd["assets"][0]["id"]')
sqlite3 "$DB" "update ZJOURNALENTRYASSETMO set ZISHIDDEN=1 where Z_PK=$HAID;"
ok "hidden assets are flagged" "$("$CLI" --db "$DB" show $OPK --json | jq_ 'd["assets"][0].get("hidden")')" "True"

# write --dry-run resolves journals; URL schemes are case-insensitive.
"$CLI" --db "$DB" write --body x --journal "No Such Journal $$" --dry-run >/dev/null 2>&1
ok "write dry-run rejects an unknown journal" "$?" "1"
"$CLI" --db "$DB" write --body x --link "HTTPS://Example.org/page" --dry-run >/dev/null 2>&1
ok "uppercase URL scheme accepted" "$?" "0"

# One writer per store: a held write lock makes the next write wait, then go.
LOCKF=$(python3 -c 'import os,sys,tempfile;st=os.stat(sys.argv[1]);print(os.path.join(tempfile.gettempdir(),f"journal-cli-write-{st.st_dev}-{st.st_ino}.lock"))' "$DB")
python3 - "$LOCKF" <<'PYLOCK' &
import fcntl,os,sys,time
fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600); fcntl.flock(fd,fcntl.LOCK_EX)
open(sys.argv[1]+".held","w").close(); time.sleep(3)
PYLOCK
until [ -f "$LOCKF.held" ]; do sleep 0.1; done
WOUT=$("$CLI" --db "$DB" write --body "after the lock" 2>&1); WRC=$?
wait; trash "$LOCKF.held" 2>/dev/null
ok "a held write lock makes the write wait" "$(echo "$WOUT" | grep -c 'waiting for another journal-cli write')" "1"
ok "the waiting write then succeeds" "$WRC" "0"

echo "T8 integrity"
ok "integrity_check" "$(sqlite3 "$DB" 'PRAGMA integrity_check;' | head -1)" "ok"
SEEDCOUNT=$(sqlite3 "${JOURNAL_SEED:-$DB}" 'select count(*) from ZJOURNALENTRYMO;' 2>/dev/null)
if [ -n "${JOURNAL_SEED:-}" ]; then
  ok "seed store untouched" "$SEEDCOUNT" "$BEFORE"
fi

trash "$SB" 2>/dev/null
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
