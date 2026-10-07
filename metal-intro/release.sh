#!/bin/sh
set -eu

cd "$(dirname "$0")"

BUDGET=65536

./build.sh

cp out/demo out/intro
strip -x out/intro
codesign --force -s - out/intro

BIN_SIZE=$(stat -f%z out/demo)
STRIPPED_SIZE=$(stat -f%z out/intro)

gzip -9 -c out/intro > out/intro.gz
GZ_SIZE=$(stat -f%z out/intro.gz)

python3 tools/pack.py out/intro.gz out/demo64k
chmod +x out/demo64k
FINAL_SIZE=$(stat -f%z out/demo64k)

PERCENT=$(awk "BEGIN { printf \"%.1f\", 100.0 * $FINAL_SIZE / $BUDGET }")

printf 'dev binary   %8d B\n' "$BIN_SIZE"
printf 'stripped     %8d B\n' "$STRIPPED_SIZE"
printf 'gzipped      %8d B\n' "$GZ_SIZE"
printf 'packed       %8d B  (%.1f%% of 64 KiB)\n' "$FINAL_SIZE" "$PERCENT"

if [ "$FINAL_SIZE" -gt "$BUDGET" ]; then
    echo "OVER BUDGET by $((FINAL_SIZE - BUDGET)) bytes" >&2
    exit 1
fi

echo "OK: out/demo64k"
