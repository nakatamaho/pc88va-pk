"""Check SGP transparent copies against a software compositor.

Run capture_maze_clear.py --palette --sgp --normal first, plus the CPU
--palette --normal control. ROMs/captures remain private in build/.
This checks captured frames, not hardware timing or every sprite variant.
"""
import struct
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1] / "build/m10"
    source = root / "clear-palette-sgp-normal"
    differing = []
    for frame in range(100):
        data = (source / f"c{frame:03d}.gvram.bin").read_bytes()
        control = (root / "clear-palette-normal" / f"c{frame:03d}.gvram.bin").read_bytes()
        if data[:153600] != control[:153600]:
            differing.append(frame)
            # Different program task progress is reported, not silently
            # accepted as a sprite mismatch. The compositor is checked below.
        pixels = data[0x26200:0x26e00]
        commands = data[0x26e00:0x26e00 + 520]
        records = []
        for i in range(16):
            offset = 6 + i * 32
            if struct.unpack_from("<H", commands, offset)[0] == 1:
                break
            q = struct.unpack_from("<16H", commands, offset)
            assert (q[0], q[1], q[4], q[7], q[11], q[14], q[15]) == (4, 1, 12, 5, 160, 7, 0x105)
            assert q[2] == q[9] and q[3] == q[10]
            records.append(q)
        if not records:
            continue
        base = records[0][5] + (records[0][6] << 16)
        first_dest = records[0][12] + (records[0][13] << 16) - 0x200000
        page = first_dest // 38400
        assert page in (1, 2, 3)
        expected = bytearray(data[:38400])
        for i, q in enumerate(records):
            src = q[5] + (q[6] << 16) - base
            assert src == i * 192
            dest = q[12] + (q[13] << 16) - 0x200000 - page * 38400
            dot = q[8] >> 4
            for y in range(q[3]):
                for x in range(q[2]):
                    value = (pixels[src + y * 12 + x // 2] >> (4 if x % 2 == 0 else 0)) & 15
                    where = dest + y * 160 + (x + dot) // 2
                    # CPU clip_rects restores columns outside raster 16..271.
                    if not 16 <= where % 160 < 144 or value == 0:
                        continue
                    shift = 4 if (x + dot) % 2 == 0 else 0
                    expected[where] = (expected[where] & ~(15 << shift)) | (value << shift)
        actual = data[page * 38400:(page + 1) * 38400]
        assert expected == actual, (frame, "SGP output differs from transparent ordered compositor")
    print("100 captured SGP frames: ordered transparency/CPU clipping compositor PASS")
    print("CPU/SGP full-GVRAM snapshots differing:", differing)
    print("Hardware timing and broader sprite coverage remain pending.")


if __name__ == "__main__":
    main()
