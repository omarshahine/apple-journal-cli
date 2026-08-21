#!/usr/bin/env bash
# Sandbox write tests. Never touches the real Journal store.
set -uo pipefail
CLI="$(cd "$(dirname "$0")/.." && pwd)/journal-cli"
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
ok "location in frontmatter" "$(grep -rl 'Space Needle' "$EXP" | wc -l | tr -d ' ')" "1"
ok "export wrote files" "$([ "$(ls "$EXP" | wc -l | tr -d ' ')" -gt 50 ] && echo yes || echo no)" "yes"
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

echo "T8 integrity"
ok "integrity_check" "$(sqlite3 "$DB" 'PRAGMA integrity_check;' | head -1)" "ok"
SEEDCOUNT=$(sqlite3 "${JOURNAL_SEED:-$DB}" 'select count(*) from ZJOURNALENTRYMO;' 2>/dev/null)
if [ -n "${JOURNAL_SEED:-}" ]; then
  ok "seed store untouched" "$SEEDCOUNT" "$BEFORE"
fi

trash "$SB" 2>/dev/null
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
