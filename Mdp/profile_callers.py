"""Resolve Python-level caller/callee relationships for the mdp benchmark.

perf's native call-graph is unusable here (see perf_baseline_report.txt: LTO in
python3-dbg drops frame pointers, so perf's fp-unwinder walks off into
pymalloc-poisoned memory --> ~98% "[unknown]" parent frames). cProfile instead
tracks Python call/return events directly from the interpreter, so it names
every caller and callee exactly, with zero dependency on native stack unwinding.

Usage: python3-dbg profile_callers.py <path-to-run_benchmark.py> <output.txt>
"""
import cProfile
import importlib.util
import pstats
import sys

bench_path = sys.argv[1]
out_path = sys.argv[2]

spec = importlib.util.spec_from_file_location("run_benchmark", bench_path)
run_benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_benchmark)

profiler = cProfile.Profile()
profiler.enable()
result = run_benchmark.Battle().evaluate(0.192)
profiler.disable()

assert abs(result - 0.89873589887) < 1e-6, f"correctness check failed: {result}"

with open(out_path, "w") as f:
    stats = pstats.Stats(profiler, stream=f)
    stats.sort_stats("cumulative")

    f.write("=" * 70 + "\n")
    f.write("TOP FUNCTIONS BY CUMULATIVE TIME\n")
    f.write("=" * 70 + "\n")
    stats.print_stats(25)

    f.write("\n" + "=" * 70 + "\n")
    f.write("WHO CALLS WHOM (callers of each hot function)\n")
    f.write("=" * 70 + "\n")
    stats.sort_stats("tottime")
    stats.print_callers(20)

    f.write("\n" + "=" * 70 + "\n")
    f.write("WHAT EACH HOT FUNCTION CALLS (callees)\n")
    f.write("=" * 70 + "\n")
    stats.print_callees(20)

print(f"OK result={result} -> wrote {out_path}")
