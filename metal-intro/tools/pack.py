#!/usr/bin/env python3
"""Build a self-extracting file: shell launcher + gzipped Mach-O payload."""
import sys


def launcher(offset: int) -> bytes:
    return f'''#!/bin/sh
set -eu
tmp="${{TMPDIR:-/tmp}}/mac-demo-lab.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM
dd if="$0" bs=1 skip={offset} 2>/dev/null | gunzip > "$tmp/intro"
chmod +x "$tmp/intro"
"$tmp/intro" "$@"
exit 0
'''.encode()


def main() -> None:
    payload_path, output_path = sys.argv[1], sys.argv[2]
    with open(payload_path, "rb") as f:
        payload = f.read()

    offset = 0
    head = launcher(offset)
    for _ in range(16):
        head = launcher(offset)
        if len(head) == offset:
            break
        offset = len(head)
    else:
        raise SystemExit("launcher offset did not converge")

    with open(output_path, "wb") as f:
        f.write(head)
        f.write(payload)


if __name__ == "__main__":
    main()
