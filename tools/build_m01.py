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

"""Build the M01 feasibility test disk (self-booting 2HD D88).

Disk layout: the IPL in sector 0, then M01TEST (32 KiB, loaded to
2000:0000) followed by the patched Z80 program (16 KiB, at 2000:8000).

    python3 -I tools/build_m01.py [--roms PATH] [--output PATH]

The output contains the arcade program and must never be committed; the
default path, build/m01test.d88, is ignored by git.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d88  # noqa: E402
import patches  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--roms", type=Path, default=patches.DEFAULT_ZIP,
                        help="zip or directory with the ROM files (default: $PK_ROMS)")
    parser.add_argument("--output", type=Path, default=d88.REPO / "build/m01test.d88")
    args = parser.parse_args()

    program = patches.apply(patches.load_program(args.roms))
    sectors = d88.build_boot_disk(d88.REPO / "src/m01/m01test.asm", program,
                                  args.output, "PACM01")
    print(f"{args.output}: IPL, M01TEST and the program with {len(patches.PATCHES)} patches "
          f"({sectors} sectors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
