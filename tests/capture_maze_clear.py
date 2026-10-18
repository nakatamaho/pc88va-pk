"""Private vaeg level-clear diagnostic, not a distributable game build.

python3 -I tests/capture_maze_clear.py --roms PATH --machine-roms PATH --emulator PATH
Forces the eaten-dot counter once during active play, without changing ROMs.
Snapshots include tile/colour RAM and state RAM in the debug GVRAM area.
Does not prove normal-play completion or hardware correctness.
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
import install_roms


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for name in ("roms", "machine-roms", "emulator"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--palette", action="store_true", help="enable experimental palette-only flash")
    parser.add_argument("--menu", action="store_true", help="inject a native F10 event during white flash and close after 20 frames")
    parser.add_argument("--normal", action="store_true", help="do not force eaten-dot counter; ordinary play/death smoke test")
    parser.add_argument("--model", choices=("va", "va2"), default="va")
    parser.add_argument("--sgp", action="store_true", help="experimental SGP sprite backend")
    parser.add_argument("--scene-hold", action="store_true", help="hold display during bulk updates")
    parser.add_argument("--startup", action="store_true", help="capture immediately after start input")
    parser.add_argument("--sgp-cache", action="store_true", help="cache expanded SGP sprites")
    parser.add_argument("--draw-30", action="store_true", help="diagnostic startup in half-rate draw mode")
    parser.add_argument("--fm", action="store_true", help="enable runtime FM loader/playback")
    parser.add_argument("--output-dir", type=Path, help="private capture output directory")
    args = parser.parse_args()
    if args.sgp_cache:
        args.sgp = True
    if args.normal and args.menu:
        parser.error("--normal and --menu cannot be combined")
    name = "clear-palette" if args.palette else "clear-probe"
    if args.menu:
        name += "-menu"
    if args.startup:
        name += "-startup"
    if args.draw_30:
        name += "-30fps"
    if args.scene_hold:
        name += "-hold"
    if args.sgp:
        name += "-sgp"
    if args.sgp_cache:
        name += "-cache"
    if args.normal:
        name += "-normal"
    if args.model != "va":
        name += "-" + args.model
    root = (args.output_dir or (d88.REPO / "build/m10" / name)).resolve()
    root.mkdir(parents=True, exist_ok=True)
    source = (d88.REPO / "src/game/pk.asm").read_text()
    if args.draw_30:
        assert source.count("draw_half\tdb\t0") == 1
        source = source.replace("draw_half\tdb\t0", "draw_half\tdb\t1", 1)
    old = "\t\tcall\tsound\n.done:"
    assert source.count(old) == 1
    source = source.replace(old, """\t\tcall\tsound
                inc word [cs:probe_frames]
                cmp word [cs:probe_frames],1500
                jb .done
                cmp byte [cs:probe_forced],0
                jne .done
                mov ax,Z80SEG
                mov ds,ax
                cmp byte [4e00h],3
                jne .done
                cmp byte [4e04h],3
                jne .done
                mov byte [4e0eh],0f4h
                mov byte [cs:probe_forced],1
.done:""")
    if args.normal:
        source = source.replace("                mov byte [4e0eh],0f4h\n", "")
    old = "\t\trep\tmovsw\n%endif\n\t\tpop\tes"
    assert source.count(old) == 1
    source = source.replace(old, """\t\trep\tmovsw
                mov ax,Z80SEG
                mov ds,ax
                mov di,900h
                mov si,4e00h
                mov cx,80h
                rep movsw
%endif
\t\tpop\tes""")
    if args.scene_hold:
        marker = "                rep movsw\n%endif\n\t\tpop\tes"
        assert source.count(marker) == 1
        source = source.replace(marker, """                rep movsw
                mov di,2000h
                mov al,[cs:scene_hold]
                stosb
                mov al,[cs:scene_display]
                stosb
                mov al,[cs:back]
                stosb
                mov al,[cs:scene_quiet]
                stosb
                mov ax,[cs:scene_epoch]
                stosw
%endif
\t\tpop\tes""")
    if args.sgp:
        marker = "                rep movsw\n%endif\n\t\tpop\tes"
        if args.scene_hold:
            marker = "                stosw\n%endif\n\t\tpop\tes"
        assert source.count(marker) == 1
        first = "                stosw" if args.scene_hold else "                rep movsw"
        source = source.replace(marker, first + """
                push cs
                pop ds
                mov si,sgp_pixels
                mov di,0a00h
                mov cx,1536
                rep movsw
                mov si,sgp_commands
                mov cx,260
                rep movsw
%endif
\t\tpop\tes""")
    if args.menu:
        marker = "\t\tcmp\tbyte [cs:menu_on],0\n\t\tje\t.game"
        assert source.count(marker) == 1
        source = source.replace(marker, """                push ds
                mov ax,Z80SEG
                mov ds,ax
                cmp byte [cs:probe_menu],0
                jne .probe_menu_wait
                cmp byte [4e00h],3
                jne .probe_menu_done
                cmp byte [4e04h],15
                jne .probe_menu_done
                mov byte [cs:probe_menu],1
                mov byte [cs:probe_menu_left],20
                or word [cs:keys_new],K_F10
                or bx,K_F10
                jmp .probe_menu_done
.probe_menu_wait:
                cmp byte [cs:probe_menu],1
                jne .probe_menu_done
                dec byte [cs:probe_menu_left]
                jnz .probe_menu_done
                mov byte [cs:probe_menu],2
                or word [cs:keys_new],K_F10
.probe_menu_done:
                pop ds
""" + marker)
    source = source.replace("s_fail\t\tdb", "probe_frames dw 0\nprobe_forced db 0\nprobe_menu db 0\nprobe_menu_left db 0\ns_fail\t\tdb", 1)
    asm = root / "probe.asm"
    asm.write_text(source)
    original = d88.nasm

    def assemble(command):
        if str(command[-1]).endswith("src/game/pk.asm"):
            flags = ["-DMAZE_PALETTE"] if args.palette else []
            if args.sgp:
                flags.append("-DSGP_SPRITES")
            if args.scene_hold:
                flags.append("-DSCENE_HOLD")
            command = [*flags, "-DDEBUG_DUMP", "-l", str(root / "game.lst"), *command[:-1], str(asm)]
        original(command)

    d88.nasm = assemble
    try:
        com = build_dos.assemble(root, sgp_cache=args.sgp_cache, fm=args.fm)
    finally:
        d88.nasm = original
    tool = build_dos.load_disk_tool()
    image = root / "test.d88"
    files = {"PK.COM": com, "AUTOEXEC.BAT": b"@ECHO OFF\r\nPK\r\n",
             **install_roms.read_roms(args.roms)}
    build_dos.make_disk(tool, build_dos.MSDOS4_DEFAULT, files, image)
    listing = (root / "game.lst").read_text()
    frame = int(re.search(r"^\s*\d+\s+([0-9A-F]{8})\s+\S+\s+frame:", listing, re.M)[1], 16)
    script = (f"debug-script 1\nlimit-frame 6000\nwait-pc 3000:{frame:04x} 900\n"
              f"input-line 5\nwait-pc 3000:{frame:04x} 60\ninput-line 1\n"
              f"wait-pc 3000:{frame:04x} {1 if args.startup else 530}\n")
    for i in range(100):
        script += f"wait-pc 3000:{frame:04x} 10\ncapture c{i:03d} gvram screen\n"
    script += "exit\n"
    (root / "run.debug").write_text(script)
    (root / "run.cfg").write_text("[NekoProjectII]\nMonitor15kHz=true\n")
    cmd = [str(args.emulator.resolve()), "--model", args.model, "--cfg", str(root / "run.cfg"),
           "--no-bkupmem", "--mute", "--nowait", "--roms", str(args.machine_roms.resolve()),
           "--fdd1", str(image), "--debug-script", str(root / "run.debug"),
           "--debug-output-dir", str(root)]
    with (root / "run.log").open("w") as log:
        subprocess.run(cmd, cwd=root, env=dict(os.environ, SDL_VIDEODRIVER="dummy",
                       SDL_AUDIODRIVER="dummy"), stdout=log, stderr=subprocess.STDOUT,
                       timeout=900, check=True)
    previous = None
    for i in range(100):
        data = (root / f"c{i:03d}.gvram.bin").read_bytes()
        state = data[0x26100:0x26200]
        colours = data[0x25c00:0x26000]
        signature = (state[0], state[4], colours[0x40])
        if signature != previous:
            print(f"snapshot {i}: main={signature[0]} state={signature[1]} "
                  f"maze attribute={signature[2]}")
            previous = signature
    if args.palette and not args.menu and not args.normal:
        captures = [(root / f"c{i:03d}.gvram.bin").read_bytes() for i in range(100)]
        images = [data[:38400] for data in captures if 15 <= data[0x26104] <= 29]
        assert len(images) >= 8, "insufficient flash captures"
        assert all(image == images[0] for image in images), "background changed during palette flash"
        print("Background bytes remain unchanged across sampled flash transitions.")
    print(f"Private captures saved under {root}; hardware validation remains pending.")


if __name__ == "__main__":
    main()
