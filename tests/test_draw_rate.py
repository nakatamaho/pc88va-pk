"""Diagnostic F10 60/30/60 rendering toggle; native inputs/audio/IRQs stay full rate.

--roms PATH --machine-roms PATH --emulator PATH [--model va|va2]
Injects native key edges to test menu logic, not physical keyboard scanning.
"""
import argparse
import os
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_dos
import d88
import install_roms


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for name in ("roms", "machine-roms", "emulator"):
        ap.add_argument("--" + name, type=Path, required=True)
    ap.add_argument("--model", choices=("va", "va2"), default="va")
    args = ap.parse_args()
    root = (d88.REPO / "build/m12/draw-rate" / args.model).resolve()
    root.mkdir(parents=True, exist_ok=True)
    source = (d88.REPO / "src/game/pk.asm").read_text()
    marker = "\t\tcmp\tbyte [cs:menu_on],0\n\t\tje\t.game"
    assert source.count(marker) == 1
    source = source.replace(marker, """                inc word [cs:probe_frames]
                mov ax,[cs:probe_frames]
                cmp ax,1700
                je .probe_f10
                cmp ax,1710
                je .probe_f10
                cmp ax,1811
                je .probe_f10
                cmp ax,1815
                je .probe_f10
                cmp ax,1701
                jb .probe_done
                cmp ax,1707
                jbe .probe_down
                cmp ax,1708
                je .probe_right
                cmp ax,1812
                je .probe_up
                cmp ax,1813
                je .probe_left
                jmp .probe_done
.probe_down:    mov ax,K_DOWN
                jmp .probe_key
.probe_up:      mov ax,K_UP
                jmp .probe_key
.probe_right:   mov ax,K_RIGHT
                jmp .probe_key
.probe_left:    mov ax,K_LEFT
                jmp .probe_key
.probe_f10:     mov ax,K_F10
.probe_key:     or bx,ax
                or [cs:keys_new],ax
.probe_done:
""" + marker)
    source = source.replace(".play:\t\tcall\tinputs", ".play:\t\tinc word [cs:probe_inputs]\n\t\tcall\tinputs", 1)
    source = source.replace(".flash_ready:\tcall\tsprites", ".flash_ready:\tinc word [cs:probe_draws]\n\t\tcall\tsprites", 1)
    source = source.replace(".audio_only:\n\t\tcall\tsound", ".audio_only:\n\t\tinc word [cs:probe_audio]\n\t\tcall\tsound", 1)
    marker = "\t\tsub\tbp,2\t\t\t; Z80 PUSH PC; PC = DX; DI"
    assert source.count(marker) == 1
    source = source.replace(marker, "\t\tinc word [cs:probe_irqs]\n" + marker)
    # Extend the existing debug GVRAM export at the unique final state-copy.
    marker = "\t\tmov\tcx,(fm_fnum + 6 - ssg_tp) / 2\n\t\trep\tmovsw"
    assert source.count(marker) == 1
    source = source.replace(marker, marker + """
                mov di,2000h
                mov si,probe_frames
                mov cx,5
                rep movsw
                mov al,[draw_half]
                stosb
                mov al,[draw_phase]
                stosb
                mov al,[menu_sel]
                stosb
                mov al,[menu_on]
                stosb
""")
    source = source.replace("s_fail\t\tdb", "probe_frames dw 0\nprobe_inputs dw 0\nprobe_draws dw 0\nprobe_audio dw 0\nprobe_irqs dw 0\ns_fail\t\tdb", 1)
    asm = root / "probe.asm"
    asm.write_text(source)
    original = d88.nasm
    def assemble(command):
        if str(command[-1]).endswith("src/game/pk.asm"):
            command = ["-DDEBUG_DUMP", "-l", str(root / "game.lst"), *command[:-1], str(asm)]
        original(command)
    d88.nasm = assemble
    try:
        com = build_dos.assemble(root, maze_palette=True, scene_hold=True, sgp_cache=True, fm=True)
    finally:
        d88.nasm = original
    import re
    listing = (root / "game.lst").read_text()
    pc = int(re.search(r"^\s*\d+\s+([0-9A-F]{8})\s+\S+\s+frame:", listing, re.M)[1], 16)
    script = (f"debug-script 1\nlimit-frame 5000\nwait-pc 3000:{pc:04x} 900\ninput-line 5\n"
              f"wait-pc 3000:{pc:04x} 60\ninput-line 1\n")
    last = 960
    for ordinal, name in ((1600, "base"), (1700, "end60a"), (1709, "menu30"),
                          (1711, "begin30"), (1811, "end30"), (1814, "menu60"),
                          (1816, "begin60b"), (1916, "end60b")):
        script += f"wait-pc 3000:{pc:04x} {ordinal - last}\ncapture {name} gvram screen\n"
        last = ordinal
    script += "exit\n"
    (root / "run.debug").write_text(script)
    (root / "run.cfg").write_text("[NekoProjectII]\nMonitor15kHz=true\n")
    image = root / "test.d88"
    build_dos.make_disk(build_dos.load_disk_tool(), build_dos.MSDOS4_DEFAULT,
                        {"PK.COM": com, "AUTOEXEC.BAT": b"@ECHO OFF\r\nPK\r\n",
                         **install_roms.read_roms(args.roms)}, image)
    command = [str(args.emulator.resolve()), "--model", args.model, "--cfg", str(root / "run.cfg"),
               "--no-bkupmem", "--mute", "--nowait", "--roms", str(args.machine_roms.resolve()),
               "--fdd1", str(image), "--debug-script", str(root / "run.debug"),
               "--debug-output-dir", str(root)]
    with (root / "run.log").open("w") as log:
        subprocess.run(command, cwd=root, env=dict(os.environ, SDL_VIDEODRIVER="dummy",
                       SDL_AUDIODRIVER="dummy"), stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=900)
    def state(name):
        data = (root / (name + ".gvram.bin")).read_bytes()
        return struct.unpack_from("<5H4B", data, 0x27800)
    assert state("base")[5] == 0, "default is not 60 FPS"
    for name, half in (("menu30", 1), ("menu60", 0)):
        fields = state(name)
        assert fields[5] == half and fields[7:9] == (7, 1), (name, fields)
    for start, end, draws in (("base", "end60a", 100), ("begin30", "end30", 50),
                              ("begin60b", "end60b", 100)):
        a, b = state(start), state(end)
        difference = [(y - x) & 65535 for x, y in zip(a[:5], b[:5])]
        assert difference == [100, 100, draws, 100, 100], (start, end, difference)
        print(args.model, start, "->", end, "ticks/input/draw/audio/IRQ:", difference, "PASS")
    print("Diagnostic key injection is not physical-keyboard or hardware speed validation.")


if __name__ == "__main__":
    main()
