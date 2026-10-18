"""Compare CPU/SGP sprite-stage guest clocks in vaeg, not hardware speed.

Uses an identical synthetic 8-sprite register set (overlap, flips, wrap and
vertical clipping) with private ROM graphics. The diagnostic disables the
original interrupt enable after 600 frames to keep background tasks from
changing the comparison scene. This is not a normal-play benchmark.
Includes source preparation,
command construction, SGP wait and horizontal clipping; CPU erase is outside.
--roms PATH --machine-roms PATH --emulator PATH [--model va|va2]
"""
import argparse
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_dos
import d88
import install_roms


def address(listing, label):
    lines = listing.read_text().splitlines()
    for i, line in enumerate(lines):
        if re.search(r"(?<![\w.])" + re.escape(label) + ":", line):
            for code in lines[i:]:
                match = re.match(r"\s*\d+\s+([0-9A-F]{8})\s+[0-9A-F]", code)
                if match:
                    return int(match[1], 16)
    raise ValueError(label)


def clock(path):
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if fields[0] == "clock":
            return int(fields[1])
    raise ValueError(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for name in ("roms", "machine-roms", "emulator"):
        ap.add_argument("--" + name, type=Path, required=True)
    ap.add_argument("--model", default="va", choices=("va", "va2"))
    ap.add_argument("--churn", action="store_true", help="change codes/colours every frame to test eviction")
    args = ap.parse_args()
    tool = build_dos.load_disk_tool()
    romfiles = install_roms.read_roms(args.roms)
    root = (d88.REPO / "build/m11/benchmark" / args.model).resolve()
    if args.churn:
        root = root / "churn"
    results = {}
    for backend in ("cpu", "sgp", "cache"):
        work = root / backend
        work.mkdir(parents=True, exist_ok=True)
        source = (d88.REPO / "src/game/pk.asm").read_text()
        setup = """ inc word [cs:bench_frames]
 cmp word [cs:bench_frames],600
 jb .bench_live
 push ds
 mov ax,Z80SEG
 mov ds,ax
 mov byte [5000h],0
 pop ds
.bench_live:
"""
        for i, (x, y) in enumerate(((24, 30), (28, 34), (75, -7), (108, 219),
                                   (150, 90), (200, 130), (260, 160), (40, 180))):
            setup += (f" mov word [cs:s_x + {i * 2}],{x}\n"
                      f" mov word [cs:s_y + {i * 2}],{y}\n"
                      f" mov byte [cs:s_attr + {i}],{i * 5}\n"
                      f" mov byte [cs:s_colour + {i}],{i + 1}\n")
        if args.churn:
            for i in range(8):
                setup += (f" mov ax,[cs:bench_frames]\n add ax,{i * 17}\n"
                          f" mov byte [cs:s_attr + {i}],al\n and al,31\n"
                          f" mov byte [cs:s_colour + {i}],al\n")
        source = source.replace("\nsprites:\n", "\nsprites:\n" + setup, 1)
        source = source.replace("s_fail\t\tdb", "bench_frames dw 0\ns_fail\t\tdb", 1)
        asm = work / "benchmark.asm"
        asm.write_text(source)
        original = d88.nasm

        def assemble(command):
            if str(command[-1]).endswith("src/game/pk.asm"):
                command = ["-l", str(work / "game.lst"), *command[:-1], str(asm)]
            original(command)

        d88.nasm = assemble
        try:
            com = build_dos.assemble(work, maze_palette=True,
                                     sgp_sprites=backend != "cpu", scene_hold=True,
                                     sgp_cache=backend == "cache")
        finally:
            d88.nasm = original
        image = work / "test.d88"
        build_dos.make_disk(tool, build_dos.MSDOS4_DEFAULT,
                            {"PK.COM": com, "AUTOEXEC.BAT": b"@ECHO OFF\r\nPK\r\n", **romfiles}, image)
        start = address(work / "game.lst", "sprites")
        end = address(work / "game.lst", ".sprites_done")
        script = f"debug-script 1\nlimit-frame 4000\nwait-pc 3000:{start:04x} 900\n"
        for i in range(20):
            script += (f"wait-pc 3000:{start:04x} 1\ncapture a{i} registers\n"
                       f"wait-pc 3000:{end:04x} 1\ncapture b{i} registers gvram\n")
        script += "exit\n"
        (work / "run.debug").write_text(script)
        (work / "run.cfg").write_text("[NekoProjectII]\nMonitor15kHz=true\n")
        command = [str(args.emulator.resolve()), "--model", args.model, "--cfg", str(work / "run.cfg"),
                   "--no-bkupmem", "--mute", "--nowait", "--roms", str(args.machine_roms.resolve()),
                   "--fdd1", str(image), "--debug-script", str(work / "run.debug"),
                   "--debug-output-dir", str(work)]
        with (work / "run.log").open("w") as log:
            subprocess.run(command, cwd=work, env=dict(os.environ, SDL_VIDEODRIVER="dummy",
                           SDL_AUDIODRIVER="dummy"), stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=900)
        spans = [clock(work / f"b{i}.registers.tsv") - clock(work / f"a{i}.registers.tsv") for i in range(20)]
        results[backend] = statistics.median(spans)
        print(backend, "guest clocks: min/median/max", min(spans), results[backend], max(spans))
    for i in range(20):
        pages = []
        for backend in ("cpu", "sgp", "cache"):
            work = root / backend
            registers = dict(line.split("\t", 1) for line in
                             (work / f"b{i}.registers.tsv").read_text().splitlines())
            page = ((int(registers["es"], 16) - 0xa000) * 16) // 38400
            assert page in (1, 2, 3)
            data = (work / f"b{i}.gvram.bin").read_bytes()
            pages.append(data[page * 38400:(page + 1) * 38400])
        assert pages[0] == pages[1] == pages[2], (i, "synthetic workload draw-page pixels differ")
    print("20 synthetic-workload completed draw-page comparisons: identical")
    print("SGP/CPU median guest-clock ratio:", round(results["sgp"] / results["cpu"], 3))
    print("Cached SGP/CPU median guest-clock ratio:", round(results["cache"] / results["cpu"], 3))
    print("Emulator timing only; no VA/VA2 hardware speed claim.")


if __name__ == "__main__":
    main()
