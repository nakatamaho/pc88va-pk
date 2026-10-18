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

"""Run the real DOS loader in vaeg; requires private ROMs supplied by user.

python3 -I tests/test_fm_dos.py --roms PATH --machine-roms PATH --emulator PATH
All images, caches, payloads and logs stay under build/v02/tests (ignored).
No ROM-derived data is printed. Does not alter v0.1 artifacts or releases.
"""
import argparse
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_dos
import fmdata
import install_roms
import roms


def read_file(tool, image, name):
    disk = tool.PcEngineDisk(image.read_bytes(), require_system_files=False)
    for _, entry in tool.iter_entries(disk.root):
        if tool.display_name(entry[:11]) == name:
            cluster = struct.unpack_from("<H", entry, 26)[0]
            size = struct.unpack_from("<I", entry, 28)[0]
            return b"".join(disk.read_cluster(c) for c in disk.cluster_chain(cluster))[:size]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--roms", required=True, type=Path)
    ap.add_argument("--machine-roms", required=True, type=Path)
    ap.add_argument("--emulator", required=True, type=Path)
    ap.add_argument("--model", default="va2", choices=("va", "va2"))
    ap.add_argument("--output", type=Path, default=Path("build/v02/tests"))
    args = ap.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    source = roms.load(args.roms, ("waves",))["waves"]
    expected = fmdata.quick_voices(source)
    tool = build_dos.load_disk_tool()
    com = build_dos.assemble(root, fm=True, maze_palette=True,
                             scene_hold=True, sgp_cache=True)
    # Anonymous filenames; content recognition must not depend on ROM names.
    all_roms = {f"R{i}.BIN": data for i, data in
                enumerate(install_roms.read_roms(args.roms).values(), 1)}
    no_wave = {name: data for name, data in all_roms.items()
               if (len(data), zlib.crc32(data)) != (256, fmdata.WAVE_CRC)}
    # Synthetic legal register values distinguish loading from regeneration.
    imported = bytes((7, 1, 50, 2, 60, 3, 70, 4, 80)) * 16
    cache = fmdata.pack(imported, 2)

    def run(name, files, command="PK /D", want=expected, ready=True, prepare=None):
        work = root / name
        work.mkdir(exist_ok=True)
        image = work / "test.d88"
        payload_files = {"PK.COM": com, "AUTOEXEC.BAT":
                         ("@ECHO OFF\r\n" + command + "\r\n").encode(), **files}
        build_dos.make_disk(tool, build_dos.MSDOS4_DEFAULT, payload_files, image)
        if prepare:
            prepare(image, work)
        (work / "run.cfg").write_text("[NekoProjectII]\nMonitor15kHz=true\n")
        (work / "run.debug").write_text(
            "debug-script 1\nlimit-frame 1800\nwait-frame 1790\n")
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        cmd = [str(args.emulator.resolve()), "--model", args.model,
               "--cfg", str(work / "run.cfg"), "--no-bkupmem", "--mute", "--nowait",
               "--roms", str(args.machine_roms.resolve()), "--fdd1", str(image),
               "--debug-script", str(work / "run.debug"),
               "--debug-output-dir", str(work),
               "--screenshot", f"1750:{work / 'screen.png'}"]
        with (work / "run.log").open("w") as log:
            subprocess.run(cmd, cwd=work, env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=360)
        payload = read_file(tool, image, "PAYLOAD.BIN")
        assert payload is not None and len(payload) == 0xE800, name + ": no payload"
        assert payload[0x9F01] == int(ready), name + ": FM ready flag"
        if ready:
            assert payload[0x9900:0x9990] == want, name + ": voices mismatch"
        else:
            assert not any(payload[0x9900:0x9990]), name + ": unexpected voices"
        print(name + ": PASS", flush=True)
        return image

    image = run("first-and-second", all_roms, "PK /D\r\nPK /D")
    saved = read_file(tool, image, "FMVOICE.DAT")
    assert saved == fmdata.pack(expected), "saved cache differs from reference"
    assert read_file(tool, image, "FMVOICE.$$$") is None
    run("load-without-prom", {**no_wave, "FMVOICE.DAT": cache}, want=imported)
    run("regenerate", {**all_roms, "FMVOICE.DAT": cache}, "PK /D /F")
    run("ssg", {**all_roms, "FMVOICE.DAT": cache}, "PK /D /S /F", ready=False)
    run("missing-prom", no_wave, ready=False)
    cases = {"truncated": cache[:-1], "trailing": cache + b"x",
             "bad-header": bytes(164), "bad-crc": cache[:30] + b"x" + cache[31:]}
    for name, data in cases.items():
        run(name, {**no_wave, "FMVOICE.DAT": data}, ready=False)
    bad = bytearray(cache)
    bad[21] = 16
    struct.pack_into("<I", bad, 16, zlib.crc32(bad[20:]))
    run("bad-register", {**no_wave, "FMVOICE.DAT": bytes(bad)}, ready=False)
    run("rebuild-corrupt", {**all_roms, "FMVOICE.DAT": b"invalid"})

    def fill_disk(image, work):
        disk = tool.PcEngineDisk(image.read_bytes(), require_system_files=False)
        # Reserve PAYLOAD.BIN first, leaving no cluster for the FM temp file.
        # /D can still replace its old allocation after the failed cache save.
        for name, size in (("PAYLOAD.BIN", 0xE800), ("FILLER.BIN", None)):
            path = work / name
            path.write_bytes(bytes(disk.free_bytes() if size is None else size))
            tool.add_file(disk, disk.root, path)
        assert disk.free_bytes() == 0
        disk.flush()
        image.write_bytes(disk.image)

    image = run("disk-full", all_roms, prepare=fill_disk)
    assert read_file(tool, image, "FMVOICE.DAT") is None
    assert read_file(tool, image, "FMVOICE.$$$") is None

    def subdir(image, work):
        disk = tool.PcEngineDisk(image.read_bytes(), require_system_files=False)
        directory = work / "DATA"
        directory.mkdir(exist_ok=True)
        for name, data in all_roms.items():
            (directory / name).write_bytes(data)
        tool.install_directory(disk, disk.root, directory)
        disk.flush()
        image.write_bytes(disk.image)

    run("directory", {}, "PK /D DATA", prepare=subdir)
    run("reload-directory", {}, "PK /D DATA\r\nPK /D DATA", prepare=subdir)
    print("All DOS FM cases passed. Hardware sound/timing still requires maintainer gate.")


if __name__ == "__main__":
    main()
