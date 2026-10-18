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

"""FM voices for the WSG waveforms, fitted on a YM2203 model.

The WSG plays 32-sample, 4-bit waveforms, held for a 32nd of the period
each, so besides the waveform's own harmonics 1-15 its output has images
around harmonics 32 and 64 (31, 33, 30, 34, ...), weighted by the hold's
sinc. At low pitches those images are what makes the arcade bass and the
sound effects buzz. For each waveform two voices are fitted:

- LOW, for pitches below LOW_HIGH_HZ: the target is harmonics 1-48 with
  the images;
- HIGH: harmonics 1-16 without them (higher up the images would lie above
  the YM2203's 27.7 kHz Nyquist frequency and alias).

The model follows ymfm's 4-operator channel: operator k outputs
A_k sin(2 pi (MUL_k t + m_k)), A_k = 10^(-0.75 TL_k / 20); a modulator adds
4 x its output to m (in cycles; ymfm adds opout >> 1 to a 10-bit phase);
operator 1's feedback adds (o[n-1] + o[n-2]) x 2^FB / 128. The search
minimises a log-spectral distance (harmonic powers relative to the total,
in dB, floored at -50 dB), trying every algorithm and five feedback levels
from STARTS starting points each and descending over MUL and TL one operator
at a time. The carriers' TL is then shifted so that the voice's RMS level
matches the WSG waveform's (a WSG peak of 7.5 steps = one full-scale
carrier), but never so far that the voice's peak exceeds one full-scale
carrier (ymfm does not clip the YM2203's carrier sum below 32767; whether
the chip does is not known). Phase is not part of the distance: for a steady tone it is
hardly audible, and the YM2203 starts every operator at phase 0 on key-on,
so the fitted voice's waveform shape follows from the modulation.

Output: for each waveform (0-7) and range (LOW, HIGH), 9 bytes:
FB << 3 | ALG (register B0h), then MUL and TL of operators 1-4.

Run as a script to print the voices and their distances. The results are
derived from the ROM; they go onto the disk only (tools/build.py caches
them in build/, which git ignores).
"""

import math
import random
import sys
from multiprocessing import Pool

import numpy as np

VERSION = 1
WAVES = 8
SAMPLES = 32
N = 256                       # model samples per period
LOW_HIGH_HZ = 576           # 48 harmonics below the 27.7 kHz Nyquist frequency
LOW_HARMONICS = 48
HIGH_HARMONICS = 16
FLOOR_DB = -50.0
FB_LEVELS = (0, 3, 5, 6, 7)
STARTS = 6
VOICE_BYTES = 9
FM_VOICES_BYTES = WAVES * 2 * VOICE_BYTES

MULS = [0.5] + list(range(1, 16))       # MUL 0 is x0.5
# For operators 1-4: the operators modulating it; and the carriers.
ALGORITHMS = {
    0: ([[], [0], [1], [2]], [3]),
    1: ([[], [], [0, 1], [2]], [3]),
    2: ([[], [], [1], [0, 2]], [3]),
    3: ([[], [0], [], [1, 2]], [3]),
    4: ([[], [0], [], [2]], [1, 3]),
    5: ([[], [0], [0], [0]], [1, 2, 3]),
    6: ([[], [0], [], []], [1, 2, 3]),
    7: ([[], [], [], []], [0, 1, 2, 3]),
}
T = np.arange(2 * N) / N


def amplitude(tl: int) -> float:
    return 10 ** (-0.75 * tl / 20)


_op1_cache: dict = {}


def operator1(fb: int, mul: int, tl: int) -> np.ndarray:
    key = (fb, mul, tl)
    if key in _op1_cache:
        return _op1_cache[key]
    a = amplitude(tl)
    m = MULS[mul]
    if fb == 0:
        out = a * np.sin(2 * math.pi * m * T)
    else:
        out = np.zeros(2 * N)
        k = 2 ** fb / 128
        p1 = p2 = 0.0
        for i in range(2 * N):
            v = a * math.sin(2 * math.pi * (m * T[i] + (p1 + p2) * k))
            out[i] = v
            p2, p1 = p1, v
    _op1_cache[key] = out
    return out


def render(alg: int, fb: int, muls, tls) -> np.ndarray:
    """The last of two periods of the channel's output (N samples)."""
    modulators, carriers = ALGORITHMS[alg]
    outs = [operator1(fb, muls[0], tls[0]), None, None, None]
    for op in (1, 2, 3):
        mod = sum((outs[j] for j in modulators[op]), np.zeros(2 * N))
        outs[op] = amplitude(tls[op]) * np.sin(2 * math.pi * (MULS[muls[op]] * T + 4 * mod))
    return sum(outs[c] for c in carriers)[N:]


def spectrum(y: np.ndarray, harmonics: int) -> np.ndarray:
    return np.fft.rfft(y)[1:harmonics + 1] / (N / 2)


def target(samples, harmonics: int, images: bool) -> np.ndarray:
    """Complex amplitudes of harmonics 1..harmonics of the held waveform,
    in DAC steps."""
    s = np.array(samples, float)
    x = np.fft.fft(s - s.mean()) / (SAMPLES / 2)
    out = np.zeros(harmonics, complex)
    for n in range(1, harmonics + 1):
        k = n % SAMPLES
        if k == 0 or (not images and n >= SAMPLES // 2 + 1):
            continue
        hold = math.sin(math.pi * n / SAMPLES) / (math.pi * n / SAMPLES) if images else 1.0
        out[n - 1] = x[k] * hold * np.exp(-1j * math.pi * n / SAMPLES)
    return out


def levels_db(spec: np.ndarray) -> np.ndarray:
    p = np.abs(spec) ** 2
    p = p / max(p.sum(), 1e-30)
    return np.maximum(10 * np.log10(p + 1e-30), FLOOR_DB)


def distance(spec: np.ndarray, target_db: np.ndarray) -> float:
    weight = np.where(target_db > -30, 1.0, 0.3)
    return float(np.sum(weight * (levels_db(spec) - target_db) ** 2) / np.sum(weight))


def fit(job):
    """Fit one voice: job = (samples, harmonics, images, seed)."""
    samples, harmonics, images, seed = job
    goal = target(samples, harmonics, images)
    goal_db = levels_db(goal)
    rng = random.Random(seed)

    def cost(alg, fb, muls, tls):
        return distance(spectrum(render(alg, fb, muls, tls), harmonics), goal_db)

    best = (math.inf, None)
    for alg in range(8):
        for fb in FB_LEVELS:
            for _ in range(STARTS):
                muls = [rng.choice((1, 1, 2, 3, 4)) for _ in range(4)]
                tls = [rng.randint(0, 40) for _ in range(4)]
                cur = cost(alg, fb, muls, tls)
                improved = True
                while improved:
                    improved = False
                    for op in range(4):
                        for m in range(16):
                            if m != muls[op]:
                                trial = muls[:]
                                trial[op] = m
                                d = cost(alg, fb, trial, tls)
                                if d < cur - 1e-6:
                                    cur, muls, improved = d, trial, True
                        for step in (-16, -8, -4, -2, -1, 1, 2, 4, 8, 16):
                            if 0 <= tls[op] + step <= 127:
                                trial = tls[:]
                                trial[op] += step
                                d = cost(alg, fb, muls, trial)
                                if d < cur - 1e-6:
                                    cur, tls, improved = d, trial, True
                if cur < best[0]:
                    best = (cur, (alg, fb, muls[:], tls[:]))
    dist, (alg, fb, muls, tls) = best
    # Level: the RMS of the voice against the WSG waveform's, a WSG peak of
    # 7.5 steps being one full-scale carrier.
    want = math.sqrt(np.sum(np.abs(goal) ** 2) / 2) / 7.5
    y = render(alg, fb, muls, tls)
    have = math.sqrt(np.mean(y ** 2))
    shift = max(round(20 * math.log10(have / want) / 0.75),
                math.ceil(20 * math.log10(max(np.max(np.abs(y)), 1e-9)) / 0.75))
    carriers = ALGORITHMS[alg][1]
    shift = max(shift, -min(tls[c] for c in carriers))
    for c in carriers:
        tls[c] = min(127, tls[c] + shift)
    return dist, alg, fb, muls, tls


def jobs(prom: bytes):
    out = []
    for wave in range(WAVES):
        samples = [b & 0x0F for b in prom[wave * SAMPLES:(wave + 1) * SAMPLES]]
        out.append((samples, LOW_HARMONICS, True, wave))
        out.append((samples, HIGH_HARMONICS, False, wave))
    return out


def fm_voices(prom: bytes, report=None) -> bytes:
    """The voices (FM_VOICES_BYTES): waveform 0 LOW, 0 HIGH, 1 LOW, ..."""
    with Pool() as pool:
        results = pool.map(fit, jobs(prom))
    out = bytearray()
    for index, (dist, alg, fb, muls, tls) in enumerate(results):
        if report is not None:
            report(index // 2, "LOW" if index % 2 == 0 else "HIGH", dist, alg, fb, muls, tls)
        out.append(fb << 3 | alg)
        for mul, tl in zip(muls, tls):
            out += bytes((mul, tl))
    assert len(out) == FM_VOICES_BYTES
    return bytes(out)


if __name__ == "__main__":
    sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
    import gfx
    import patches
    prom = gfx.load(patches.DEFAULT_ZIP)["waves"]
    fm_voices(prom, lambda w, r, d, a, f, m, t:
              print(f"wave {w} {r:4}: distance {d:6.1f}  ALG {a} FB {f}  MUL {m}  TL {t}"))
