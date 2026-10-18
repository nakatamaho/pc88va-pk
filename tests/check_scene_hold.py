"""Validate scene-hold telemetry from private capture_maze_clear diagnostics.

python3 -I tests/check_scene_hold.py build/m10/clear-palette-startup-hold [...]
Does not prove scanline-level hardware safety or every transition frame.
"""
import sys
from pathlib import Path


def check(root):
    visible_by_epoch = {}
    held = completed = 0
    for path in sorted(root.glob("c*.gvram.bin")):
        data = path.read_bytes()
        active, shown, draw, quiet = data[0x27800:0x27804]
        epoch = int.from_bytes(data[0x27804:0x27806], "little")
        assert shown < 3 and draw < 3, path
        if active:
            held += 1
            assert shown != draw, (path, "drawing into the displayed page")
            visible = data[(shown + 1) * 38400:(shown + 2) * 38400]
            if epoch in visible_by_epoch:
                assert visible == visible_by_epoch[epoch], (path, "held display changed")
            visible_by_epoch[epoch] = visible
        elif quiet == 2:
            completed += 1
    assert held >= 2 and completed >= 1, (root, "insufficient transition coverage")
    print(root, f": PASS, {held} held snapshots, {len(visible_by_epoch)} transactions, "
          f"{completed} post-completion snapshots")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for argument in sys.argv[1:]:
        check(Path(argument))
