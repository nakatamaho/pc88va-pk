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

"""Build-time patches to the arcade game's Z80 program.

Every change to the program is listed here: in PATCHES with the original
byte, the new byte and the reason (apply() refuses a ROM whose bytes
differ), and the HALT patch below. tools/roms.py checks each ROM's SHA-1.
The ROM files themselves are never modified.

The power-on test at 3000h requires the even-address and the odd-address
bytes of every 4 KiB block to sum to 00h (mod 256). The last two bytes of
each block are the program's own compensation bytes; apply() adjusts them
so that the sums stay 00h after the patches.
"""

import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roms  # noqa: E402

DEFAULT_ZIP = roms.DEFAULT

# The arcade's input ports share addresses with write-only registers
# (5000h interrupt enable, 5040h-505Fh sound), which in the PC-88VA's plain
# RAM would overwrite the inputs. Each LD A,(nnnn) that reads an input is
# redirected from 50xxh to 51xxh, where the native code stores the inputs.
# Sites from tools/audit.py, "Direct reads of 5000h-50FFh".
INPUT_IN0 = 0x5100
INPUT_IN1 = 0x5140
INPUT_DSW = 0x5180
_INPUT_READS = {
    0x5000: [0x0272, 0x08CD, 0x1883, 0x18C5, 0x312A, 0x3197, 0x32B1, 0x32BD],
    0x5040: [0x01CC, 0x0631, 0x187D, 0x18BF, 0x271D, 0x312E, 0x314A, 0x31A5,
             0x3232, 0x323E, 0x3289, 0x3290, 0x329F, 0x32E2],
    0x5080: [0x26D0, 0x31DF, 0x31EA, 0x321C],
}

# (address, original bytes, new bytes, reason)
PATCHES = []
for port, sites in _INPUT_READS.items():
    for site in sites:
        # LD A,(nnnn) = 3A lo hi; the high byte at site + 2 goes 50h -> 51h.
        PATCHES.append((site + 2, b"\x50", b"\x51",
                        f"LD A,({port:04X}h) at {site:04X}h reads {port + 0x100:04X}h"))

# Startup waits for the first interrupt with EI; HALT at 2349h. The first
# interrupt enters the power-on test at 3000h and never returns, so the wait
# can spin instead, as NEC replaced HALT with JR $ in the VA's Debug 8800
# (vaeg docs/modernization/upd9002-upd70008-mode.md 4.5). The 4 bytes at
# 233Dh (an unused load and two NOPs where another version of the program
# writes the interrupt vector with OUT (0),A)
# make room: the 8 bytes from 2341h move to 233Dh and EI; JR $; NOP NOP NOP
# follow. 234Bh is a jump target and stays. The patch is applied by moving
# the program's own bytes, so that no ROM bytes need to be listed here.
HALT_MOVE = (0x2341, 0x233D, 8)
HALT_TAIL = (0x2345, bytes((0xFB, 0x18, 0xFE, 0x00, 0x00, 0x00)))

# The two versions of the program, by the SHA-1 of the 16 KiB.
VERSION_A = "fd1fa132f8ecee801c56b878d009bde55ff34ce2"
VERSION_B = "a70bb25d643a594f5bd0114f54d40fab0901ef3b"

# Version B uses interrupt mode 2: I = 3Fh, and OUT (0),A sets the vector
# byte, FAh at start-up (3FFAh -> the power-on test) and FCh from 3183h
# (3FFCh -> the interrupt routine). OUT would reach a PC-88VA port, so both
# become LD I,A (the vector is kept in I) and IM 2 becomes IM 1 (checked on
# the hardware in M01); the native side injects the interrupt into
# IM2_STUB (src/game/pk.asm), which jumps through the word at 3F00h + I.
# At 233Dh the start-up wait gets the same JR $ as in version A; the coin
# counter store dropped there was already done at 232Fh.
B_PATCHES = [
    (0x233C, 0x56, "IM 2 -> IM 1"),
    (0x3183, 0xED, "OUT (0),A -> LD I,A"),
    (0x3184, 0x47, "OUT (0),A -> LD I,A"),
]
B_START = (0x233D, bytes((0x3E, 0xFA,              # LD A,0FAh
                          0xED, 0x47,              # LD I,A
                          0x3E, 0x01,              # LD A,1
                          0x32, 0x00, 0x50,        # LD (5000h),A
                          0xFB, 0x18, 0xFE,        # EI; JR $
                          0x00, 0x00)))


def version(program: bytes) -> str:
    """"A" or "B"."""
    digest = hashlib.sha1(program).hexdigest()
    if digest == VERSION_A:
        return "A"
    if digest == VERSION_B:
        return "B"
    raise ValueError("unknown program")


def load_program(source: Path) -> bytes:
    return roms.program(source)


def checksums(program: bytes) -> list[tuple[int, int]]:
    return [(sum(program[b:b + 0x1000:2]) & 0xFF, sum(program[b + 1:b + 0x1000:2]) & 0xFF)
            for b in range(0, len(program), 0x1000)]


def tested_blocks(kind: str) -> int:
    """4 KiB blocks the power-on test checks: version B stops at 3000h."""
    return 4 if kind == "A" else 3


def apply(program: bytes) -> bytes:
    kind = version(program)
    blocks = tested_blocks(kind)
    if any(c != (0, 0) for c in checksums(program)[:blocks]):
        raise ValueError("the original program does not pass its own checksum")
    out = bytearray(program)
    for address, old, new, reason in PATCHES:
        if len(old) != len(new) or out[address:address + len(old)] != old:
            raise ValueError(f"{address:04X}h does not hold {old.hex()} ({reason})")
        out[address:address + len(new)] = new
    if kind == "A":
        source, destination, count = HALT_MOVE
        out[destination:destination + count] = program[source:source + count]
        address, tail = HALT_TAIL
        out[address:address + len(tail)] = tail
    else:
        for address, value, _ in B_PATCHES:
            out[address] = value
        address, block = B_START
        out[address:address + len(block)] = block
    for block in range(0, blocks * 0x1000, 0x1000):
        for parity in (0, 1):
            total = sum(out[block + parity:block + 0x1000:2]) & 0xFF
            fix = block + 0x0FFE + parity
            out[fix] = (out[fix] - total) & 0xFF
    if any(c != (0, 0) for c in checksums(bytes(out))[:blocks]):
        raise AssertionError("checksum compensation failed")
    return bytes(out)
