# AGENTS.md — pc88va-pk

Public repository (`nakatamaho/pc88va-pk`), two-clause BSD licence
(`LICENSE`). Push only to that remote.

## What this is

The Game PK: an unofficial port of an arcade game (four 4 KiB Z80 program
ROMs, `tools/roms.py`) to the NEC PC-88VA and PC-88VA2. The original Z80
program runs in the uPD9002's uPD780 (Z80-compatible) mode. Native V30-mode code owns the
vertical interrupt, video, sound and input. See `docs/ROADMAP.md`.

## Invariants

- ROM images, ROM bytes and anything derived from them (patched ROMs,
  converted graphics, fitted voices, disk images) are never committed.
  The build reads `$PK_ROMS` (a zip or directory; `tools/roms.py`).
  `.gitignore` enforces the common cases; check `git status` before every
  commit.
- The repository and everything built from it use the name "The Game PK"
  (PK). The arcade game's name, its characters' names and its makers'
  names appear nowhere: not in files, file names, comments or commit
  messages. ROM files are identified by size, CRC-32 and SHA-1.
- Changes to the Z80 program are build-time patches in `tools/patches.py`
  with the reason for each; no ROM bytes are listed there. The original ROM
  files are never modified.
- Two products. The self-booting D88 is built with the ROMs and is never
  distributed. The MS-DOS 4.0 disk (`tools/build_dos.py`, PK.COM) is the
  distributable one: it must contain no ROM bytes, no ROM-derived data (so
  SSG sound only) and no ROM file names, and none of its files may use the
  arcade game's name or its makers' names. Check every distributed file
  for both before a release (docs/DESIGN.md).
- Display: 320x224 graphics at 15.98 kHz (`SYNC` 37/224/2/4, 59.9 Hz,
  measured on the VA2 in vaeg M104). The picture keeps the arcade board's
  raster orientation: the top of the game is on the left, for a monitor
  turned clockwise.
- Targets, in order: the vaeg emulator, then the PC-88VA and PC-88VA2.
  vaeg running a test is not evidence that the hardware does.
- Tools: NASM for V30 code, Python 3 for build scripts. Run Python that
  reads ROM data with `-I`.
- Code, comments, identifiers and committed documents are in English.

## Reference material

- `../pc88va-private-docs/tekumani/` — PC-88VA technical manuals.
- `../vaeg/docs/modernization/upd9002-upd70008-mode.md` — the CPU's
  Z80-compatible mode: mode switching, interrupts, register mapping.
- `../vaeg/docs/modernization/pc88va-video-modes.md` §12 — measured
  non-native video timings, including 320x224.
- `../vaeg/demos/sgp-boot/` — the self-booting D88 method.

## How work is organized

Work goes in milestones on a branch `topic/mNN-<name>` with commit prefix
`MNN:`; each ends at a maintainer gate on the hardware. Keep the public
documents short and technical: `docs/ROADMAP.md` gets one line a
milestone, `docs/DESIGN.md` the design; no descriptions of the game's
content.
