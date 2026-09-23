# HW-SW-Proj

Final project for the Technion HW-SW course (00460882) — *Benchmark Optimization,
Analysis, and Hardware Acceleration Proposal*. Per the assignment, we picked two
pyperformance benchmarks and, for each, profiled it with `perf` + flame graphs,
optimized it, measured the speedup, and (where completed) proposed a hardware
accelerator for a hot component.

- **`Mdp/`** — the `mdp` benchmark (value-iteration MDP solver). Software profiling
  and optimization are complete.
- **`go/`** — the `go` benchmark (Monte-Carlo Go engine). Software
  optimization and a hardware accelerator proposal (with RTL) are both complete.

 `Final Report.docx` is the submitted writeup
covering both benchmarks.

## Repository structure

```
Mdp/
  report_mdp.txt              Full report: overview, analysis, optimizations,
                               performance comparison, conclusion (HW section pending)
  prompt.txt                  AI-tool prompt disclosure for this benchmark
  script_mdp.sh                Reproduces the whole pipeline end to end (see below)
  mdp_baseline.json / mdp_fraction_optimized.json / mdp_optimized.json
                               pyperf timing results: baseline, +Fraction->float,
                               +id-indexed lists (final)
  mdp_fraction_optimized.py / mdp_optimized.py
                               modified benchmark source for each optimization stage
  perf_*_report.txt, perf_*_flat_report.txt
                               perf call-graph and flat (self-time) reports per stage
  flamegraph_*.svg            flame graphs per stage
  profile_callers*.py / profile_callers_*.txt
                               cProfile-based caller/callee breakdown per stage
                               (cross-checks the perf reports; immune to VM jitter)
  comparison*.txt              `pyperf compare_to` output per stage
  run_*.log, regen_baseline.log
                               raw console logs from the pipeline runs

go/
  sw/                          Baseline benchmark and the software-optimized version,
                               plus software_optimization_summary.txt
  hw/                          Hardware accelerator proposal:
    docs/spec.md               Accelerator specification
    rtl/*.sv                   SystemVerilog implementation
    sw_with_hw_interface/       Reference SW model of the HW/SW interface
    accelerator_block_diagram.png
    hardware_accelerator_summary.txt
```

## Requirements

- `python3-dbg` (CPython debug build — needed for symbol resolution in `perf`
  and required by `pyperformance`)
- `pyperformance` / `pyperf` (`pip install pyperformance`)
- Linux `perf`
- [FlameGraph](https://github.com/brendangregg/FlameGraph) tools
  (`stackcollapse-perf.pl`, `flamegraph.pl`) on `PATH`, or cloned locally —
  `script_mdp.sh` will clone them automatically if missing

**Environment note:** on a KVM guest VM, `perf record`'s default hardware
`cycles` event can silently capture zero samples (the hypervisor doesn't
deliver the PMU sampling interrupt). All profiling here uses the software
`cpu-clock` event (`-e cpu-clock`) instead, which works correctly under KVM.

## Running the mdp benchmark pipeline

```bash
cd Mdp
./script_mdp.sh
```

This regenerates, for each stage (baseline, Fraction-only, final optimized):
a pyperf timing run, a flat and a call-graph `perf` profile, a flame graph SVG,
and a cProfile breakdown, then prints the `pyperf compare_to` speedup. Useful
flags:

- `--quick` — fewer pyperf samples, for a fast sanity check
- `--fast` — skip the slower call-graph `perf` pass
- `--skip-baseline` / `--skip-optimized` — re-run only part of the pipeline

To run a single stage directly instead of the full pipeline:

```bash
python3-dbg -m pyperformance run --bench mdp -o mdp_baseline.json   # baseline
python3-dbg mdp_optimized.py -o mdp_optimized.json                  # optimized
pyperf compare_to mdp_baseline.json mdp_optimized.json
```

## Running the go benchmark

```bash
python3-dbg go/sw/run_benchmark.py                       # baseline / optimized SW
python3 go/hw/sw_with_hw_interface/run_benchmark.py       # with HW-interface model
```

See `go/sw/software_optimization_summary.txt` and
`go/hw/hardware_accelerator_summary.txt` for the detailed analysis,
measured numbers, and the hardware accelerator design (spec in
`go/hw/docs/spec.md`, RTL in `go/hw/rtl/`).

## AI tool usage

Each benchmark's `prompt.txt` documents the AI prompts that materially shaped
the work, per the assignment's AI-tools disclosure policy.
