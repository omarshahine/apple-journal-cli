#!/usr/bin/env bash
# Sandbox write tests. Never touches the real Journal store.
set -uo pipefail
# JOURNAL_CLI overrides which binary is under test. Default: the Swift release
# build if present, else the Python reference implementation.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${JOURNAL_CLI:-}" ]; then CLI="$JOURNAL_CLI"
elif [ -x "$ROOT/swift/.build/release/journal-cli" ]; then CLI="$ROOT/swift/.build/release/journal-cli"
else CLI="$ROOT/reference/journal-cli.py"; fi
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
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
      else echo "  FAIL  $1 (want '$3', got '$2')"; fail=$((fail+1)); fi; }
jq_(){ python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

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

echo "T1 guards"
"$CLI" write --body x >/dev/null 2>&1; ok "refuses live without --live" "$?" "1"
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
ok "metadata version byte" "$(sqlite3 "$DB" "select hex(substr(ZASSETMETADATA,1,1)) from ZJOURNALENTRYASSETMO where ZENTRY=$LPK;")" "01"
ok "lat round-trips" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'round(d["assets"][0]["places"][0]["lat"],5)')" "47.62055"
ok "lon round-trips" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'round(d["assets"][0]["places"][0]["lon"],5)')" "-122.3493"
ok "place name" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'd["assets"][0]["places"][0]["name"]')" "Space Needle"
ok "city" "$("$CLI" --db "$DB" show $LPK --json | jq_ 'd["assets"][0]["places"][0]["city"]')" "Seattle"
ok "asset parented to entry" "$(sqlite3 "$DB" "select hex(a.ZPARENTID)=hex(e.ZID) from ZJOURNALENTRYASSETMO a join ZJOURNALENTRYMO e on e.Z_PK=a.ZENTRY where a.ZENTRY=$LPK;")" "1"

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
ok "location in frontmatter" "$(grep -l 'Space Needle' "$EXP"/*-"$LPK"*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
ok "export wrote files" "$([ "$(ls "$EXP" | wc -l | tr -d ' ')" -ge 3 ] && echo yes || echo no)" "yes"
ok "media linked for media entry" "$(grep -l '_resized' "$EXP"/*-"$MPK"*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
ok "media linked for combo entry" "$(grep -l '_resized' "$EXP"/*-"$BPK"*.md 2>/dev/null | wc -l | tr -d ' ')" "1"
ok "location scoped to its entry" "$(grep -l 'Space Needle' "$EXP"/*-"$LPK"*.md 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "T7 edit"
EOUT=$("$CLI" --db "$DB" write --body "Original body." --title "Original" 2>&1)
EPK=$(echo "$EOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
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
"$CLI" --db "$DB" edit $EPK --lat 51.5007 --lon -0.1246 --place "Big Ben" --city London >/dev/null 2>&1
ok "location added" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "1"
ok "location reads back" "$("$CLI" --db "$DB" show $EPK --json | jq_ '[p for a in d["assets"] for p in a.get("places",[])][0]["name"]')" "Big Ben"
"$CLI" --db "$DB" edit $EPK --lat 48.8584 --lon 2.2945 --place "Eiffel Tower" >/dev/null 2>&1
ok "location replaced not duplicated" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYASSETMO where ZENTRY=$EPK and ZASSETTYPE='multiPinMap';")" "1"
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
  ok "journals lists both" "$("$CLI" --db "$DB" journals --json | jq_ 'len(d)')" "$NJ"
  ok "name resolved from CRDT" "$("$CLI" --db "$DB" journals --json | jq_ '[j for j in d if j["pk"]=='$TJPK'][0]["name"]')" "Test Journal"
  JOUT=$("$CLI" --db "$DB" write --body "In the test journal." --journal "Test Journal" 2>&1)
  JPK=$(echo "$JOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "join row written" "$(sqlite3 "$DB" "select Z_6JOURNALS from Z_5JOURNALS where Z_5ENTRIES=$JPK;")" "$TJPK"
  ok "custom journal queued for sync" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "0"
  ok "custom journal version bumped" "$(sqlite3 "$DB" "select Z_OPT from ZJOURNALMO where Z_PK=$TJPK;")" "2"
  DOUT=$("$CLI" --db "$DB" write --body "In the default journal." 2>&1)
  DPK=$(echo "$DOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "default write has no join row" "$(sqlite3 "$DB" "select count(*) from Z_5JOURNALS where Z_5ENTRIES=$DPK;")" "0"
  sqlite3 "$DB" "update ZJOURNALMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$TJPK;"
  "$CLI" --db "$DB" edit $DPK --journal "Test Journal" >/dev/null 2>&1
  ok "edit moves into journal" "$(sqlite3 "$DB" "select Z_6JOURNALS from Z_5JOURNALS where Z_5ENTRIES=$DPK;")" "$TJPK"
  ok "move queues destination journal" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "0"
  sqlite3 "$DB" "update ZJOURNALMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$TJPK;"
  "$CLI" --db "$DB" edit $DPK --journal 1 >/dev/null 2>&1
  ok "edit moves back to default (join row dropped)" "$(sqlite3 "$DB" "select count(*) from Z_5JOURNALS where Z_5ENTRIES=$DPK;")" "0"
  ok "move queues source journal" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "0"
  sqlite3 "$DB" "update ZJOURNALMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$TJPK;"
  "$CLI" --db "$DB" sync-journals --dry-run >/dev/null 2>&1
  ok "sync-journals dry-run is read-only" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "1"
  "$CLI" --db "$DB" sync-journals >/dev/null 2>&1
  ok "sync-journals repairs existing memberships" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "0"
  "$CLI" --db "$DB" write --body x --journal "No Such Journal" >/dev/null 2>&1
  ok "unknown journal rejected" "$?" "1"
  sqlite3 "$DB" "update ZJOURNALMO set ZISUPLOADEDTOCLOUD=1 where Z_PK=$TJPK;"
  "$CLI" --db "$DB" delete $JPK --hard >/dev/null 2>&1
  ok "hard delete queues former journal" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALMO where Z_PK=$TJPK;")" "0"
  "$CLI" --db "$DB" delete $DPK --hard >/dev/null 2>&1
else
  echo "  SKIP  (seed has one journal)"
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
  PUA=$(python3 -c 'import sys;sys.stdout.write("a\ue000b")')
  ok "private-use scalar survives"    "$(printf '%s' "$PUA" | "$CLI" render --plain)" "$PUA"
  LLOUT=$(printf -- '- alpha\n- beta' | "$CLI" --db "$DB" write --markdown 2>&1)
  LLPK=$(echo "$LLOUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
  ok "list length matches visible"    "$(sqlite3 "$DB" "select ZTEXTLENGTH from ZJOURNALENTRYMO where Z_PK=$LLPK;")" "10"
  "$CLI" --db "$DB" write --markdown --title '   ' >/dev/null 2>&1
  ok "blank title rejected"           "$?" "1"
  ok "title keeps rule-like text"     "$(printf -- '---' | "$CLI" render --inline)" "---"
  ok "title de-escapes"               "$(printf 'Day 9 \\- N' | "$CLI" render --inline)" "Day 9 - N"
  ok "list plain omits markers"       "$(printf -- '- alpha\n- beta' | "$CLI" render --plain)" "alpha
beta"
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

echo "T8 integrity"
ok "integrity_check" "$(sqlite3 "$DB" 'PRAGMA integrity_check;' | head -1)" "ok"
SEEDCOUNT=$(sqlite3 "${JOURNAL_SEED:-$DB}" 'select count(*) from ZJOURNALENTRYMO;' 2>/dev/null)
if [ -n "${JOURNAL_SEED:-}" ]; then
  ok "seed store untouched" "$SEEDCOUNT" "$BEFORE"
fi

trash "$SB" 2>/dev/null
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
