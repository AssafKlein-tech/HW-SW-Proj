# `go_useful_accel` RTL

Hardware shadow copy of a 9x9 Go board's group/liberty structure (union-find +
liberty counts + incremental 63-bit Zobrist hash), used to offload
`Board.useful(pos, color)` from CPython.  Bit-exact with the golden model
`bm_go_hw/accel_model.py`.

| file | contents |
|---|---|
| `rtl/go_useful_core.sv`  | the engine: sequencer FSM, board flop arrays, ZKEY block RAM, elaborated neighbour ROM |
| `rtl/go_useful_accel.sv` | AXI4-Lite (32-bit) slave wrapper and register map |
| `tb/tb_go_useful_core.sv`  | replays `model/ops_trace.txt` (81,747 ops) and checks every result |
| `tb/tb_go_useful_accel.sv` | AXI4-Lite smoke test (register map + 400 trace ops over the bus) |
| `docs/SPEC.md` | full specification, micro-architecture, FSM table, assumptions |
| `model/gen_small_trace.py` | generates mini traces for non-9x9 boards from the golden model (parameterisation testing) |

## Measured cycle counts (from simulation, full 81,747-op trace)

100 MHz clock, 1 op in flight, measured from command accept to the `done` pulse.

| op class | count | min | mean | max |
|---|---|---|---|---|
| `LOAD_KEY`    |   486 |   2 |   2.00 |   2 |
| `RESET`       |   202 | 164 | 164.00 | 164 |
| `MOVE`        | 21401 |  11 |  28.41 | 655 |
| `USEFUL` fast | 28199 |   2 |   2.00 |   2 |
| `USEFUL` full | 31459 |  11 |  29.40 | 553 |
| `USEFUL` all  | 59658 |   2 |  16.45 | 553 |

Latency tail:

| op class | >50 cy | >100 cy | >200 cy | >300 cy |
|---|---|---|---|---|
| `USEFUL` full (31459) | 1453 | 467 | 107 | 31 |
| `MOVE` (21401)        | 2341 | 705 | 159 |  54 |

Total: 1,705,080 cycles for the whole trace = 17.05 ms at 100 MHz.

### Against the 3 us budget

Mean `USEFUL` = 16.45 cycles = **0.165 us**, i.e. **18x** inside the 3 us
budget.  47.3% of calls take the 2-cycle fast path (0.02 us).
The tail is dominated by large speculative captures: 31 of 59,658 `USEFUL`
calls (0.05%) exceed 300 cycles (3 us), and the single worst call is 553 cycles
(5.53 us).  Each stone in a speculatively captured group costs ~7 cycles, of
which 3 are the two serialised ZKEY reads for its `key[color] ^ key[EMPTY]`
pair.  If the tail ever matters, using a dual-port (or 2-word-wide) ZKEY RAM
would fetch both keys in one cycle and cut the flood-fill cost by ~40%; nothing
else in the design would change.

`RESET` is a fixed 164 cycles (81 sequential ZKEY reads, 2 cycles each) and
happens 202 times in the trace — 0.2% of the total cycles.

## Reproduce

```sh
cd /root/Project_go/hw
iverilog -g2012 -o /tmp/tb_core tb/tb_go_useful_core.sv rtl/go_useful_core.sv
vvp /tmp/tb_core                       # full 81,747-op trace, ~18 s

iverilog -g2012 -o /tmp/tb_axil tb/tb_go_useful_accel.sv \
         rtl/go_useful_accel.sv rtl/go_useful_core.sv
vvp /tmp/tb_axil

verilator --lint-only -Wall -Wno-DECLFILENAME rtl/go_useful_core.sv  --top-module go_useful_core
verilator --lint-only -Wall -Wno-DECLFILENAME rtl/go_useful_accel.sv rtl/go_useful_core.sv \
         --top-module go_useful_accel
```

Useful plusargs for `tb_go_useful_core`: `+trace=<file>`, `+maxops=<n>`, `+vcd`.

Non-default board sizes (proves the parameterisation):

```sh
python3 model/gen_small_trace.py 5 /tmp/t5.txt 1 600      # SIZE NPTS-out seed moves
iverilog -g2012 -DTB_SIZE=5 -o /tmp/tb5 tb/tb_go_useful_core.sv rtl/go_useful_core.sv
vvp /tmp/tb5 +trace=/tmp/t5.txt
```

Verified at `SIZE` = 2, 5, 9 and 19.
