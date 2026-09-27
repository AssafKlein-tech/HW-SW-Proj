"""CPU time of one versus_cpu() call, N repetitions per variant.

usage: python3 cputime.py <N> label=path [label=path ...]
The first variant is the baseline the speedups are relative to.
"""
import importlib.util
import statistics
import sys
import time


def load(path):
    spec = importlib.util.spec_from_file_location('go_variant', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def measure(path, n):
    mod = load(path)
    times = []
    for _ in range(n):
        t0 = time.process_time()
        r = mod.versus_cpu()
        times.append((time.process_time() - t0) * 1000.0)
        assert r == 5, r
    return times


n = int(sys.argv[1])
print('%d repetitions per variant, process CPU time, ms' % n)
print('%-12s %9s %8s %9s %9s %9s' % ('variant', 'mean', 'stdev', 'min', 'max', 'speedup'))
base = None
for arg in sys.argv[2:]:
    label, path = arg.split('=', 1)
    t = measure(path, n)
    mean = statistics.mean(t)
    if base is None:
        base = mean
    print('%-12s %9.1f %8.1f %9.1f %9.1f %8.3fx'
          % (label, mean, statistics.stdev(t), min(t), max(t), base / mean))
