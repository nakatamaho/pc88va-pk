# Roadmap

| Milestone | Content | State |
|---|---|---|
| M01 | Feasibility of Z80-compatible mode, probe disk | passed on VA and VA2 |
| M02 | Self-booting disk, 320x224 15.98 kHz screen | passed on VA and VA2 |
| M03 | Tile layer | passed on VA and VA2 |
| M04 | Sprites, page flipping, alignment screen | passed on VA and VA2 |
| M05 | Keyboard input, DIP switch screen | passed on VA and VA2 |
| M06 | Sound: SSG, then FM | passed on VA |
| M07 | Sound test, MS-DOS 4.0 disk with run-time ROM loading | passed on VA and VA2 |
| M08 | The other program version (as in the Steam re-release) | hardware test pending |

| M10 | Palette maze flashing and off-screen scene completion | vaeg checked |
| M11 | Optional SGP sprites with 24 KiB expanded-image cache | vaeg checked |
| M12 | Host-side FM fitting from Steam DLL, F10 30/60 draw choice | v0.2; corrected hardware speed pending |

M01-M08 status is retained from v0.1. Details in `docs/DESIGN.md`.
A combined-build slowdown was reported on VA and VA2. The latest background
scan corrections and draw-rate selection pass emulator diagnostics; real
hardware speed recovery has not yet been confirmed. Release authorization
must not be described as a hardware timing measurement.

Later candidates: closer reproduction of the WSG sound, high score saving,
the graphics screen 1 question (`docs/DESIGN.md`).
