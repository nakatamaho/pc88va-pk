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

"""vaeg game smoke test: FM dispatch after startup, coin and start input.

Needs --roms PATH --machine-roms PATH --emulator PATH; optionally
--fitted PATH for a private host-fitted FMVOICE.DAT. No audio quality claim.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_dos
import d88
import fmdata
import install_roms


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for arg in ("roms", "machine-roms", "emulator"):
        ap.add_argument("--" + arg, type=Path, required=True)
    ap.add_argument("--fitted", type=Path)
    ap.add_argument("--output", type=Path, default=Path("build/v02/game-tests"))
    args = ap.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    original = d88.nasm

    def debug_nasm(command):
        if str(command[-1]).endswith("src/game/pk.asm"):
            command = ["-DDEBUG_DUMP", "-l", str(root / "game.lst"), *command]
        original(command)

    d88.nasm = debug_nasm
    try:
        com = build_dos.assemble(root, fm=True, maze_palette=True,
                                 scene_hold=True, sgp_cache=True)
    finally:
        d88.nasm = original
    listing = (root / "game.lst").read_text().splitlines()

    def label(name):
        for i, line in enumerate(listing):
            if re.search(r"(?<![\w.])" + re.escape(name) + ":", line):
                for code in listing[i:]:
                    m = re.match(r"\s*\d+\s+([0-9A-F]{8})\s+[0-9A-F]", code)
                    if m:
                        return int(m[1], 16)
        raise ValueError(name)

    frame, fmvoice = label("frame"), label("fm_voice")
    tool = build_dos.load_disk_tool()
    romfiles = install_roms.read_roms(args.roms)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    cases = [("quick-va2", "va2", False, False),
             ("quick-va", "va", False, False),
             ("readonly-va2", "va2", False, True)]
    if args.fitted:
        fmdata.unpack(args.fitted.read_bytes())
        cases.append(("fitted-va", "va", True, False))
    for name, model, fitted, readonly in cases:
        work = root / name
        work.mkdir(exist_ok=True)
        files = {"PK.COM": com, "AUTOEXEC.BAT": b"@ECHO OFF\r\nPK\r\n", **romfiles}
        if fitted:
            files["FMVOICE.DAT"] = args.fitted.read_bytes()
        image = work / "test.d88"
        build_dos.make_disk(tool, build_dos.MSDOS4_DEFAULT, files, image)
        if readonly:
            data = bytearray(image.read_bytes())
            data[0x1A] = 0x10
            image.write_bytes(data)
        (work / "run.cfg").write_text("[NekoProjectII]\nMonitor15kHz=true\n")
        (work / "run.debug").write_text(
            f"debug-script 1\nlimit-frame 4000\ncounter fm 3000:{fmvoice:04x}\n"
            f"wait-pc 3000:{frame:04x} 900\ncapture attract gvram\ninput-line 5\n"
            f"wait-pc 3000:{frame:04x} 60\ninput-line 1\n"
            f"wait-pc 3000:{frame:04x} 300\ncapture game gvram\nwait-frame 3990\n")
        cmd = [str(args.emulator.resolve()), "--model", model, "--cfg", str(work / "run.cfg"),
               "--no-bkupmem", "--mute", "--nowait", "--roms", str(args.machine_roms.resolve()),
               "--fdd1", str(image), "--debug-script", str(work / "run.debug"),
               "--debug-output-dir", str(work)]
        with (work / "run.log").open("w") as log:
            subprocess.run(cmd, cwd=work, env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=600)
        state = (work / "game.gvram.bin").read_bytes()[0x26020:]
        assert state[19] == 0, name + ": not FM"
        assert any(x != 255 for x in state[9:12]), name + ": no loaded voice"
        events = (work / "events.tsv").read_text()
        assert re.search(r"counter\s+4000\s+fm\s+[1-9]", events), name
        print(name + ": PASS (game reached, FM selected, voices loaded)", flush=True)
    print("Real hardware sound quality and elapsed generation time remain untested.")


if __name__ == "__main__":
    main()
