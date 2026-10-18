"""Check private clear-probe backgrounds against an unbudgeted tile renderer.

Run after capture_maze_clear.py with --palette, with and without --menu:
python3 -I tests/check_maze_background.py --roms PATH
Checks background, not sprite composition, scanout timing or normal completion.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import gfx
import roms


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--roms", type=Path, required=True)
    args = parser.parse_args()
    data = roms.load(args.roms, ("tiles", "lookup"))
    lookup = data["lookup"]
    slot = min(set(range(1, 16)) - set(lookup))
    tiles = gfx.tile_rows(data["tiles"])
    offsets = gfx.tile_screen_offsets()
    root = Path(__file__).resolve().parents[1] / "build/m10"
    cases = {"clear-palette": [0, 12, 13, 15, 21, 36],
             "clear-palette-menu": [14, 15, 16, 17, 23, 38]}
    for name, indices in cases.items():
        for index in indices:
            capture = (root / name / f"c{index:03d}.gvram.bin").read_bytes()
            state = capture[0x26104]
            attrs = capture[0x25c00:0x26000]
            codes = capture[0x25800:0x25c00]
            flashing = 14 <= state <= 29
            colour = lookup[(31 if flashing and attrs[0x40] == 31 else 16) * 4 + 3]
            maze_errors = text_errors = reserved_ui = 0
            for tile in range(1024):
                offset = int.from_bytes(offsets[tile * 2:tile * 2 + 2], "little")
                if offset == 65535:
                    continue
                interior = 0x40 <= tile < 0x3c0
                for y in range(8):
                    for x in range(8):
                        packed = tiles[codes[tile] * 16 + y * 2 + x // 4]
                        pixel = (packed >> (6 - 2 * (x % 4))) & 3
                        expected = lookup[(attrs[tile] & 31) * 4 + pixel] & 15
                        packed = capture[1280 + offset + y * 160 + x // 2]
                        actual = (packed >> (4 if x % 2 == 0 else 0)) & 15
                        if actual == slot:
                            reserved_ui += not interior
                            actual = colour
                        if actual != expected:
                            if interior:
                                maze_errors += 1
                            else:
                                text_errors += 1
            assert reserved_ui == 0, (name, index, "wall slot used by UI")
            assert maze_errors == 0, (name, index, "maze differs from full redraw", maze_errors)
            if not flashing:
                assert text_errors == 0, (name, index, "text differs after flash")
            # During flashing the UI is intentionally frozen (including its blink).
            print(f"{name} snapshot {index}: maze exact, UI colour isolated; "
                  f"frozen text differences={text_errors}")
    print("PASS; forced-state diagnostic is not an unassisted level-clear test.")


if __name__ == "__main__":
    main()
