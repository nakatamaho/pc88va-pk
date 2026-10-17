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

"""Graphics data for the PC-88VA build, converted from the arcade ROMs.

Everything here is derived from the arcade ROMs at build time and goes onto
the disk only; none of it is committed.

Tiles (the tile ROM) keep the arcade board's raster orientation, which is the
orientation of the PC-88VA picture (the top of the game on the left). The
decoding follows the board's tile layout as described by MAME's driver
for the board (tilelayout): 8x8 pixels, 2 bits per pixel,
16 bytes per tile; pixel x < 4 of row y is in byte 8 + y, x >= 4 in byte y;
within a byte, pixel j (0-3) has its high bit at bit 7 - j and its low bit
at bit 3 - j.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roms  # noqa: E402

TILE_ROWS_BYTES = 256 * 8 * 2       # 256 tiles, 8 rows, 8 pixels at 2 bits
SPRITE_ROW_BYTES = 9                # 4 bytes even-aligned, 5 bytes odd-aligned
SPRITE_ROWS_BYTES = 64 * 2 * 16 * SPRITE_ROW_BYTES
LOOKUP_BYTES = 128                  # 32 palettes x 4 colours
PALETTE_BYTES = 32                  # 16 PC-88VA palette words


def load(source: Path) -> dict[str, bytes]:
    """The graphics and sound ROMs by role (tools/roms.py)."""
    return roms.load(source, ("tiles", "sprites", "colours", "lookup", "waves"))


def _pixels(byte: int) -> list[int]:
    return [(((byte >> (7 - j)) & 1) << 1) | ((byte >> (3 - j)) & 1) for j in range(4)]


def tile_rows(rom: bytes) -> bytes:
    """Each tile row as two bytes, pixels 0-3 then 4-7, two bits per pixel,
    the leftmost pixel in the top bits."""
    out = bytearray()
    for tile in range(256):
        base = tile * 16
        for y in range(8):
            for pixels in (_pixels(rom[base + 8 + y]), _pixels(rom[base + y])):
                value = 0
                for p in pixels:
                    value = (value << 2) | p
                out.append(value)
    assert len(out) == TILE_ROWS_BYTES
    return bytes(out)


def lookup(prom: bytes) -> bytes:
    """Colour index (0-15) of each of the 4 colours of the 32 palettes."""
    return bytes(b & 0x0F for b in prom[:LOOKUP_BYTES])


def _level(value: int) -> int:
    return (value * 15 + 127) // 255


def palette(prom: bytes) -> bytes:
    """The 16 arcade colours as PC-88VA palette words (technical manual 4.6:
    G at bits 15-12, R at 9-6, B at 4-1; each component's unused low bits
    set when the component is not zero)."""
    out = bytearray()
    for c in prom[:16]:
        r = 0x21 * (c & 1) + 0x47 * ((c >> 1) & 1) + 0x97 * ((c >> 2) & 1)
        g = 0x21 * ((c >> 3) & 1) + 0x47 * ((c >> 4) & 1) + 0x97 * ((c >> 5) & 1)
        b = 0x51 * ((c >> 6) & 1) + 0xAE * ((c >> 7) & 1)
        r, g, b = _level(r), _level(g), _level(b)
        word = (g << 12) | ((3 if g else 0) << 10) | (r << 6) | ((1 if r else 0) << 5) \
            | (b << 1) | (1 if b else 0)
        out += word.to_bytes(2, "little")
    assert len(out) == PALETTE_BYTES
    return bytes(out)


def tile_position(offset: int) -> tuple[int, int] | None:
    """(column, row) on the 36x28 tile screen of tile RAM byte OFFSET, in
    the board's raster orientation, or None for the 16 bytes not shown.
    This is MAME's tilemap scan for the board, inverted."""
    if 0x040 <= offset < 0x3C0:
        return offset % 32 + 2, offset // 32 - 2
    for base, column in ((0x3C2, 0), (0x3E2, 1), (0x002, 34), (0x022, 35)):
        if base <= offset < base + 28:
            return column, offset - base
    return None


def tile_screen_offsets() -> bytes:
    """For each tile RAM byte, the GVRAM byte offset of the tile's top-left
    pixel (320x224, 160 bytes a line, the 288-dot picture at dot 16), or
    FFFFh for a byte not shown."""
    out = bytearray()
    for offset in range(1024):
        position = tile_position(offset)
        value = 0xFFFF
        if position is not None:
            column, row = position
            value = row * 8 * 160 + (16 + column * 8) // 2
        out += value.to_bytes(2, "little")
    return bytes(out)


def _pack(pixels: list[int]) -> bytes:
    """Pixels, 2 bits each, 4 to a byte, the leftmost in the top bits."""
    out = bytearray()
    for i in range(0, len(pixels), 4):
        value = 0
        for p in pixels[i:i + 4]:
            value = (value << 2) | p
        out.append(value)
    return bytes(out)


def sprite_pixels(rom: bytes, code: int) -> list[list[int]]:
    """16x16 pixels of sprite CODE (the sprite ROM), in the board's raster
    orientation, following MAME's spritelayout: pixels x 0-3, 4-7, 8-11 and
    12-15 of a row are in the bytes from 8, 16, 24 and 0; rows 0-7 add y,
    rows 8-15 add 32 + y - 8; within a byte as for tiles."""
    base = code * 64
    rows = []
    for y in range(16):
        row_offset = y if y < 8 else 32 + y - 8
        row = []
        for group in (8, 16, 24, 0):
            row += _pixels(rom[base + group + row_offset])
        rows.append(row)
    return rows


def sprite_rows(rom: bytes) -> bytes:
    """For each sprite code (64) and horizontal flip (0, 1), 16 rows of
    SPRITE_ROW_BYTES: the row's 16 pixels at 2 bits (4 bytes), then the
    same row one pixel to the right in 20 pixels (5 bytes), for drawing at
    an odd dot. Pixel value 0 is transparent in every sprite palette."""
    out = bytearray()
    for code in range(64):
        pixels = sprite_pixels(rom, code)
        for flip in (0, 1):
            for row in pixels:
                row = row[::-1] if flip else row
                out += _pack(row) + _pack([0] + row + [0, 0, 0])
    assert len(out) == SPRITE_ROWS_BYTES
    return bytes(out)
