# Copyright (c) 2026 Nakata Maho
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

"""ROM-free FM container and integer reference tests.

    python3 -I tests/test_fm.py
"""
import math
import struct
import sys
import unittest
from unittest.mock import patch
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import fmdata
import install_roms
import roms


def synthetic_prom():
    return bytes(round(7.5 + 7 * math.cos(2 * math.pi * (w + 1) * j / 32))
                 for w in range(8) for j in range(32))


class FMTests(unittest.TestCase):
    def setUp(self):
        self.voices = fmdata.quick_voices(synthetic_prom())

    def test_tables(self):
        self.assertEqual(sum(fmdata.SIN), 0)
        self.assertLessEqual(max(fmdata.SIN), 127)
        self.assertEqual(fmdata.AMPLITUDES[0], fmdata.FULL_SCALE)
        self.assertEqual(sorted(fmdata.AMPLITUDES, reverse=True),
                         list(fmdata.AMPLITUDES))

    def test_quick(self):
        self.assertTrue(fmdata.valid_voices(self.voices))
        self.assertEqual(self.voices, fmdata.quick_voices(synthetic_prom()))
        for wave in range(8):
            voice = self.voices[wave * 18:wave * 18 + 9]
            self.assertEqual(voice, self.voices[wave * 18 + 9:wave * 18 + 18])
            self.assertEqual(voice[0], 7)
            self.assertEqual(voice[1], wave + 1)
        self.assertTrue(fmdata.valid_voices(fmdata.quick_voices(bytes(256))))
        with self.assertRaises(ValueError):
            fmdata.quick_voices(bytes(255))

    def test_roundtrip(self):
        for method in (1, 2):
            data = fmdata.pack(self.voices, method)
            self.assertEqual(len(data), 164)
            self.assertEqual(fmdata.unpack(data), self.voices)

    def test_corruption(self):
        data = fmdata.pack(self.voices)
        for i in range(len(data)):
            bad = bytearray(data)
            bad[i] ^= 128
            with self.assertRaises(ValueError):
                fmdata.unpack(bytes(bad))
        for bad in (data[:-1], data + b"x", b"", bytes(164)):
            with self.assertRaises(ValueError):
                fmdata.unpack(bad)

    def test_preserved_dual_revision_loader(self):
        self.assertTrue(set(roms.VERSION_B) <= set(roms.ROMS))
        self.assertEqual(len(install_roms.VERSION_A), 4)

    def test_installer_safe_names(self):
        keys = install_roms.VERSION_B + install_roms.SHARED + [install_roms.WAVES]
        names = ["ROM1.BIN", "PK.COM", "AUTOEXEC.BAT", "FMVOICE.DAT",
                 "ROM3.BIN", "COMMAND.COM", "ROM1.BIN", "bad.name.long", "PK.COM"]
        entries = [(name, bytes([i + 1]) * size)
                   for i, (name, (size, crc)) in enumerate(zip(names, keys))]
        crc_by_id = {id(data): crc for (name, data), (size, crc) in zip(entries, keys)}
        with patch.object(install_roms, "candidates", return_value=iter(entries)), \
                patch.object(install_roms.zlib, "crc32", side_effect=lambda d: crc_by_id[id(d)]):
            found = install_roms.read_roms(Path("unused"))
        self.assertEqual(len(found), 9)
        self.assertFalse(set(found) & {"PK.COM", "AUTOEXEC.BAT", "FMVOICE.DAT", "COMMAND.COM"})
        for name in found:
            self.assertEqual(install_roms.dos_name(name, 0), name)

    def test_dll_extraction_validates_all_slices(self):
        import tempfile
        blob = bytearray(install_roms.DLL_ID[0])
        for i, (offset, (size, crc)) in enumerate(install_roms.DLL_PARTS):
            blob[offset:offset + size] = bytes([i + 1]) * size
        def fake_crc(data):
            if len(data) == len(blob):
                return install_roms.DLL_ID[1]
            i = data[0] - 1
            return install_roms.DLL_PARTS[i][1][1]
        with patch.object(install_roms.zlib, "crc32", side_effect=fake_crc):
            parts = install_roms.dll_candidates(bytes(blob))
            self.assertEqual(len(parts), 9)
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "Release_3.dll"
                path.write_bytes(blob)
                self.assertEqual(len(install_roms.read_roms(path)), 9)
            with patch.object(install_roms.zlib, "crc32", side_effect=lambda data:
                              install_roms.DLL_ID[1] if len(data) == len(blob) else 0):
                with self.assertRaises(ValueError):
                    install_roms.dll_candidates(bytes(blob))
        alternate = bytes(install_roms.DLL_IDS[1][0])
        calls = [install_roms.DLL_IDS[1][1]] + [crc for _, (_, crc) in install_roms.DLL_PARTS]
        with patch.object(install_roms.zlib, "crc32", side_effect=calls):
            self.assertEqual(len(install_roms.dll_candidates(alternate)), 9)
        for bad in (b"", bytes(len(blob)), bytes(len(blob) - 1), alternate):
            with self.assertRaises(ValueError):
                install_roms.dll_candidates(bad)

    def test_host_fit_uses_verified_wave_and_method_two(self):
        import fmfit
        prom = bytes(256)
        with patch.object(install_roms.zlib, "crc32", return_value=install_roms.WAVES[1]), \
                patch.object(fmfit, "fm_voices", return_value=self.voices) as fit:
            # Isolate fitting dispatch from the container's CRC tests above.
            with patch.object(fmdata, "pack", return_value=b"fitted") as pack:
                self.assertEqual(install_roms.fit_voices({"wave.bin": prom}), b"fitted")
                fit.assert_called_once_with(prom)
                pack.assert_called_once_with(self.voices, method=2)
        with self.assertRaises(ValueError):
            install_roms.fit_voices({})

    def test_register_ranges_even_with_correct_crc(self):
        for offset, value in ((0, 64), (1, 16), (2, 128)):
            bad = bytearray(fmdata.pack(self.voices))
            bad[20 + offset] = value
            struct.pack_into("<I", bad, 16, zlib.crc32(bad[20:]))
            with self.assertRaises(ValueError):
                fmdata.unpack(bad)
        with self.assertRaises(ValueError):
            fmdata.pack(self.voices, 3)


if __name__ == "__main__":
    unittest.main()
