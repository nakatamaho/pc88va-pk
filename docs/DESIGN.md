# Design notes

Short technical notes on how The Game PK runs on the PC-88VA. The ROM
files are the user's own; `tools/roms.py` lists them by size, CRC-32 and
SHA-1.

## CPU: the arcade program in Z80-compatible mode

- The four program ROMs (0000h-3FFFh) run unmodified apart from
  `tools/patches.py` in the uPD9002's uPD780 (Z80-compatible) mode, entered
  with BRKEM. The compatible-mode segment holds the program and its RAM.
- Native V30 code runs only in the VRTC interrupt (IR2, INT 0Ah). It does
  the frame's work, then injects the program's mode 1 interrupt: it pushes
  the Z80 PC on the Z80 stack (DS0:BP), sets the saved IP to 0038h and
  clears IE in the saved PSW. Every ICU input but IR2 is masked.
- Checked on the PC-88VA and PC-88VA2 with `src/m01/m01test.asm`:
  `LD I,A`/`LD A,I`, `IM 1`, IX/IY, EXX and the injected interrupt behave
  as on a Z80; a native interrupt ends a compatible-mode HALT; a VRTC
  raised while the Z80 code has interrupts disabled is lost. Compatible
  mode runs about 2.5 (VA) to 2.9 (VA2) times the arcade CPU's speed.
- The program uses no IN/OUT and no undocumented opcode, and does not
  depend on the uPD9002's known flag differences.
- Two versions of the program are accepted (`tools/roms.py`). Version B
  (the one in the Steam re-release) uses interrupt mode 2 with I = 3Fh and
  writes the vector byte with OUT (0),A: FAh at start-up (the power-on
  test), FCh later (the interrupt routine). Both OUT (0),A become LD I,A
  and IM 2 becomes IM 1; the interrupt is injected into a small Z80 stub
  that jumps through the word at 3F00h + I. Its power-on test checks only
  0000h-2FFFh. The other 424 bytes that differ from version A are left
  alone; the input reads are at the same addresses.
- Patches: the input reads at 5000h, 5040h and 5080h are redirected to
  5100h, 5140h and 5180h (in plain RAM those addresses are also written by
  the program), and the start-up EI; HALT becomes EI; JR $ (vaeg does not
  end a compatible-mode HALT on an interrupt). The ROM checksums are kept
  by adjusting each 4 KiB block's last two bytes.

## Screen

- 320x224 graphics at 15.98 kHz, TSP SYNC 37/224/2/4 (59.9 Hz), measured
  on the VA2 in vaeg M104. The machine must be started in 15 kHz mode:
  port 1CBh bit 3 = 1 (24.8 kHz) stops the game with a message.
- The arcade board's raster orientation is kept: the top of the game is on
  the left (monitor turned clockwise). The 288x224 picture is at dots
  16-303.
- Graphics screen 0 only, 4 bits per pixel. GVRAM holds four 240-line areas
  (8 blank lines, the picture, 8 blank lines): a background with the tiles
  only, and three display pages selected by FB0's DSA (word writes). Three
  pages retain the configuration that alleviated VA2 flicker. The exact
  two-page failure mechanism and DSA latch timing remain unresolved; an
  emulator result does not establish hardware scanout timing. DSA carries the position
  chosen on the alignment screen (keypad or cursor keys, 5 s at start).
- Graphics screen 1 was not used: in the first sprite version it stopped
  at line 200 on the VA2; `src/fb1test/fb1test.asm` did not reproduce
  that with a single page (open).

## Tiles and sprites

- Built from the ROMs (`tools/gfx.py`): 2-bit tile rows, the 16-colour
  palette as PC-88VA palette words, the 32 x 4 colour lookup, sprite rows
  for both horizontal flips and both dot parities.
- Tile and colour RAM are compared with shadows using a circular pair
  cursor and REPE clean-block probes. Up to 32 changed tiles are drawn into
  the background and hidden page, then queued for the other pages. Budget
  exhaustion holds that page off-screen until two complete render sweeps;
  other pages then receive background catch-up copies when hidden. There is
  no separate preflight full-RAM scan.
- Maze flashing uses a runtime-discovered unused palette slot for wall
  pixels, leaving text colours alone; the original program drives timing.
  Background redraw pauses during the effect, including UI blinking.
- The eight 16x16 sprites: the page's previous sprite rectangles are
  restored from the background, the sprites drawn back to front with
  masks or transparent SGP BITBLT, and the parts outside raster columns
  16-271 restored by the CPU. SGP sources use 128 cached expanded-image
  slots (24 KiB), tagged by source variant, palette, clipping and direction.
  Referenced slots stay pinned through batch completion; collisions use
  per-frame staging. CPU conversion is skipped on cache hits. SGP timeout
  currently halts the prototype rather than reusing active buffers.
- Placement, flips, the colour PROM levels and the tile layout follow
  MAME's description of the board.

## Sound

- The program's WSG registers (5040h-505Fh: three voices, 20-bit
  frequency, 4-bit volume, waveform number) are read every frame.
- SSG: each voice as a square wave, TP = 681574 / F (OPN clock 3.9936 MHz),
  volume through a table to the SSG level.
- FM: `tools/fmfit.py` fits a four-operator voice to each waveform on a
  model of the YM2203 channel, one below 576 Hz and one above. The DOS base
  contains no fitted voices. `install_roms.py --fit-fm` verifies and extracts
  the user's supported Steam DLL, fits with NumPy on the host and installs
  private `FMVOICE.DAT`. Its header, waveform identifier, CRC and register
  ranges are validated before loading. No V30 precision search is included.
- With no valid fitted cache, the verified waveform PROM enables quick
  harmonic generation, otherwise SSG is selected. `/S` forces SSG; `/F`
  regenerates quick voices and may replace a fitted cache.
- The F10 screen's sound test runs the program's own sound routines from a
  small Z80 stub while the game is paused.

## Input and DIP switches

- The key matrix (ports 00h-0Eh) is read in the VRTC handler into the
  redirected inputs: keypad 8 2 4 6 or the cursor keys, 5 coin, 1 and 2
  start, ESC restarts the machine. F10 is at port 0Dh bit 4 (technical
  manual); vaeg puts it at 0Ch bit 4, and both are accepted.
- F10 pauses the game (no interrupt injected) and shows the DIP switches,
  SOUND, TEST and DRAW, drawn as tiles with the game's renderer. A DIP
  change restarts the program at 0000h. DRAW selects nominal 60 (default)
  or 30 FPS: only alternate graphics stages are skipped, not input, audio
  or original-game IRQ injection. Settings are not saved to disk. A single
  frame overrun can still delay the game at either draw-rate setting.

## MS-DOS 4.0 disk

- `tools/build_dos.py`: the FreeDOS-88VA project's MS-DOS 4.0 (release
  msdos4-va.2, MIT licence) with PK.COM, PK.TXT, PKLICENS.TXT and an
  AUTOEXEC.BAT that runs PK.
- PK.COM holds the game code and no ROM data. It finds the eight ROM files
  in a directory by size and CRC-32 (any names), builds the same payload as
  the self-booting disk in V30 code, and starts the game. MS-DOS 4.0 loads
  programs at 1DDBh, so the game is assembled with LOAD_SEG 3000h (memory
  up to 6080h, or 6700h with the expanded sprite cache). The loader checks
  the DOS allocation before using it. `PK /D` writes PAYLOAD.BIN for checking.
- Before a release, inspect base-disk files and script bundles for ROM data,
  derived voices and original ROM filenames. Check ROM-byte windows against
  the existing release baseline to distinguish generic incidental matches.
  Only the README purchase instructions may use the Steam product name.
- vaeg tests validate composition, menu selection and code paths, not real
  machine timing. A hardware half-speed report prompted removal of duplicate
  scene scans and clean-block probing. The resulting native-stage reduction
  is measured in vaeg; recovered VA/VA2 hardware speed is not yet confirmed.

## vaeg notes

- vaeg boots at 24 kHz unless `Monitor15kHz=true` is set (section
  `[NekoProjectII]`); at 24 kHz its window shows only half of the 224
  lines.
- vaeg does not end a compatible-mode HALT on a native interrupt, and the
  PSW saved by an interrupt in native mode can have MD = 0.
- The debug script's `capture ID gvram` and `tools/gvram_png.py` show the
  whole picture.
