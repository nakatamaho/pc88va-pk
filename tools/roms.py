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

"""The arcade ROM files the build needs, found by content.

The ROMs are the user's own and are not part of the repository. SOURCE (a
zip file or a directory) may hold them under any names: each file is
recognised by its size and CRC-32 and then checked by SHA-1. The default
SOURCE is the PK_ROMS environment variable.
"""

import hashlib
import os
import sys
import zipfile
import zlib
from pathlib import Path

# role: (size, CRC-32, SHA-1)
ROMS = {
    "program1": (4096, 0xFEE263B3, "87117ba5082cd7a615b4ec7c02dd819003fbd669"),
    "program2": (4096, 0x39D1FC83, "326dbbf94c6fa2e96613dedb53702f8832b47d59"),
    "program3": (4096, 0x02083B03, "7e1945f6eb51f2e51806d0439f975f7a2889b9b8"),
    "program4": (4096, 0x7A36FE55, "01b4c38108d9dc4e48da4f8d685248e1e6821377"),
    # the other version of the program (IM 2), as extracted from the
    # game's Steam re-release by game-extraction-toolbox
    "program1b": (4096, 0xC1E6AB10, "e87e059c5be45753f7e9f33dff851f16d6751181"),
    "program2b": (4096, 0x1A6FB2D4, "674d3a7f00d8be5e38b1fdc208ebef5a92d38329"),
    "program3b": (4096, 0xBCDD1BEB, "8e47e8c2c4d6117d174cdac150392042d3e0a881"),
    "program4b": (4096, 0x817D94E3, "d4a70d56bb01d27d094d73db8667ffb00ca69cb9"),
    "tiles": (4096, 0x0C944964, "06ef227747a440831c9a3a613b76693d52a2f0a9"),
    "sprites": (4096, 0x958FEDF9, "4a937ac02216ea8c96477d4a15522070507fb599"),
    "colours": (32, 0x2FC650BD, "8d0268dee78e47c712202b0ec4f1f51109b1f2a5"),
    "lookup": (256, 0x3EB3A8E4, "19097b5f60d1030f8b82d9f1d3a241f93e5c75d6"),
    "waves": (256, 0xA9CC86BF, "bbcec0570aeceb582ff8238a4bc8546a23430081"),
}
DEFAULT = Path(os.environ["PK_ROMS"]) if os.environ.get("PK_ROMS") else None


def _files(source: Path):
    if source.is_dir():
        for path in sorted(source.iterdir()):
            if path.is_file() and path.stat().st_size <= 4096:
                yield path.read_bytes()
    else:
        with zipfile.ZipFile(source) as archive:
            for info in archive.infolist():
                if not info.is_dir() and info.file_size <= 4096:
                    yield archive.read(info)


VERSION_A = ("program1", "program2", "program3", "program4")
VERSION_B = ("program1b", "program2b", "program3b", "program4b")


def _found(source: Path) -> dict[str, bytes]:
    by_key = {(size, crc): role for role, (size, crc, _) in ROMS.items()}
    found = {}
    for data in _files(Path(source)):
        role = by_key.get((len(data), zlib.crc32(data)))
        if role is not None and hashlib.sha1(data).hexdigest() == ROMS[role][2]:
            found.setdefault(role, data)
    return found


def load(source: Path | None, roles=tuple(ROMS)) -> dict[str, bytes]:
    """The ROMs of ROLES from SOURCE, by role."""
    if source is None:
        sys.exit("error: no ROM source: give --roms PATH or set PK_ROMS")
    found = _found(source)
    missing = [r for r in roles if r not in found]
    if missing:
        sys.exit(f"error: {source} lacks the ROM(s) " + ", ".join(
            f"{r} (CRC-32 {ROMS[r][1]:08X}, {ROMS[r][0]} bytes)" for r in missing))
    return {r: found[r] for r in roles}


def program(source: Path | None) -> bytes:
    """The four program ROMs, 0000h-3FFFh, of whichever version SOURCE holds
    complete (version A first)."""
    if source is None:
        load(None)
    found = _found(source)
    for version in (VERSION_A, VERSION_B):
        if all(role in found for role in version):
            return b"".join(found[role] for role in version)
    return b"".join(load(source, VERSION_A).values())    # reports what is missing
