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
  (runtime FM or SSG sound; no ROM data or fitted voices on the base disk).
- Targets: the vaeg emulator first, then real PC-88VA and PC-88VA2.

ROM images are not part of this repository; two versions of the program
ROMs are accepted, one of them as extracted from the game's Steam
re-release by game-extraction-toolbox. The build reads them from
`$PK_ROMS`, a zip file or a directory holding them under any names
(`--roms PATH` instead); `tools/roms.py` lists their sizes and CRC-32s.

## Preparing the FM release disk on your PC

Download and extract **`pk-v0.2.zip`** from the
[v0.2 release](https://github.com/nakatamaho/pc88va-pk/releases/tag/v0.2).
Verify its SHA-256 against the release's `SHA256SUMS`.
This workflow uses the **FM-capable v0.2 base disk**, not the SSG-only v0.1
disk. It does not require fitting voices on the PC-88VA.

1. Extract the bundle into a directory. Keep `pk-msdos4.d88`,
   `install_roms.py`, `pcengine_disk.py`, `fmfit.py` and `fmdata.py` together.
2. Purchase and install **ARCADE GAME SERIES: PAC-MAN** on Steam, then
   locate `Release_3.dll` in that game's installation directory (not
   `Release_0.dll`). Supply the DLL from your own installation. This project
   does not distribute the DLL or extracted ROMs. Only the verified DLL
   versions are supported; other versions are not guaranteed to work.
   The installer reads the DLL but does not modify or execute it.
3. Install NumPy, then run from the bundle directory:

   ```sh
   python3 -m pip install numpy
   python3 -I install_roms.py --fit-fm pk-msdos4.d88 /path/to/Release_3.dll output.d88
   ```

The script validates the DLL and embedded ROMs, extracts them in memory,
fits FM voices on the host PC, and adds the ROMs and `FMVOICE.DAT` to a new
`output.d88`. No separate ROM extraction tool or intermediate ROM zip is
needed. The original disk and DLL are unchanged; existing output files are
refused. Unknown DLL versions are rejected. Extracted ROM directories and
zip files are also accepted instead of the DLL.

Boot `output.d88` on the PC-88VA/VA2 in 15 kHz mode. The FM-capable game loads
the fitted voices at startup; do not use `PK /F`, which replaces them with
quick-generated voices. `PK /S` forces SSG sound.

F10's **DRAW** setting selects nominal 60 FPS (default) or 30 FPS rendering.
Use up/down to select it and left/right to change it. The 30 FPS option skips
alternate graphics updates, not input, sound or original-game interrupts.
It is not saved to disk and does not guarantee real-time play if a drawn
frame still exceeds the frame budget.

**The completed disk contains ROMs and derived FM voices. Keep it private;
do not upload or redistribute it.** The release base disk and Python scripts
contain neither ROMs nor fitted voices.

## Building

NASM and Python 3 (with numpy for the FM voice fit).

    python3 -I tools/build.py              # build/pk.d88, self-booting
    python3 -I tools/build_dos.py --fm --maze-palette --scene-hold --sgp-cache \
        --output-dir build/v0.2            # v0.2 ROM-free base disk
    python3 -I tools/build_m01.py          # build/m01test.d88

The self-booting build contains ROMs and is private. For the DOS build,
`--fm` enables runtime voice loading, `--sgp-cache` enables expanded-image
caching, `--maze-palette` isolates wall flashing, and `--scene-hold` completes
large background changes off-screen. Omitting these flags builds the older
CPU/SSG baseline. Installed RAM must be 512 KiB for the cache configuration.

`tools/build_dos.py` needs the msdos4-va.2 release disk and vaeg's
`tools/pc88va/pcengine_disk.py`; `tools/audit.py` the `z80dis` package.
See `docs/DESIGN.md` and `docs/ROADMAP.md`.
