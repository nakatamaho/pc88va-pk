#!/usr/bin/env python3
# Copyright (c) 2026 Nakata Maho
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

"""Turn a vaeg GVRAM capture (debug script "capture ID gvram") into a PNG of
the 320x224 4-bit screen, with the game's palette.

vaeg shows only part of the 224-line 15.98 kHz picture in its window, so
the whole screen is checked from GVRAM instead.

    python3 -I tools/gvram_png.py CAPTURE.gvram.bin OUTPUT.png [--offset N]
        [--roms PATH] [--scale N]

--area selects the background (bg, tiles only) or display page 0, 1 or 2
(src/game/pk.asm: four 240-line areas from GVRAM 0, the picture at
line 8 of each). The image is drawn as on the screen, the top of the game
on the left; --rotate shows it upright.
"""

import argparse
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gfx  # noqa: E402
import patches  # noqa: E402

WIDTH, HEIGHT, LINE_BYTES = 320, 224, 160


def rgb(word: int) -> tuple[int, int, int]:
    g, r, b = (word >> 12) & 15, (word >> 6) & 15, (word >> 1) & 15
    return r * 17, g * 17, b * 17


def write_png(path: Path, width: int, height: int, rows: list[bytes]) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    raw = b"".join(b"\x00" + row for row in rows)
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--area", choices=["bg", "0", "1", "2"], default="bg")
    parser.add_argument("--roms", type=Path, default=patches.DEFAULT_ZIP,
                        help="zip or directory with the ROM files (default: $PK_ROMS)")
    parser.add_argument("--scale", type=int, default=2)
    parser.add_argument("--rotate", action="store_true", help="show the game upright")
    args = parser.parse_args()

    words = gfx.palette(gfx.load(args.roms)["colours"])
    colours = [rgb(words[i] | (words[i + 1] << 8)) for i in range(0, 32, 2)]
    dump = args.capture.read_bytes()
    offset = {"bg": 0, "0": 1, "1": 2, "2": 3}[args.area] * 240 * LINE_BYTES + 8 * LINE_BYTES
    pixels = [[0] * WIDTH for _ in range(HEIGHT)]
    for y in range(HEIGHT):
        line = dump[offset + y * LINE_BYTES:offset + (y + 1) * LINE_BYTES]
        for i, byte in enumerate(line):
            pixels[y][2 * i] = byte >> 4
            pixels[y][2 * i + 1] = byte & 15
    if args.rotate:   # upright: rotate the screen clockwise
        pixels = [[pixels[HEIGHT - 1 - x][y] for x in range(HEIGHT)] for y in range(WIDTH)]
    rows = []
    for line in pixels:
        row = b"".join(bytes(colours[p]) * args.scale for p in line)
        rows += [row] * args.scale
    write_png(args.output, len(pixels[0]) * args.scale, len(pixels) * args.scale, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
