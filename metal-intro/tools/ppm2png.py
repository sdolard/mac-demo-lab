#!/usr/bin/env python3
"""Convert a binary PPM (P6) to PNG, no dependencies beyond the stdlib."""
import struct
import sys
import zlib


def read_ppm(path):
    with open(path, "rb") as f:
        tokens = []
        token = b""
        while len(tokens) < 4:
            c = f.read(1)
            if not c:
                break
            if c == b"#":
                f.readline()
                token = b""
                continue
            if c.isspace():
                if token:
                    tokens.append(token)
                    token = b""
                continue
            token += c
        if token:
            tokens.append(token)
        if tokens[:1] != [b"P6"]:
            raise SystemExit("not a binary PPM (P6) file")
        width, height, maxval = (int(t) for t in tokens[1:4])
        if maxval != 255:
            raise SystemExit("only 8-bit PPM files are supported")
        pixels = f.read(width * height * 3)
        if len(pixels) != width * height * 3:
            raise SystemExit("truncated PPM payload")
        return width, height, pixels


def chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload +
            struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def write_png(path, width, height, rgb):
    scanlines = b"".join(
        b"\x00" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height)
    )
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", ihdr) +
           chunk(b"IDAT", zlib.compress(scanlines, 9)) +
           chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main() -> None:
    width, height, rgb = read_ppm(sys.argv[1])
    write_png(sys.argv[2], width, height, rgb)


if __name__ == "__main__":
    main()
