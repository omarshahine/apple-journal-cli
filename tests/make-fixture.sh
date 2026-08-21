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
# Retire any previous fixture instead of deleting it: `trash` is macOS 26+,
# and on older hosts moving it aside keeps the old copy recoverable.
if [ -e "$DB" ]; then
  if command -v trash >/dev/null 2>&1; then
    for f in "$DB" "$DB-wal" "$DB-shm"; do [ -e "$f" ] && trash "$f"; done
  else
    OLD="$DIR/superseded-$$"
    mkdir -p "$OLD"
    for f in "$DB" "$DB-wal" "$DB-shm"; do
      [ -e "$f" ] && mv "$f" "$OLD/"
    done
  fi
fi

sqlite3 "$DB" < "$HERE/fixture-schema.sql"

python3 "$HERE/seed-fixture.py" "$DB"

mkdir -p "$DIR/Attachments"
echo "$DB"
