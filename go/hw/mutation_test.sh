#!/usr/bin/env bash
# Checks that the testbench can actually fail: three single-line bugs are
# planted in a copy of the core, and each copy must be rejected by the trace
# replay.  Only the first 40000 operations are replayed per mutant.
set -uo pipefail
cd "$(dirname "$0")"

mutants=(
  "empties never counted|s/empties <= empties + CNTW'(1);/empties <= empties;/"
  "weak_opps never counted|s/weak_opps *<= *weak_opps + CNTW'(1);/weak_opps <= weak_opps;/"
  "weak_opps dropped from cond|s/(weak_opps != '0) ||//"
)
caught=0
for m in "${mutants[@]}"; do
    name=${m%%|*}; expr=${m#*|}
    sed "$expr" rtl/go_useful_core.sv > mutant.sv
    if cmp -s rtl/go_useful_core.sv mutant.sv; then echo "$name: pattern not found"; continue; fi
    iverilog -g2012 -o tb_mut tb/tb_go_useful_core.sv mutant.sv 2>/dev/null
    if vvp tb_mut +maxops=40000 2>&1 | grep -q "PASS - all"; then
        echo "$name: NOT caught"
    else
        echo "$name: caught"; caught=$((caught+1))
    fi
done
rm -f mutant.sv tb_mut
echo "$caught of ${#mutants[@]} planted bugs caught"
