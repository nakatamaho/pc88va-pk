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

"""Add the ROM files that PK.COM needs to a PC-88VA MS-DOS disk image.

    python3 install_roms.py DISK.d88 SOURCE [OUTPUT.d88]

SOURCE is a zip file or a directory. Every file in it is checked; the eight
whose size and CRC-32 are those listed in PK.TXT (the four program ROMs of
either version and the four shared ROMs) are copied, under their
own names, to the root of DISK.d88, and the result is written to OUTPUT.d88
(by default DISK-roms.d88). The files are recognised by content, not by
name. They can instead be copied to the disk under MS-DOS.

Needs pcengine_disk.py (from the vaeg project) beside this script.
"""

import importlib.util
import re
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path

# (size, CRC-32) of the files, in PK.TXT's order: the four program ROMs of
# version A or of version B, and the four shared ROMs
VERSION_A = [(4096, 0xFEE263B3), (4096, 0x39D1FC83), (4096, 0x02083B03), (4096, 0x7A36FE55)]
VERSION_B = [(4096, 0xC1E6AB10), (4096, 0x1A6FB2D4), (4096, 0xBCDD1BEB), (4096, 0x817D94E3)]
SHARED = [(4096, 0x0C944964), (4096, 0x958FEDF9), (32, 0x2FC650BD), (256, 0x3EB3A8E4)]


def load_disk_tool():
    here = Path(__file__).resolve().parent
    for path in (here / "pcengine_disk.py",
                 here.parents[1] / "vaeg" / "tools" / "pc88va" / "pcengine_disk.py"):
        if path.exists():
            spec = importlib.util.spec_from_file_location("pcengine_disk", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    sys.exit("error: pcengine_disk.py not found beside install_roms.py")


def candidates(source: Path):
    if source.is_dir():
        for path in sorted(source.iterdir()):
            if path.is_file() and path.stat().st_size <= 4096:
                yield path.name, path.read_bytes()
    else:
        with zipfile.ZipFile(source) as archive:
            for info in archive.infolist():
                if not info.is_dir() and info.file_size <= 4096:
                    yield Path(info.filename).name, archive.read(info)


def dos_name(name: str, index: int) -> str:
    """The name if it is a valid 8.3 name, otherwise ROMn.BIN."""
    upper = name.upper()
    if re.fullmatch(r"[A-Z0-9_\-]{1,8}(\.[A-Z0-9_\-]{1,3})?", upper):
        return upper
    return f"ROM{index + 1}.BIN"


def read_roms(source: Path) -> dict[str, bytes]:
    """The eight files from SOURCE (the program of version A if complete,
    else of version B), by DOS name."""
    found: dict[tuple[int, int], tuple[str, bytes]] = {}
    for name, data in candidates(source):
        found.setdefault((len(data), zlib.crc32(data)), (name, data))
    program = VERSION_A if all(k in found for k in VERSION_A) else VERSION_B
    wanted = program + SHARED
    missing = [f"CRC-32 {crc:08X}, {size} bytes" for size, crc in wanted
               if (size, crc) not in found]
    if missing:
        sys.exit(f"error: not found in {source}: " + "; ".join(missing))
    out = {}
    for index, key in enumerate(wanted):
        name, data = found[key]
        name = dos_name(name, index)
        if name in out:
            name = f"ROM{index + 1}.BIN"
        out[name] = data
    return out


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    disk_path, source = Path(sys.argv[1]), Path(sys.argv[2])
    output = Path(sys.argv[3]) if len(sys.argv) == 4 else \
        disk_path.with_name(disk_path.stem + "-roms" + disk_path.suffix)
    if output.exists():
        sys.exit(f"error: {output} exists")
    roms = read_roms(source)
    tool = load_disk_tool()
    disk = tool.PcEngineDisk(disk_path.read_bytes(), require_system_files=False)
    with tempfile.TemporaryDirectory(prefix="pk-roms-") as tmp:
        for name, data in roms.items():
            path = Path(tmp) / name
            path.write_bytes(data)
            tool.add_file(disk, disk.root, path)
    disk.flush()
    output.write_bytes(disk.image)
    print(f"{output}: {len(roms)} ROM files added")
    return 0


if __name__ == "__main__":
    sys.exit(main())
