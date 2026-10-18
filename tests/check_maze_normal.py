"""Compare ordinary-play captures with palette isolation disabled/enabled.

Run capture_maze_clear.py --normal with and without --palette first.
Then: python3 -I tests/check_maze_normal.py
Requires Pillow. This is not an unassisted level-clear test.
"""
from pathlib import Path
from PIL import Image, ImageChops


def main():
    root = Path(__file__).resolve().parents[1] / "build/m10"
    tile_differences = []
    for i in range(100):
        a = root / "clear-probe-normal" / f"c{i:03d}"
        b = root / "clear-palette-normal" / f"c{i:03d}"
        with Image.open(str(a) + ".screen.bmp") as ia, Image.open(str(b) + ".screen.bmp") as ib:
            assert ImageChops.difference(ia.convert("RGB"), ib.convert("RGB")).getbbox() is None, (
                i, "visible image differs")
        x = Path(str(a) + ".gvram.bin").read_bytes()
        y = Path(str(b) + ".gvram.bin").read_bytes()
        assert x[0x26100:0x26200] == y[0x26100:0x26200], (i, "state snapshot differs")
        # The Z80 task queue can be sampled at different points within a
        # multi-cell update due to changed native work duration. Report it;
        # do not claim every source tile snapshot is identical.
        if x[0x25800:0x26000] != y[0x25800:0x26000]:
            tile_differences.append(i)
    print("100 ordinary-play/death/restart screenshots and state snapshots: identical")
    print("Source tile snapshots differing at sampling time:", tile_differences)
    print("Unassisted level completion and hardware checks remain pending.")


if __name__ == "__main__":
    main()
