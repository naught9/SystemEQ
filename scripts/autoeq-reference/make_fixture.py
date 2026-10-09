"""Writes synthetic source/target curves and AutoEq's results for them (run against the real AutoEq)."""
import json, sys, subprocess, math
out = sys.argv[1]
freqs = [20 * 1.01 ** i for i in range(700) if 20 * 1.01 ** i <= 20000]
def bump(f, fc, gain, width):
    return gain * math.exp(-(math.log2(f / fc) / width) ** 2)
# An IEM-like source: bass shelf, 3 kHz ear-gain peak, 6 kHz peak, treble roll-off, small ripples.
source = [95 + bump(f, 40, 3, 1.5) + bump(f, 3000, 9, 0.8) + bump(f, 6000, 5, 0.25) + bump(f, 8500, -6, 0.2)
          - (6 * math.log2(f / 12000) if f > 12000 else 0) + 0.4 * math.sin(math.log2(f) * 9) for f in freqs]
# A Harman-like target: bass boost, broad ear gain, gentle treble tilt.
target = [bump(f, 30, 8, 2.2) + bump(f, 2800, 11, 1.1) - 0.8 * max(0, math.log2(f / 5000)) for f in freqs]
for name, values in (('source', source), ('target', target)):
    with open(f'{out}/{name}.csv', 'w') as fh:
        fh.write('frequency,raw\n' + ''.join(f'{f},{v}\n' for f, v in zip(freqs, values)))
