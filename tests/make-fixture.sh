#!/usr/bin/env bash
# Build a synthetic, empty moments.sqlite so the test suite can run on machines
# with no Journal library (CI). Schema only — contains zero personal data.
#
# Usage: tests/make-fixture.sh /path/to/dir   -> prints the fixture db path
set -euo pipefail
DIR="${1:?usage: make-fixture.sh DIR}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR"
DB="$DIR/moments.sqlite"
rm -f "$DB" 2>/dev/null || :

sqlite3 "$DB" < "$HERE/fixture-schema.sql"

python3 "$HERE/seed-fixture.py" "$DB"

mkdir -p "$DIR/Attachments"
echo "$DB"
