#!/usr/bin/env bash
#
# script_go.sh - profiling, measurement and verification pipeline for the
# pyperformance "go" benchmark.  Regenerates everything the report cites.
#
#   sw/results/
#     cprofile_baseline.txt, cprofile_optimized.txt   cProfile of one versus_cpu() call
#     flamegraph_baseline.svg, flamegraph_optimized.svg  py-spy flame graphs
#     collapsed_baseline.txt, collapsed_optimized.txt    the same samples as folded stacks
#     flamegraph_shares.txt        self and inclusive time per function (baseline)
#     cputime.txt                  runtime of baseline / opt 1 / opt 2 / both, REPS repetitions
#     verify.txt                   every variant checked bit-identical against the baseline
#   hw/results/
#     shadow_sync.txt              accelerator model vs Python board after every move
#     offload_budget.txt           time owned by find() and useful(), and the budget per call
#     rtl_sim.txt, axil_sim.txt    iverilog runs of the two testbenches, with cycle counts
#     mutation_test.txt            three planted RTL bugs, each must be rejected by the testbench
#     lint.txt                     verilator lint
#
# The flame graph is recorded with py-spy rather than perf: perf's frame-pointer
# unwinding through python3-dbg gives mostly "[unknown]" parents on this VM (see
# ../Mdp/script_mdp.sh), while py-spy samples the interpreter's own frame stack.
#
# usage: ./script_go.sh            REPS=15 by default
#        REPS=5 ./script_go.sh     quicker runtime table

set -euo pipefail
cd "$(dirname "$0")"

REPS=${REPS:-15}
SW=sw; HW=hw; R=$SW/results; HR=$HW/results
BASE=$SW/run_benchmark_baseline.py
FIND=$SW/run_benchmark_find_only.py
SLOTS=$SW/run_benchmark_slots_only.py
OPT=$SW/run_benchmark.py
HWB=$HW/sw_with_hw_interface/run_benchmark.py
mkdir -p "$R" "$HR"

echo "==> cProfile"
python3 $SW/cprofile_run.py $BASE > $R/cprofile_baseline.txt
python3 $SW/cprofile_run.py $OPT  > $R/cprofile_optimized.txt

echo "==> flame graphs (py-spy, 200 Hz, 30 iterations each)"
record() {   # $1 = format, $2 = output, $3 = benchmark source
    # py-spy occasionally loses the race with the exiting child; just retry.
    for attempt in 1 2 3; do
        py-spy record -r 200 -f "$1" -o "$2" -- python3 $SW/loop.py "$3" 30 && [ -s "$2" ] && return 0
        echo "    py-spy attempt $attempt failed, retrying"
    done
    return 1
}
if command -v py-spy >/dev/null; then
    for v in baseline:$BASE optimized:$OPT; do
        label=${v%%:*}; src=${v#*:}
        record flamegraph $R/flamegraph_$label.svg $src
        record raw        $R/collapsed_$label.txt  $src
    done
else
    echo "    py-spy not found, skipping"
fi

echo "==> runtime, $REPS repetitions"
python3 $SW/cputime.py $REPS baseline=$BASE find_only=$FIND slots_only=$SLOTS combined=$OPT | tee $R/cputime.txt

if [ -f $R/collapsed_baseline.txt ]; then
    base_ms=$(awk '$1=="baseline"{print $2}' $R/cputime.txt)
    python3 $SW/shares.py $R/collapsed_baseline.txt "$base_ms" > $R/flamegraph_shares.txt
fi

echo "==> verification: each variant against the baseline"
for v in $FIND $SLOTS $OPT $HWB; do python3 $SW/verify.py $BASE $v; done > $R/verify.txt
grep -E "VERIFIED|MISMATCH" $R/verify.txt

echo "==> hardware: operation trace, model checks"
python3 $HW/sw_with_hw_interface/gen_trace.py
python3 $HW/sw_with_hw_interface/check_shadow_sync.py > $HR/shadow_sync.txt
python3 $HW/sw_with_hw_interface/measure_offload_budget.py > $HR/offload_budget.txt

echo "==> hardware: RTL simulation"
if command -v iverilog >/dev/null; then
    ( cd $HW
      iverilog -g2012 -o tb_core tb/tb_go_useful_core.sv rtl/go_useful_core.sv
      vvp tb_core > results/rtl_sim.txt
      iverilog -g2012 -o tb_axil tb/tb_go_useful_accel.sv rtl/go_useful_accel.sv rtl/go_useful_core.sv
      vvp tb_axil > results/axil_sim.txt
      rm -f tb_core tb_axil )
    grep -E "PASS|FAIL" $HR/rtl_sim.txt $HR/axil_sim.txt
    $HW/mutation_test.sh > $HR/mutation_test.txt
    tail -1 $HR/mutation_test.txt
else
    echo "    iverilog not found, skipping"
fi
if command -v verilator >/dev/null; then
    ( cd $HW
      verilator --lint-only -Wall -Wno-DECLFILENAME rtl/go_useful_core.sv --top-module go_useful_core
      verilator --lint-only -Wall -Wno-DECLFILENAME rtl/go_useful_accel.sv rtl/go_useful_core.sv --top-module go_useful_accel
    ) > $HR/lint.txt 2>&1 && echo "    lint clean" || echo "    lint reported warnings, see $HR/lint.txt"
fi

echo "==> done, outputs in $R and $HR"
