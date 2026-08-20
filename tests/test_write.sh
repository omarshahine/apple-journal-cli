#!/usr/bin/env bash
# Sandbox write tests. Never touches the real Journal store.
set -uo pipefail
CLI="$(cd "$(dirname "$0")/.." && pwd)/journal-cli"
SB=$(mktemp -d /tmp/journal-sandbox.XXXXXX)
DB=$("$CLI" sandbox --dir "$SB")
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
      else echo "  FAIL  $1 (want '$3', got '$2')"; fail=$((fail+1)); fi; }

BEFORE=$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO;")
MAX0=$(sqlite3 "$DB" "select Z_MAX from Z_PRIMARYKEY where Z_NAME='JournalEntryMO';")
echo "sandbox: $DB  ($BEFORE rows, Z_MAX=$MAX0)"

echo "T1 refuses live write without --live"
"$CLI" write --body x >/dev/null 2>&1; ok "exit nonzero" "$?" "1"

echo "T2 write into sandbox"
OUT=$("$CLI" --db "$DB" write --title "Test Title" --body "Hello from the test suite." --date 2026-08-20 2>&1)
NEWPK=$(echo "$OUT" | grep -oE 'entry [0-9]+' | grep -oE '[0-9]+')
ok "row added" "$(sqlite3 "$DB" 'select count(*) from ZJOURNALENTRYMO;')" "$((BEFORE+1))"
ok "Z_MAX bumped" "$(sqlite3 "$DB" "select Z_MAX from Z_PRIMARYKEY where Z_NAME='JournalEntryMO';")" "$((MAX0+1))"
ok "pk matches Z_MAX" "$NEWPK" "$((MAX0+1))"
ok "ZID is 16-byte blob" "$(sqlite3 "$DB" "select length(ZID) from ZJOURNALENTRYMO where Z_PK=$NEWPK;")" "16"
ok "marked unsynced" "$(sqlite3 "$DB" "select ZISUPLOADEDTOCLOUD from ZJOURNALENTRYMO where Z_PK=$NEWPK;")" "0"
ok "Z_ENT correct" "$(sqlite3 "$DB" "select Z_ENT from ZJOURNALENTRYMO where Z_PK=$NEWPK;")" "5"
ok "textlength" "$(sqlite3 "$DB" "select ZTEXTLENGTH from ZJOURNALENTRYMO where Z_PK=$NEWPK;")" "26"

echo "T3 round-trip read"
ok "title round-trips" "$("$CLI" --db "$DB" show $NEWPK --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["title"])')" "Test Title"
ok "body round-trips"  "$("$CLI" --db "$DB" show $NEWPK --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["text"])')" "Hello from the test suite."
ok "searchable" "$("$CLI" --db "$DB" search 'test suite' --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "1"

echo "T4 soft delete"
"$CLI" --db "$DB" delete $NEWPK >/dev/null 2>&1
ok "row still present" "$(sqlite3 "$DB" "select count(*) from ZJOURNALENTRYMO where Z_PK=$NEWPK;")" "1"
ok "flagged deleted" "$(sqlite3 "$DB" "select ZRECENTLYDELETED from ZJOURNALENTRYMO where Z_PK=$NEWPK;")" "1"
ok "hidden from list" "$("$CLI" --db "$DB" search 'test suite' --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "0"

echo "T5 hard delete"
"$CLI" --db "$DB" delete $NEWPK --hard >/dev/null 2>&1
ok "row gone" "$(sqlite3 "$DB" 'select count(*) from ZJOURNALENTRYMO;')" "$BEFORE"

echo "T6 integrity + live store untouched"
ok "integrity_check" "$(sqlite3 "$DB" 'PRAGMA integrity_check;' | head -1)" "ok"
LIVE=~/Library/Group\ Containers/group.com.apple.moments/Library/moments.sqlite
ok "live row count unchanged" "$(sqlite3 "file:$LIVE?mode=ro" 'select count(*) from ZJOURNALENTRYMO;' 2>/dev/null)" "$BEFORE"

trash "$SB" 2>/dev/null
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
