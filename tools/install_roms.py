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

    python3 -I install_roms.py DISK.d88 SOURCE [OUTPUT.d88] [--fit-fm]

SOURCE is a verified Steam Release_3.dll, a zip file or a directory.
The DLL is validated and sliced in memory; directory/zip files are checked.
The eight
whose size and CRC-32 are those listed in PK.TXT (the four program ROMs of
either version and the four shared ROMs) are copied, under their
own names (generic names for DLL input), to the root of DISK.d88, and the result is written to OUTPUT.d88
(by default DISK-roms.d88). The files are recognised by content, not by
name. They can instead be copied to the disk under MS-DOS.

--fit-fm also adds host-fitted FMVOICE.DAT (requires NumPy, fmfit.py and
fmdata.py beside this script, and an FM-capable PK.COM on the input disk).
The verified waveform PROM must be included in SOURCE. A verified Steam Release_3.dll can be supplied directly instead of extracted
ROMs. Other DLL versions are rejected; recognition uses content, not name.
Generated voices and completed disks are private ROM-derived data.

Needs pcengine_disk.py (from the vaeg project) beside this script.
"""

import argparse
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
WAVES = (256, 0xA9CC86BF)


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


# Steam DLL layout, documented by game-extraction-toolbox task metadata.
# Size/CRC identifiers and offsets only; no embedded ROM data or filenames.
DLL_ID = (394240, 0xAA58DC77)
DLL_IDS = (DLL_ID, (247296, 0xEF8E9EB3))
DLL_PARTS = [(0x28020, VERSION_B[0]), (0x29020, VERSION_B[1]),
             (0x2A020, VERSION_B[2]), (0x2B020, VERSION_B[3]),
             (0x1C050, SHARED[0]), (0x1AC50, SHARED[1]),
             (0x1AB30, SHARED[2]), (0x1AB50, SHARED[3]),
             (0x1AA30, WAVES)]


def dll_candidates(data: bytes):
    """Validate the supported DLL and every slice before returning any ROM."""
    if (len(data), zlib.crc32(data)) not in DLL_IDS:
        raise ValueError("unsupported DLL: expected the verified Steam Release_3.dll")
    extracted = []
    for index, (offset, (size, crc)) in enumerate(DLL_PARTS):
        part = data[offset:offset + size]
        if (len(part), zlib.crc32(part)) != (size, crc):
            raise ValueError(f"DLL ROM validation failed for part {index + 1}")
        extracted.append((f"ROM{index + 1}.BIN", part))
    return extracted


def candidates(source: Path):
    if source.is_file() and (source.suffix.lower() == ".dll" or
                             source.stat().st_size in {size for size, _ in DLL_IDS}):
        yield from dll_candidates(source.read_bytes())
    elif source.is_dir():
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
    if WAVES in found:
        wanted.append(WAVES)
    out = {}
    reserved = {"PK.COM", "AUTOEXEC.BAT", "CONFIG.SYS", "COMMAND.COM", "IO.SYS",
                "MSDOS.SYS", "FMVOICE.DAT", "PK.TXT", "PKLICENS.TXT"}
    for index, key in enumerate(wanted):
        name, data = found[key]
        name = dos_name(name, index)
        if name in out or name in reserved:
            suffix = index + 1
            name = f"ROM{suffix}.BIN"
            while name in out or name in reserved:
                suffix += 1
                name = f"ROM{suffix}.BIN"
        out[name] = data
    return out


def fit_voices(files: dict[str, bytes]) -> bytes:
    """Fit on the host; never print or commit ROM-derived voice values."""
    prom = next((data for data in files.values()
                 if (len(data), zlib.crc32(data)) == WAVES), None)
    if prom is None:
        raise ValueError("FM fitting requires the verified 256-byte waveform PROM")
    # Explicit sibling path also supports python -I on exported scripts.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import fmdata
    import fmfit
    print("Fitting 16 FM voices on the host (requires NumPy); please wait.", flush=True)
    return fmdata.pack(fmfit.fm_voices(prom), method=2)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("disk", type=Path)
    parser.add_argument("source", type=Path, help="Steam Release_3.dll, extracted ROM directory or zip")
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--fit-fm", action="store_true", help="host-fit FMVOICE.DAT and add it to an FM-capable disk")
    args = parser.parse_args()
    disk_path, source = args.disk, args.source
    output = args.output or disk_path.with_name(disk_path.stem + "-roms" + disk_path.suffix)
    if output.exists():
        sys.exit(f"error: {output} exists")
    try:
        roms = read_roms(source)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        sys.exit(f"error: {error}; no output disk written")
    tool = load_disk_tool()
    disk = tool.PcEngineDisk(disk_path.read_bytes(), require_system_files=False)
    if args.fit_fm:
        import struct
        offset, exists = tool.find_entry(disk.root, tool.short_name("PK.COM"))
        if not exists:
            sys.exit("error: PK.COM not found on input disk")
        cluster = struct.unpack_from("<H", disk.root, offset + 26)[0]
        size = struct.unpack_from("<I", disk.root, offset + 28)[0]
        program = b"".join(disk.read_cluster(c) for c in disk.cluster_chain(cluster))[:size]
        if b"FMVOICE.DAT\0" not in program:
            sys.exit("error: input disk needs an FM-capable PK.COM; the SSG-only v0.1 disk is not supported by --fit-fm")
        try:
            roms["FMVOICE.DAT"] = fit_voices(roms)
        except (ImportError, ValueError) as error:
            sys.exit(f"error: {error}; no output disk written")
    with tempfile.TemporaryDirectory(prefix="pk-roms-") as tmp:
        for name, data in roms.items():
            path = Path(tmp) / name
            path.write_bytes(data)
            tool.add_file(disk, disk.root, path)
    disk.flush()
    output.write_bytes(disk.image)
    print(f"{output}: ROMs{' and fitted FM voices' if args.fit_fm else ''} added (private; do not distribute)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
