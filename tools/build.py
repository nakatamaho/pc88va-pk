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

"""Build the PK disk (self-booting 2HD D88).

Disk layout: the IPL in sector 0, then the payload loaded to 2000:0000
(the offsets are also defined in src/game/pk.asm):

    0000h  game code (src/game/pk.asm), 16 KiB
    4000h  the patched Z80 program, 16 KiB
    8000h  tile rows (tools/gfx.py), 4 KiB
    9000h  colour lookup, 128 bytes
    9080h  PC-88VA palette, 32 bytes
    9100h  screen offset of each tile RAM byte, 2 KiB
    9900h  FM voices (tools/fmfit.py), 144 bytes
    9F00h  program version: 0 A, 1 B (tools/patches.py)
    A000h  sprite rows, 18 KiB

    python3 -I tools/build.py [--roms PATH] [--output PATH] [--debug-dump]
        [--key-diag] [--ssg]

--debug-dump copies tile and colour RAM, the WSG registers and the SSG values
to GVRAM offset 25800h every frame,
for inspection through vaeg's GVRAM capture. --key-diag shows the raw key
matrix (ports 00h-0Eh) in the left margin, for hardware checks. --ssg makes
the SSG square waves the default sound instead of FM (F10 switches).

The output contains the arcade program and must never be committed; the
default path, build/pk.d88, is ignored by git.
"""

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d88  # noqa: E402
import gfx  # noqa: E402
import patches  # noqa: E402
import fmfit  # noqa: E402

CODE_BYTES = 0x4000


def fm_voices(prom: bytes) -> bytes:
    """tools/fmfit.py's voices, cached in build/ by the wave PROM and the
    fitter's source (a fit takes some seconds on many cores)."""
    key = hashlib.sha256(prom + Path(fmfit.__file__).read_bytes()).hexdigest()[:16]
    cache = d88.REPO / "build" / f"fmvoices-{key}.bin"
    if cache.exists() and len(cache.read_bytes()) == fmfit.FM_VOICES_BYTES:
        return cache.read_bytes()
    voices = fmfit.fm_voices(prom)
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_bytes(voices)
    return voices


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--roms", type=Path, default=patches.DEFAULT_ZIP,
                        help="zip or directory with the ROM files (default: $PK_ROMS)")
    parser.add_argument("--output", type=Path, default=d88.REPO / "build/pk.d88")
    parser.add_argument("--debug-dump", action="store_true")
    parser.add_argument("--key-diag", action="store_true")
    parser.add_argument("--ssg", action="store_true")
    args = parser.parse_args()

    original = patches.load_program(args.roms)
    program = patches.apply(original)
    roms = gfx.load(args.roms)
    layout = [(0x4000, program),
              (0x8000, gfx.tile_rows(roms["tiles"])),
              (0x9000, gfx.lookup(roms["lookup"])),
              (0x9080, gfx.palette(roms["colours"])),
              (0x9100, gfx.tile_screen_offsets()),
              (0x9900, fm_voices(roms["waves"])),
              (0x9F00, bytes((0 if patches.version(original) == "A" else 1,))),
              (0xA000, gfx.sprite_rows(roms["sprites"]))]
    data = bytearray()
    for offset, part in layout:
        if len(data) + CODE_BYTES > offset:
            raise SystemExit(f"error: the payload overlaps at {offset:04X}h")
        data += bytes(offset - CODE_BYTES - len(data)) + part
    sectors = d88.build_boot_disk(d88.REPO / "src/game/pk.asm", data,
                                  args.output, "PK",
                                  (["DEBUG_DUMP"] if args.debug_dump else [])
                                  + (["KEY_DIAG"] if args.key_diag else [])
                                  + (["SOUND_SSG"] if args.ssg else []),
                                  code_bytes=CODE_BYTES)
    print(f"{args.output}: IPL, game code and the program with {len(patches.PATCHES)} "
          f"patches ({sectors} sectors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
