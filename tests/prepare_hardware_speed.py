"""Prepare private controlled disks for the reported hardware slowdown.

Clone the supplied fitted disk, keeping ROMs/voices/background features.
cache-ssg differs only by AUTOEXEC PK /S. cpu-fm changes only PK.COM's
sprite backend; cpu-ssg changes that backend and starts with /S.
No hardware speed or successful fix is implied by building these controls.
"""
import argparse
import hashlib
import struct
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_dos
import fmdata


def read_file(tool, disk, name):
    offset, exists = tool.find_entry(disk.root, tool.short_name(name))
    if not exists:
        raise ValueError(f"missing {name}")
    cluster = struct.unpack_from("<H", disk.root, offset + 26)[0]
    size = struct.unpack_from("<I", disk.root, offset + 28)[0]
    return b"".join(disk.read_cluster(c) for c in disk.cluster_chain(cluster))[:size]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disk", type=Path, default=Path("build/m12/fitted/pk-msdos4-dll-fm.d88"))
    ap.add_argument("--output", type=Path, default=Path("build/m12/hardware-speed"))
    args = ap.parse_args()
    tool = build_dos.load_disk_tool()
    original = args.disk.read_bytes()
    source = tool.PcEngineDisk(original, require_system_files=False)
    voices = read_file(tool, source, "FMVOICE.DAT")
    fmdata.unpack(voices)
    autoexec = read_file(tool, source, "AUTOEXEC.BAT")
    assert autoexec.count(b"\r\nPK\r\n") == 1
    outputs = [args.output / (name + ".d88") for name in ("cache-ssg", "cpu-fm", "cpu-ssg")]
    for output in outputs:
        if output.exists():
            raise SystemExit(f"refusing to replace {output}")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pk-speed-") as tmp:
        work = Path(tmp)
        cpu = build_dos.assemble(work, fm=True, maze_palette=True, scene_hold=True)
        for output in outputs:
            disk = tool.PcEngineDisk(original, require_system_files=False)
            if output.stem.startswith("cpu-"):
                payload = work / "PK.COM"
                payload.write_bytes(cpu)
                tool.add_file(disk, disk.root, payload)
            if output.stem.endswith("-ssg"):
                payload = work / "AUTOEXEC.BAT"
                payload.write_bytes(autoexec.replace(b"\r\nPK\r\n", b"\r\nPK /S\r\n"))
                tool.add_file(disk, disk.root, payload)
            disk.flush()
            assert read_file(tool, disk, "FMVOICE.DAT") == voices
            if output.stem == "cache-ssg":
                assert read_file(tool, disk, "PK.COM") == read_file(tool, source, "PK.COM")
            output.write_bytes(disk.image)
            print(hashlib.sha256(disk.image).hexdigest(), output.resolve())
    assert args.disk.read_bytes() == original
    print("Original disk unchanged. Controls are private ROM-containing disks.")


if __name__ == "__main__":
    main()
