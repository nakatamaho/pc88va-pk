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

"""ROM-free tables, integer quick voices and the FMVOICE.DAT container.

The quick method uses the four strongest harmonics (1..15), algorithm 7,
no feedback. Both pitch ranges use the same voice. It is not the fitted
FM model in fmfit.py. All tables depend only on mathematics, not on ROMs.
"""

import math
import struct
import zlib

WAVE_CRC = 0xA9CC86BF
VOICE_BYTES = 144
HEADER = struct.Struct("<4sHHIHHI")
SIN = tuple(round(127 * math.sin(2 * math.pi * n / 32)) for n in range(32))
FULL_SCALE = 15240  # 32/2 * 7.5 DAC steps * 127
AMPLITUDES = tuple(round(FULL_SCALE * 10 ** (-0.75 * tl / 20)) for tl in range(128))


def valid_voices(data: bytes) -> bool:
    return (len(data) == VOICE_BYTES and all(
        data[i] <= 63 and all(data[i + j] <= 15 and data[i + j + 1] <= 127
                             for j in (1, 3, 5, 7))
        for i in range(0, VOICE_BYTES, 9)))


def pack(data: bytes, method: int = 1) -> bytes:
    if method not in (1, 2) or not valid_voices(data):
        raise ValueError("invalid FM voices")
    return HEADER.pack(b"PKFM", 1, method, WAVE_CRC, VOICE_BYTES, 0,
                       zlib.crc32(data)) + data


def unpack(file: bytes) -> bytes:
    if len(file) != HEADER.size + VOICE_BYTES:
        raise ValueError("invalid FMVOICE.DAT length")
    magic, version, method, wave, size, reserved, crc = HEADER.unpack_from(file)
    data = file[HEADER.size:]
    if ((magic, version, wave, size, reserved) !=
            (b"PKFM", 1, WAVE_CRC, VOICE_BYTES, 0) or method not in (1, 2)
            or zlib.crc32(data) != crc or not valid_voices(data)):
        raise ValueError("invalid FMVOICE.DAT")
    return data


def quick_voices(prom: bytes) -> bytes:
    """Bit-exact reference for src/dos/fm.asm; any 256-byte input allowed."""
    if len(prom) != 256:
        raise ValueError("wave PROM must be 256 bytes")
    out = bytearray()
    for wave in range(8):
        samples = [b & 15 for b in prom[wave * 32:wave * 32 + 32]]
        harmonics = []
        for k in range(1, 16):
            real = sum((s - 8) * SIN[(j * k + 8) & 31] for j, s in enumerate(samples))
            imag = sum((s - 8) * SIN[(j * k) & 31] for j, s in enumerate(samples))
            harmonics.append((math.isqrt(real * real + imag * imag), k))
        strongest = sorted(harmonics, key=lambda a: (-a[0], a[1]))[:4]
        total = sum(a for a, _ in strongest)
        voice = bytearray((7,))
        for amplitude, harmonic in strongest:
            if total > FULL_SCALE:
                amplitude = amplitude * FULL_SCALE // total
            tl = min(range(128), key=lambda t: abs(AMPLITUDES[t] - amplitude))
            voice.extend((harmonic, tl))
        out.extend(voice * 2)
    return bytes(out)


def nasm_tables() -> str:
    return ("; Mathematical tables only: no ROM input.\n"
            + "fm_sine dw " + ", ".join(map(str, SIN)) + "\n"
            + "fm_amplitudes dw " + ", ".join(map(str, AMPLITUDES)) + "\n")
