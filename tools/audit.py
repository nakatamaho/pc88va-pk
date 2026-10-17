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

"""Audit the arcade game's Z80 program for the PC-88VA port.

Reads the program ROMs (tools/roms.py), disassembles them recursively from
the reset and interrupt entries, and reports what matters for running the
program in the uPD9002's Z80-compatible mode: I/O and CPU-control
instructions, index and alternate registers, undocumented opcodes,
flag-sensitive sequences, and every access to the 5000h-50FFh I/O area.

Nothing is written; the report goes to standard output.

Requires the z80dis package (pip install z80dis).

    python3 -I tools/audit.py [--roms PATH]
"""

import argparse
import sys
from collections import defaultdict
from pathlib import Path

from z80dis import z80

sys.path.insert(0, str(Path(__file__).resolve().parent))
from patches import DEFAULT_ZIP, load_program  # noqa: E402

# Entry points: reset, the RST 38h interrupt, and the targets of the
# interrupt dispatcher at 0F3Ch.
ENTRIES = [0x0000, 0x0038, 0x008D, 0x3000]

# Inline-argument conventions of the program's RST routines.
RST_INLINE = {0x28: 2, 0x30: 3}   # RST 28h: two bytes, RST 30h: three
RST_JUMP_TABLE = 0x20             # RST 20h: word table of targets follows

# ED opcodes defined on a Zilog Z80 (documented and the common mirrors).
ED_DEFINED = set()
for base in range(0x40, 0x80, 8):
    ED_DEFINED.update(range(base, base + 8))
ED_DEFINED -= {0x77, 0x7F}
ED_DEFINED.update({0xA0, 0xA1, 0xA2, 0xA3, 0xA8, 0xA9, 0xAA, 0xAB,
                   0xB0, 0xB1, 0xB2, 0xB3, 0xB8, 0xB9, 0xBA, 0xBB})
# Of those, the ones that are undocumented mirrors on a Zilog Z80.
ED_MIRRORS = {0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C,      # NEG
              0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D,            # RETN
              0x4E, 0x66, 0x6E, 0x76, 0x7E,                  # IM
              0x70, 0x71}                                    # IN (C) / OUT (C),0

# Instructions that read H or N, or P/V after an instruction whose P/V the
# uPD9002 computes differently (vaeg docs/modernization/uPD9002-zex-results.md).
PV_CONDITIONS = {"CC.P", "CC.NOT_P"}


def classify_undocumented(code: bytes, addr: int) -> str | None:
    """Name the undocumented feature an instruction uses, if any."""
    b0 = code[addr]
    b1 = code[addr + 1] if addr + 1 < len(code) else 0
    if b0 == 0xCB and 0x30 <= b1 <= 0x37:
        return "SLL"
    if b0 == 0xED:
        if b1 not in ED_DEFINED:
            return f"undefined ED {b1:02X}"
        if b1 in ED_MIRRORS:
            return f"ED {b1:02X} mirror"
        return None
    if b0 in (0xDD, 0xFD):
        if b1 == 0xCB:
            op = code[addr + 3]
            if op & 7 != 6:
                return f"{b0:02X} CB register form {op:02X}"
            return None
        decoded = z80.decode(code[addr:addr + 4], addr)
        text = z80.decoded2str(decoded).lower()
        if any(r in text for r in ("ixh", "ixl", "iyh", "iyl")):
            return "index half register"
        if "ix" not in text and "iy" not in text:
            return "prefix without effect"
    return None


class Disassembler:
    def __init__(self, code: bytes) -> None:
        self.code = code
        self.insns: dict[int, z80.Decoded] = {}
        self.data: dict[int, str] = {}       # inline argument and table bytes
        self.tables: list[tuple[int, int, list[int]]] = []
        self.indirect: list[int] = []        # JP (HL)/(IX)/(IY) sites

    def run(self, entries: list[int]) -> None:
        work = list(entries)
        while work:
            pc = work.pop()
            while 0 <= pc < len(self.code) and pc not in self.insns and pc not in self.data:
                decoded = z80.decode(self.code[pc:pc + 4], pc)
                if decoded.status != z80.DECODE_STATUS.OK or decoded.len == 0:
                    self.data[pc] = "undecodable"
                    break
                self.insns[pc] = decoded
                nxt = pc + decoded.len
                op = decoded.op
                operands = decoded.operands
                cond = any(t == z80.OPER_TYPE.COND for t, _ in operands)
                target = next((v for t, v in operands if t == z80.OPER_TYPE.ADDR), None)
                if op in (z80.OP.JP, z80.OP.JR, z80.OP.DJNZ, z80.OP.CALL):
                    if target is None:          # JP (HL), (IX), (IY)
                        self.indirect.append(pc)
                        break
                    work.append(target)
                    if op in (z80.OP.JP, z80.OP.JR) and not cond:
                        break
                elif op == z80.OP.RST:
                    vector = next(v for t, v in operands)
                    work.append(vector)
                    if vector in RST_INLINE:
                        for i in range(RST_INLINE[vector]):
                            self.data[nxt + i] = f"RST {vector:02X}h argument"
                        nxt += RST_INLINE[vector]
                    elif vector == RST_JUMP_TABLE:
                        work.extend(self.jump_table(nxt))
                        break
                    elif vector == 0x00:
                        break
                elif op in (z80.OP.RET, z80.OP.RETI, z80.OP.RETN) and not cond:
                    break
                elif op == z80.OP.HALT:
                    pass
                pc = nxt

    def jump_table(self, start: int) -> list[int]:
        """Heuristic: take word entries until one cannot be a code address."""
        targets = []
        addr = start
        while addr + 1 < len(self.code) and addr not in self.insns:
            value = self.code[addr] | (self.code[addr + 1] << 8)
            if value >= 0x4000 or value < 0x0008:
                break
            targets.append(value)
            self.data[addr] = self.data[addr + 1] = "RST 20h table"
            addr += 2
            # A table entry pointing just past the table means code follows.
            if addr in targets:
                break
        self.tables.append((start, addr, targets))
        return targets


def text(decoded: z80.Decoded) -> str:
    return z80.decoded2str(decoded)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--roms", type=Path, default=DEFAULT_ZIP,
                        help="zip or directory with the ROM files (default: $PK_ROMS)")
    args = parser.parse_args()
    code = load_program(args.roms)
    dis = Disassembler(code)
    dis.run(ENTRIES)

    covered = set()
    for addr, d in dis.insns.items():
        covered.update(range(addr, addr + d.len))
    covered.update(dis.data)
    print("# Z80 program audit\n")
    print(f"Instructions reached: {len(dis.insns)}; bytes covered "
          f"{len(covered)} of {len(code)} ({100 * len(covered) // len(code)}%).")
    print(f"RST 20h jump tables: {len(dis.tables)}; indirect jumps: {len(dis.indirect)}.\n")

    groups: dict[str, list[str]] = defaultdict(list)
    io_reads: dict[int, list[int]] = defaultdict(list)
    io_writes: dict[int, list[int]] = defaultdict(list)
    order = sorted(dis.insns)
    for i, addr in enumerate(order):
        d = dis.insns[addr]
        line = f"{addr:04X}  {code[addr:addr + d.len].hex()}  {text(d)}"
        op = d.op
        s = text(d).lower()
        if op in (z80.OP.IN, z80.OP.OUT, z80.OP.INI, z80.OP.IND, z80.OP.INIR,
                  z80.OP.INDR, z80.OP.OUTI, z80.OP.OUTD, z80.OP.OTIR, z80.OP.OTDR):
            groups["I/O instructions"].append(line)
        if op in (z80.OP.HALT, z80.OP.IM, z80.OP.EI, z80.OP.DI, z80.OP.RETI, z80.OP.RETN):
            groups["CPU control"].append(line)
        if "ld a,i" in s or "ld i,a" in s or "ld a,r" in s or "ld r,a" in s:
            groups["I and R registers"].append(line)
        if op in (z80.OP.EXX,) or "af'" in s:
            groups["Alternate register set"].append(line)
        if op == z80.OP.DAA:
            prev = dis.insns.get(order[i - 1]) if i else None
            prev_text = text(prev) if prev and order[i - 1] + prev.len == addr else "?"
            groups["DAA (with the preceding instruction)"].append(f"{line}    after: {prev_text}")
        if any(t == z80.OPER_TYPE.COND and str(v) in PV_CONDITIONS for t, v in d.operands):
            prev = dis.insns.get(order[i - 1]) if i else None
            prev_text = text(prev) if prev else "?"
            groups["P/V conditions (with the preceding instruction)"].append(
                f"{line}    after: {prev_text}")
        note = classify_undocumented(code, addr)
        if note:
            groups["Undocumented opcodes"].append(f"{line}    [{note}]")
        if "ix" in s:
            groups["_ix"].append(line)
        if "iy" in s:
            groups["_iy"].append(line)
        for t, v in d.operands:
            if t == z80.OPER_TYPE.ADDR_DEREF and 0x5000 <= v <= 0x50FF:
                dest_first = d.operands[0] == (t, v)
                (io_writes if dest_first else io_reads)[v].append(addr)
            if t == z80.OPER_TYPE.IMM and 0x5000 <= v <= 0x50FF and len(d.operands) == 2:
                groups["Pointers into 5000h-50FFh (check the use)"].append(line)

    for title in ["I/O instructions", "CPU control", "I and R registers",
                  "Alternate register set", "Undocumented opcodes",
                  "DAA (with the preceding instruction)",
                  "P/V conditions (with the preceding instruction)",
                  "Pointers into 5000h-50FFh (check the use)"]:
        print(f"## {title}\n")
        lines = groups.get(title, [])
        print("\n".join(lines) if lines else "(none)")
        print()
    print("## Index registers\n")
    print(f"IX: {len(groups['_ix'])} instructions; IY: {len(groups['_iy'])} instructions.\n")

    print("## Direct reads of 5000h-50FFh\n")
    for port in sorted(io_reads):
        print(f"{port:04X}: " + " ".join(f"{a:04X}" for a in io_reads[port]))
    print("\n## Direct writes to 5000h-50FFh\n")
    for port in sorted(io_writes):
        print(f"{port:04X}: " + " ".join(f"{a:04X}" for a in io_writes[port]))

    print("\n## RST 20h jump tables (heuristic extent)\n")
    for start, end, targets in dis.tables:
        print(f"{start:04X}-{end - 1:04X}: {len(targets)} entries")
    print("\n## Indirect jumps\n")
    for addr in dis.indirect:
        print(f"{addr:04X}  {text(dis.insns[addr])}")

    print("\n## Uncovered runs of 32 or more bytes\n")
    run_start = None
    for addr in range(len(code) + 1):
        if addr < len(code) and addr not in covered:
            if run_start is None:
                run_start = addr
        else:
            if run_start is not None and addr - run_start >= 32:
                values = set(code[run_start:addr])
                fill = f"all {values.pop():02X}h" if len(values) == 1 else "mixed"
                print(f"{run_start:04X}-{addr - 1:04X} ({addr - run_start} bytes, {fill})")
            run_start = None
    return 0


if __name__ == "__main__":
    sys.exit(main())
