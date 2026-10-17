# pc88va-pk

The Game PK: an unofficial port of an arcade game to the NEC PC-88VA (VA
and VA2). Not affiliated with or endorsed by the owners of the
original game. Two-clause BSD licence (`LICENSE`).

Approach: the original Z80 program runs unmodified apart from a small
build-time patch list, in the uPD9002 CPU's uPD780 (Z80-compatible) mode.
Native V30-mode code handles the vertical interrupt, video, sound and input.

- Display: 320x224 at 15.98 kHz; the top of the game on the left (turn the
  monitor clockwise).
- Disks: a self-booting D88 (built with the ROMs, not distributable), and
  an MS-DOS 4.0 disk whose PK.COM reads the user's ROM files at run time
  (SSG sound; no ROM data on the disk).
- Targets: the vaeg emulator first, then real PC-88VA and PC-88VA2.

ROM images are not part of this repository; two versions of the program
ROMs are accepted, one of them as extracted from the game's Steam
re-release by game-extraction-toolbox. The build reads them from
`$PK_ROMS`, a zip file or a directory holding them under any names
(`--roms PATH` instead); `tools/roms.py` lists their sizes and CRC-32s.

## Building

NASM and Python 3 (with numpy for the FM voice fit).

    python3 -I tools/build.py              # build/pk.d88, self-booting
    python3 -I tools/build_dos.py          # build/dist/pk-msdos4.d88
    python3 -I tools/build_m01.py          # build/m01test.d88

`tools/build_dos.py` needs the msdos4-va.2 release disk and vaeg's
`tools/pc88va/pcengine_disk.py`; `tools/audit.py` the `z80dis` package.
See `docs/DESIGN.md` and `docs/ROADMAP.md`.
