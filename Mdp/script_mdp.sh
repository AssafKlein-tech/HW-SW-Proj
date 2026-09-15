#!/usr/bin/env bash
#
# script_mdp.sh — reproducible profiling pipeline for the pyperformance "mdp" benchmark.
# HW-SW course project (Technion 00460882).
#
# What it does, per run (baseline, and optimized once mdp_optimized.py exists):
#   1. Run the benchmark under pyperformance and save timing stats to JSON.
#   2. Record a perf FLAT profile (no call graph) -> clean, fully-resolved hot-function list.
#   3. Record a perf frame-pointer call-graph profile of the same run -> flame graph SVG
#      (parent frames are unreliable here, see note below; leaf/self-time is still accurate).
#   4. Run cProfile directly against Battle().evaluate() -> exact Python-level caller/callee
#      graph (who calls whom), immune to the native-unwinding problem entirely.
#   5. If an optimized version is present, also compare baseline vs optimized timing.
#
# IMPORTANT environment notes (confirmed empirically on this VM, do not "fix" these):
#   - This is a KVM guest whose virtual PMU does not deliver the sampling interrupt, so
#     `perf record -e cycles` silently records ZERO samples here even though `perf stat -e cycles`
#     works fine for plain counting. Every perf record below uses `-e cpu-clock` instead.
#   - `python3-dbg` is built with LTO, which drops frame pointers in parts of the interpreter.
#     perf's fp-based call-graph (`-g`) walks off into pymalloc-poisoned stack memory as a
#     result: ~98% of parent frames come back as "[unknown]" garbage addresses (self-time on
#     leaf frames is still correct). A `--call-graph dwarf` recording resolves this properly,
#     but dwarf post-processing (`perf report`/`perf script`) took 15+ minutes and never
#     finished on this VM's single vCPU for a normal run — NOT used here. The flat profile
#     (step 2) and cProfile (step 4) below are the reliable substitutes: flat perf gives
#     accurate hot-*function* rankings (no call graph needed since only self-time matters
#     there), and cProfile gives an exact Python-level call graph directly from the
#     interpreter, with no native unwinding involved at all.
#
# Usage: ./script_mdp.sh [--skip-baseline] [--skip-optimized] [--quick|--fast]
#
# Speed flags (forwarded to pyperf's own Runner, which both `pyperformance run --bench mdp`
# and a direct `python3-dbg mdp_optimized.py` invocation are built on — same flags work for
# both baseline and optimized):
#   (default)  20 processes x 3 values = 60 timed calls to evaluate(). ~14 min for mdp on
#              this VM. Statistically solid mean+-stdev. Use this for the numbers that go
#              in report_mdp.txt's Performance Comparison section.
#   --fast     pyperf's own `-f/--fast`: fewer processes/values. ~1-2 min. Good middle
#              ground: enough repeats to sanity-check a result isn't a fluke, still quick.
#   --quick    pyperf's own `--debug-single-value`: exactly 1 warmup + 1 timed call, no
#              cross-process repetition. ~10s for mdp. Use this while iterating on an
#              optimization for a fast go/no-go signal. The resulting JSON has no stdev and
#              is NOT valid for the final >=7% comparison -- rerun with the default before
#              reporting numbers.

set -euo pipefail
cd "$(dirname "$0")"

FLAMEGRAPH_DIR="/root/FlameGraph"
BENCH_MODULE="pyperformance"
PERF_FREQ=999

SKIP_BASELINE=0
SKIP_OPTIMIZED=0
SPEED_ARGS=()
SPEED_LABEL="default (20 processes x 3 values, ~14 min)"
for arg in "$@"; do
    case "$arg" in
        --skip-baseline) SKIP_BASELINE=1 ;;
        --skip-optimized) SKIP_OPTIMIZED=1 ;;
        --quick) SPEED_ARGS=(--debug-single-value); SPEED_LABEL="--quick (1 value, ~10s, NOT for final report)" ;;
        --fast) SPEED_ARGS=(-f); SPEED_LABEL="--fast (fewer processes/values, ~1-2 min)" ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done
echo "==> Speed mode: $SPEED_LABEL"

echo "==> Environment setup"
command -v python3-dbg >/dev/null || { echo "python3-dbg not found"; exit 1; }
python3-dbg -m pyperformance --version >/dev/null 2>&1 || { echo "pyperformance not installed for python3-dbg"; exit 1; }

if [ ! -x "$FLAMEGRAPH_DIR/flamegraph.pl" ]; then
    echo "==> Cloning FlameGraph tooling to $FLAMEGRAPH_DIR"
    git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FLAMEGRAPH_DIR"
fi

# Kernel symbols are restricted by default (kptr_restrict=1); this only affects whether
# kernel-side frames resolve to names vs "[unknown]" — harmless to relax, not required.
if [ "$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo 0)" != "0" ]; then
    echo 0 | sudo tee /proc/sys/kernel/kptr_restrict >/dev/null 2>&1 || true
fi

BASELINE_SRC="/usr/local/lib/python3.10/dist-packages/pyperformance/data-files/benchmarks/bm_mdp/run_benchmark.py"
OPTIMIZED_SRC="mdp_optimized.py"

profile_one() {
    # $1 = label (baseline|optimized), $2 = benchmark source file (for cProfile),
    # rest = command to run (array via "$@" from caller)
    local label="$1"; shift
    local bench_src="$1"; shift
    local json="mdp_${label}.json"
    local flatdata="perf_${label}_flat.data"
    local flatreport="perf_${label}_flat_report.txt"
    local perfdata="perf_${label}.data"
    local report="perf_${label}_report.txt"
    local flame="flamegraph_${label}.svg"
    local callers="profile_callers_${label}.txt"

    # Re-runs must actually overwrite: pyperformance and perf both refuse to touch an
    # existing output file by default.
    rm -f "$json" "$flatdata" "$perfdata"

    echo "==> [$label] pyperformance timing run -> $json"
    "$@" -o "$json"

    echo "==> [$label] perf record FLAT (cpu-clock, $PERF_FREQ Hz, no call graph) -> $flatdata"
    sudo perf record -F "$PERF_FREQ" -e cpu-clock -o "$flatdata" -- "$@"
    sudo perf report --stdio -i "$flatdata" --sort=overhead,symbol > "$flatreport"

    echo "==> [$label] perf record (cpu-clock, $PERF_FREQ Hz, frame-pointer call graph) -> $perfdata"
    sudo perf record -F "$PERF_FREQ" -g -e cpu-clock -o "$perfdata" -- "$@"

    echo "==> [$label] perf report --stdio -> $report"
    sudo perf report --stdio -i "$perfdata" > "$report"

    echo "==> [$label] flame graph -> $flame"
    sudo perf script -i "$perfdata" \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        | "$FLAMEGRAPH_DIR/flamegraph.pl" > "$flame"
    sudo chown "$(id -u):$(id -g)" "$flatdata" "$flatreport" "$perfdata" "$report" "$flame" "$json" 2>/dev/null || true

    echo "==> [$label] cProfile caller/callee graph -> $callers"
    python3-dbg profile_callers.py "$bench_src" "$callers"

    local samples flatsamples
    samples=$(grep -m1 '^# Samples' "$report" || echo "(not found)")
    flatsamples=$(grep -m1 '^# Samples' "$flatreport" || echo "(not found)")
    echo "==> [$label] done. flat: $flatsamples | call-graph: $samples"
}

if [ "$SKIP_BASELINE" -eq 0 ]; then
    profile_one baseline "$BASELINE_SRC" python3-dbg -m "$BENCH_MODULE" run --bench mdp "${SPEED_ARGS[@]}"
else
    echo "==> Skipping baseline (--skip-baseline)"
fi

if [ "$SKIP_OPTIMIZED" -eq 0 ]; then
    if [ -f "$OPTIMIZED_SRC" ]; then
        profile_one optimized "$OPTIMIZED_SRC" python3-dbg "$OPTIMIZED_SRC" "${SPEED_ARGS[@]}"
        if [ -f mdp_baseline.json ] && [ -f mdp_optimized.json ]; then
            echo "==> Comparing baseline vs optimized"
            python3-dbg -m pyperf compare_to mdp_baseline.json mdp_optimized.json | tee comparison.txt
        fi
    else
        echo "==> mdp_optimized.py not found yet — skipping optimized run/compare."
        echo "    (Create it, then re-run: ./script_mdp.sh --skip-baseline)"
    fi
else
    echo "==> Skipping optimized (--skip-optimized)"
fi

echo "==> All done. Outputs are in $(pwd)"
