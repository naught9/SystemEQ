"""Runs AutoEq the way autoeq.app's /equalize endpoint does, for comparison with the Swift port.

Usage: run.py <AutoEq checkout> <source> <target> <max optimizer time in seconds, or "none"> [settings JSON]
The optional settings override autoeq.app's defaults: any keyword argument of FrequencyResponse.process,
plus "min_f" / "max_f" for the PEQ optimizer.
"""
import json, sys, copy
repo, source_path, target_path, max_time = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
settings = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
sys.path.insert(0, repo)
import numpy as np
from autoeq.frequency_response import FrequencyResponse
from autoeq.constants import PEQ_CONFIGS

def load(path):
    rows = []
    for line in open(path, encoding='utf-8'):
        parts = [p for p in line.replace('\t', ',').replace(';', ',').replace(' ', ',').split(',') if p]
        try:
            f, v = float(parts[0]), float(parts[1])
        except (ValueError, IndexError):
            continue
        if f > 0:
            rows.append((f, v))
    rows.sort()
    return FrequencyResponse(name=path, frequency=[r[0] for r in rows], raw=[r[1] for r in rows])

fr, target = load(source_path), load(target_path)
fs = 48000
process_args = dict(min_mean_error=True, fs=fs, max_gain=12.0, max_slope=18, window_size=0.08,
                    treble_window_size=2.0, treble_f_lower=6000.0, treble_f_upper=8000.0, treble_gain_k=1.0)
process_args.update({k: v for k, v in settings.items() if k not in ('min_f', 'max_f')})
fr.process(target=target, **process_args)
config = copy.deepcopy(PEQ_CONFIGS['8_PEAKING_WITH_SHELVES'])
for key in ('min_f', 'max_f'):
    if key in settings:
        config['optimizer'][key] = settings[key]
if max_time != 'none':
    config['optimizer']['max_time'] = float(max_time)
peqs = fr.optimize_parametric_eq([config], fs, max_time=None if max_time == 'none' else float(max_time))
peq = peqs[0]
peq.sort_filters()
print(json.dumps({
    'frequency': fr.frequency.tolist(), 'equalization': fr.equalization.tolist(),
    'preamp': -peq.max_gain - 0.1,
    'filters': [{'type': type(f).__name__, 'fc': f.fc, 'q': f.q, 'gain': f.gain} for f in peq.filters],
}))
