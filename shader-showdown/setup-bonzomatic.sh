#!/bin/sh
set -eu

cd "$(dirname "$0")"

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required: brew install cmake" >&2
    exit 1
fi

mkdir -p vendor
if [ ! -d vendor/Bonzomatic ]; then
    git clone --depth 1 https://github.com/Gargaj/Bonzomatic vendor/Bonzomatic
fi

cd vendor/Bonzomatic
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(sysctl -n hw.logicalcpu)"

echo
echo "Built: $(pwd)/build/Bonzomatic.app"
