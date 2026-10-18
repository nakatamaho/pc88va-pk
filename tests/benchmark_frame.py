"""Measure native frame stages in vaeg, not hardware timings.

Uses normal game input and compares scene-hold on/off with CPU/SSG.
--roms PATH --machine-roms PATH --emulator PATH [--output PATH]
"""
import argparse
import os
import re
import subprocess
import sys
import statistics
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_dos
import d88
import install_roms


def clock(path):
    return int(dict(line.split("\t", 1) for line in path.read_text().splitlines())["clock"])


def label(lines, name, after=0):
    for i in range(after, len(lines)):
        if re.search(r"(?<![\w.])" + re.escape(name) + ":", lines[i]):
            for code in lines[i:]:
                match = re.match(r"\s*\d+\s+([0-9A-F]{8})\s+[0-9A-F]", code)
                if match:
                    return int(match[1], 16)
    raise ValueError(name)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for name in ("roms", "machine-roms", "emulator"):
        ap.add_argument("--" + name, type=Path, required=True)
    ap.add_argument("--output", type=Path, default=Path("build/m12/frame-profile"))
    args = ap.parse_args()
    root = args.output.resolve()
    original_nasm = d88.nasm
    romfiles = install_roms.read_roms(args.roms)
    tool = build_dos.load_disk_tool()
    for name, hold, cache, fm in (("cpu-ssg-hold", True, False, False),
                                   ("cpu-ssg-nohold", False, False, False),
                                   ("cache-fm-hold", True, True, True)):
        work = root / name
        work.mkdir(parents=True, exist_ok=True)
        source = (d88.REPO / "src/game/pk.asm").read_text()
        marker = "\t\tcall\tsound\n.done:"
        assert source.count(marker) == 1
        source = source.replace(marker, "\t\tcall\tsound\n.native_done:\n.done:")
        asm = work / "profile.asm"
        asm.write_text(source)
        def assemble(command):
            if str(command[-1]).endswith("src/game/pk.asm"):
                command = ["-l", str(work / "game.lst"), *command[:-1], str(asm)]
            original_nasm(command)
        d88.nasm = assemble
        try:
            com = build_dos.assemble(work, maze_palette=True, scene_hold=hold,
                                     sgp_cache=cache, fm=fm)
        finally:
            d88.nasm = original_nasm
        lines = (work / "game.lst").read_text().splitlines()
        frame_line = next(i for i, line in enumerate(lines) if "frame:\t\tpusha" in line)
        targets = [label(lines, n, frame_line if n in (".play", ".native_done") else 0)
                   for n in (".play", "render", "sprites", "sound", ".native_done")]
        frame = label(lines, "frame")
        script = (f"debug-script 1\nlimit-frame 5000\nwait-pc 3000:{frame:04x} 900\ninput-line 5\n"
                  f"wait-pc 3000:{frame:04x} 60\ninput-line 1\nwait-pc 3000:{frame:04x} 300\n")
        for i in range(40):
            for j, pc in enumerate(targets):
                script += f"wait-pc 3000:{pc:04x} 1\ncapture p{i}-{j} registers\n"
        script += "exit\n"
        (work / "run.debug").write_text(script)
        (work / "run.cfg").write_text("[NekoProjectII]\nMonitor15kHz=true\n")
        image = work / "test.d88"
        build_dos.make_disk(tool, build_dos.MSDOS4_DEFAULT,
                            {"PK.COM": com, "AUTOEXEC.BAT": b"@ECHO OFF\r\nPK\r\n", **romfiles}, image)
        command = [str(args.emulator.resolve()), "--model", "va", "--cfg", str(work / "run.cfg"),
                   "--no-bkupmem", "--mute", "--nowait", "--roms", str(args.machine_roms.resolve()),
                   "--fdd1", str(image), "--debug-script", str(work / "run.debug"),
                   "--debug-output-dir", str(work)]
        with (work / "run.log").open("w") as log:
            subprocess.run(command, cwd=work, env=dict(os.environ, SDL_VIDEODRIVER="dummy",
                           SDL_AUDIODRIVER="dummy"), stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=900)
        samples = [[clock(work / f"p{i}-{j}.registers.tsv") for j in range(5)] for i in range(40)]
        spans = [[row[j + 1] - row[j] for row in samples] for j in range(4)]
        print(name, "median guest clocks (pre-render/background/sprites/sound/total):",
              *[statistics.median(s) for s in spans],
              statistics.median(row[-1] - row[0] for row in samples), flush=True)
    print("Includes only native frame work, not original game logic or hardware bus timings.")


if __name__ == "__main__":
    main()
