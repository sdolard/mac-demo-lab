#!/bin/sh
set -eu

cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required (Xcode Command Line Tools provide it)" >&2
    exit 1
fi

mkdir -p out
python3 tools/embed_shader.py src/shader.metal out/shader_source.h

xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wall -Wextra \
    -Isrc -Iout \
    -o out/demo \
    src/main.mm src/renderer.mm \
    -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore

echo "built out/demo ($(stat -f%z out/demo) bytes)"
