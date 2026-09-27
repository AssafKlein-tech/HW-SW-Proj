"""cProfile one versus_cpu() call and print the hot functions.

usage: python3 cprofile_run.py <run_benchmark.py>
"""
import cProfile
import importlib.util
import pstats
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location('go_variant', path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

pr = cProfile.Profile()
pr.enable()
result = mod.versus_cpu()
pr.disable()
print('result:', result)

st = pstats.Stats(pr)
st.strip_dirs().sort_stats('tottime').print_stats(20)

# Same numbers as a share of the total profiled time.  ncalls is shown as
# total/primitive when a function recurses.
total = st.total_tt
rows = sorted(st.stats.items(), key=lambda kv: kv[1][2], reverse=True)[:8]
print('share of total profiled time (%.3f s), top 8 by self time' % total)
print('%-24s %16s %8s %8s' % ('function', 'ncalls', 'self', 'cum'))
for (fname, line, name), (cc, nc, tt, ct, callers) in rows:
    calls = '%d/%d' % (nc, cc) if nc != cc else str(nc)
    print('%-24s %16s %7.1f%% %7.1f%%' % (name, calls, 100 * tt / total, 100 * ct / total))
