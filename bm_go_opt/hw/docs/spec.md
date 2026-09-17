# `go_useful_accel` — specification

## 1. Function

`go_useful_accel` is a hardware shadow copy of the group/liberty structure of a
9x9 Go board (union-find over stones, per-group liberty counts, and an
incremental 63-bit Zobrist hash).  The host CPU keeps the authoritative board
and offloads the hot read-only predicate `Board.useful(pos, color)`; it also
mirrors every committed stone placement into the accelerator with a posted
`MOVE` so that the shadow state stays in step.

The normative behavioural reference is
`/root/Project_go/bm_go_hw/accel_model.py` (`GoUsefulAccel`).  The RTL
reproduces it bit-for-bit, including traversal order where results depend on it.

Geometry: 81 points, `pos = y*9 + x`, `pos in 0..80`.
Colours: `EMPTY=0`, `WHITE=1`, `BLACK=2` (2 bits).

## 2. Parameters (`go_useful_core`)

| name | type | default | legal | controls |
|---|---|---|---|---|
| `SIZE`   | int | 9   | 9 (see note) | board edge length |
| `NPTS`   | int | 81  | `SIZE*SIZE` | number of points |
| `POSW`   | int | 7   | `$clog2(NPTS)` | position width |
| `LEDGEW` | int | 9   | `$clog2(4*NPTS+1)` | liberty-count width |
| `ZW`     | int | 63  | 63 | Zobrist key / hash width |
| `ZAW`    | int | 9   | >= `$clog2(3*NPTS)` | `cmd_key_idx` port width (9 per register-map spec) |

The ZKEY RAM itself is addressed with `ZKAW = $clog2(3*NPTS)` = 8 bits; the
spare top bits of `cmd_key_idx` are explicitly discarded.  Illegal parameter
combinations are caught by an elaboration-time `$fatal` (the module's only
`initial` block, guarded by `` `ifndef SYNTHESIS ``).

Note: `SIZE` is a true parameter (the neighbour ROM, all array depths and all
derived widths follow it), but the *port* widths of the AXI register map are
frozen at the 9x9 values by the interface spec, so the wrapper is 9x9 only.

## 3. State

| array | entries | width | reset value |
|---|---|---|---|
| `color`  | 81 | 2 | `EMPTY` |
| `ref`    | 81 | 7 | `ref[i]=i` |
| `ledges` | 81 | 9 | 0 |
| `used`   | 81 | 1 | 0 |
| `temp_ledges` | 81 | 9 | 0 (scratch, USEFUL only) |
| `root_seen`   | 81 | 1 | 0 (scratch, cleared per USEFUL/MOVE) |
| `removed`     | 81 | 1 | 0 (scratch, cleared per USEFUL/MOVE) |
| `ZKEY`   | 243 | 63 | not reset (inferred block RAM, written by LOAD_KEY) |
| `hash`   | 1 | 63 | 0 |

`ledges[r]` is meaningful only at a root (`ref[r]==r`).  It counts
stone/empty adjacencies with multiplicity, bounded by `4*81 = 324`, hence 9 b.

`root_seen` / `removed` replace the software's `TIMESTAMP` epoch trick: clearing
81 flags is one cycle in hardware.

## 4. Interfaces

### 4.1 `go_useful_core` command port (synchronous, single clock `clk`)

| name | dir | width | description |
|---|---|---|---|
| `clk` | in | 1 | single clock domain, 100 MHz target |
| `rst_n` | in | 1 | **synchronous, active-low** reset |
| `cmd_valid` | in | 1 | command request |
| `cmd_ready` | out | 1 | core is idle and will accept this cycle |
| `cmd_op` | in | 4 | opcode, see 5. |
| `cmd_pos` | in | 7 | point 0..80 |
| `cmd_color` | in | 2 | colour to place / test |
| `cmd_key` | in | 63 | LOAD_KEY payload |
| `cmd_key_idx` | in | 9 | LOAD_KEY index = `sq*3 + color` |
| `busy` | out | 1 | `state != IDLE` |
| `done` | out | 1 | **1-cycle pulse**, op complete, results valid |
| `res_fast` | out | 1 | USEFUL took the fast path |
| `res_cond` | out | 1 | USEFUL predicate result |
| `res_hash` | out | 63 | USEFUL candidate hash (0 on the fast path) |
| `cur_hash` | out | 63 | committed board hash (valid whenever `!busy`) |

Protocol: transfer on `cmd_valid && cmd_ready`.  `cmd_ready` is `state==IDLE`
and is *not* combinationally dependent on `cmd_valid`.  Payload must be stable
while `cmd_valid && !cmd_ready`.  Results (`res_*`) are registered and hold
until the next `done`.

### 4.2 `go_useful_accel` AXI4-Lite slave (32-bit)

Standard AW/W/B/AR/R channels, `AWPROT`/`ARPROT` ignored, `WSTRB` ignored
(ASSUMPTION: all register writes are full 32-bit words), `RESP` always `OKAY`
(2'b00) — ASSUMPTION: no error response for unmapped addresses; reads of
unmapped addresses return 0, writes to them are dropped.

| offset | name | dir | fields |
|---|---|---|---|
| 0x00 | `CMD` | W | `[31:28]` op, `[8:7]` color, `[6:0]` pos — write starts the op |
| 0x04 | `STAT` | R | `[0]` busy, `[1]` done (sticky), `[2]` useful_cond, `[3]` fast_path |
| 0x08 | `RES_LO` | R | hash `[31:0]` |
| 0x0C | `RES_HI` | R | `[30:0]` hash `[62:32]`, `[31]` done (sticky) |
| 0x10 | `KEY_LO` | W | key `[31:0]` |
| 0x14 | `KEY_HI` | W | key `[62:32]` |
| 0x18 | `KEY_IDX` | W | `[8:0]` index; the write itself issues LOAD_KEY |

ASSUMPTION: writing `KEY_IDX` is what commits the key (the table says "writing
it with op=LOAD_KEY commits the key"); no separate `CMD` write is needed.  A
`CMD` write with op = LOAD_KEY also works and uses the last `KEY_IDX`.

ASSUMPTION: the sticky `done` bit is set by the core's `done` pulse and cleared
by (a) a read of `RES_LO` — "the result registers are read" — or (b) the start
of a new command.  This lets software poll `RES_HI[31]`, then read `RES_LO`,
which clears the flag.

ASSUMPTION: a write to `CMD`/`KEY_IDX` while the core is busy back-pressures the
AXI write channel (`BVALID` is withheld until the core accepts the command)
rather than being dropped.

## 5. Operations (`cmd_op`, `CMD[31:28]`)

| op | name | behaviour |
|---|---|---|
| 0 | NOP | 1 cycle, `done` pulse, no state change |
| 1 | RESET | clear `color`/`used`, `ref[i]=i`, `ledges=0`, then `hash = XOR(sq=0..80) ZKEY[sq*3+EMPTY]` (81-step sequential XOR) |
| 2 | MOVE(pos,color) | commit a stone; posted, no result is read back |
| 3 | USEFUL(pos,color) | offloaded predicate; **modifies no committed state** |
| 4 | LOAD_KEY | `ZKEY[cmd_key_idx] <= cmd_key` |

RESET does not clear `ZKEY`.

### 5.1 FIND

`find(p)`: `while (ref[p] != p) p = ref[p];`, one cycle per hop.
On the MOVE path only, a second walk path-compresses, mirroring
`accel_model.find(compress=True)` exactly:

```
p = start
while ref[p] != root:
    q = ref[p];  p = q;  ref[q] = root   # CPython's `p, ref[p] = ref[p], root`
```

(Python assigns the tuple targets left to right, so the *new* `p` is the one
repointed; the first node on the path keeps its parent.  This is a weak
compression — it never changes which node is the root, so it cannot change any
result, but it is replicated for fidelity.)
USEFUL uses the non-compressing form so that it mutates nothing.

### 5.2 USEFUL

1. Clear `root_seen`/`removed`; zero `empties/opps/weak_opps/neighs/weak_neighs`.
2. Fast path: if `!used[pos]` and any neighbour is `EMPTY`, return
   `{fast=1, cond=1, hash=0}`.
3. `h = hash ^ ZKEY[pos*3+color[pos]] ^ ZKEY[pos*3+color_in]`.
4. For each neighbour `n` in NEIGH_ROM order (`(-1,0),(1,0),(0,-1),(0,1)`
   filtered for edges):
   - `EMPTY` -> `empties++`;
   - else `r = find(n)`; if `!root_seen[r]` then `root_seen[r]=1`,
     `temp[r] = ledges[r]`, and `neighs++` (same colour) or `opps++`;
     then `temp[r]--`; if it reaches 0 then `weak_neighs++` / `weak_opps++`,
     and for an enemy group run the speculative capture flood-fill from `r`
     (DFS over same-root non-empty squares, marking `removed[]`, XOR-ing
     `ZKEY[s*3+color[s]] ^ ZKEY[s*3+EMPTY]` into `h`).
5. `cond = (empties!=0) | (weak_opps!=0) | ((neighs-weak_neighs)!=0 &&
   ((opps-weak_opps)!=0 || weak_neighs!=0))`.
6. Return `{fast=0, cond, h}`.

### 5.3 MOVE

```
hash ^= ZKEY[pos*3+color[pos]] ^ ZKEY[pos*3+color_in]
color[pos]=color_in; ref[pos]=pos; ledges[pos]=0; used[pos]=1; clear removed
for n in NEIGH[pos]:                       # colour re-read every iteration
    nc = color[n]
    if nc == EMPTY: ledges[pos]++
    else:
        r = find(n, compress=1)
        if nc == color_in:
            if ref[r] != pos: ledges[pos] += ledges[r]; ref[r] = pos
            ledges[pos] -= 1
        else:
            ledges[r] -= 1
            if ledges[r] == 0: remove_commit(n, r)
```
`remove_commit(sq, root)` (recursive in the model, explicit stack in RTL):
XOR `ZKEY[sq*3+color[sq]] ^ ZKEY[sq*3+EMPTY]` into `hash`, mark `removed[sq]`,
set `color[sq]=EMPTY`, then for each neighbour `n` with
`color[n]!=EMPTY && !removed[n]`: `r2=find(n,compress=1)`; if `r2==root`
recurse, else `ledges[r2]++`.

`ref[r] != pos` is equivalent to `r != pos` because `r` is a root; the RTL
implements the latter.

## 6. Micro-architecture

```
           cmd_* ──┐
                   v
            ┌──────────────┐   zkey_addr   ┌─────────────────┐
            │  sequencer   ├──────────────>│ ZKEY RAM        │
            │  FSM (24 st) │<──────────────┤ 243 x 63b       │
            │              │   zkey_q      │ (inferred BRAM, │
            │  + XOR-pair  │               │  reg'd read)    │
            │    sub-rtn   │               └─────────────────┘
            │  + FIND      │
            │    sub-rtn   │   ┌──────────────────────────────┐
            │  + DFS stack ├──>│ flop arrays                  │
            │    (81x7b)   │<──┤ color/ref/ledges/temp (81)   │
            └──┬────┬──────┘   │ used/root_seen/removed (81b) │
               │    │          └──────────────────────────────┘
               │    │          ┌──────────────┐
               │    └─────────>│ NEIGH ROM    │ 81 x 4 x {vld,pos}
               │               │ (elaborated) │ constant function
               v               └──────────────┘
        done/res_*/cur_hash
```

Everything is registered; the only combinational paths of note are the array
read muxes.  No pipelining, one operation in flight.

### 6.1 FSM

Sub-routines use a saved return-state register (`xp_ret`, `find_ret`).

| state | condition | next | action |
|---|---|---|---|
| `S_IDLE` | `cmd_valid`, op=NOP | `S_IDLE` | `done` |
| | op=RESET | `S_RST_CLR` | latch cmd |
| | op=MOVE | `S_M_START` | latch cmd |
| | op=USEFUL | `S_U_START` | latch cmd |
| | op=LOAD_KEY | `S_LDKEY` | latch cmd |
| `S_RST_CLR` | — | `S_RST_ADDR` | clear all arrays, `hash=0`, `sq=0` |
| `S_RST_ADDR` | — | `S_RST_ACC` | drive `zkey_addr = sq*3+EMPTY` |
| `S_RST_ACC` | `sq==80` | `S_IDLE` (`done`) | `hash ^= zkey_q` |
| | else | `S_RST_ADDR` | `hash ^= zkey_q`, `sq++` |
| `S_LDKEY` | — | `S_IDLE` (`done`) | `ZKEY[idx] <= key` |
| `S_XP_A` | — | `S_XP_B` | drive `zkey_addr = xp_a0` |
| `S_XP_B` | — | `S_XP_C` | drive `xp_a1`, `acc ^= zkey_q` |
| `S_XP_C` | — | `xp_ret` | `acc ^= zkey_q` |
| `S_FIND_WALK` | `ref[p]==p` && `!cmp` | `find_ret` | `root=p` |
| | `ref[p]==p` && `cmp` | `S_FIND_CMP` | `root=p`, `cp=start` |
| | else | `S_FIND_WALK` | `p = ref[p]` |
| `S_FIND_CMP` | `ref[cp]==root` | `find_ret` | — |
| | else | `S_FIND_CMP` | `q=ref[cp]; ref[q]=root; cp=q` |
| `S_U_START` | fast | `S_IDLE` (`done`) | `res={1,1,0}` |
| | else | `S_U_HINIT` | clear scratch+counters |
| `S_U_HINIT` | — | `S_XP_A`->`S_U_LOOP` | `h=hash`, set up key pair |
| `S_U_LOOP` | `k==4` | `S_IDLE` (`done`) | compute `cond`, `res={0,cond,h}` |
| | `!valid(k)` | `S_U_LOOP` | `k++` |
| | `color[n]==EMPTY` | `S_U_LOOP` | `empties++`, `k++` |
| | else | `S_FIND_WALK`->`S_U_FIND_DONE` | non-compressing find |
| `S_U_FIND_DONE` | `temp'!=0` | `S_U_LOOP` | update `root_seen/temp/neighs/opps`, `k++` |
| | `temp'==0`, friend | `S_U_LOOP` | `weak_neighs++`, `k++` |
| | `temp'==0`, enemy | `S_U_CAS_POP` | `weak_opps++`, push `r` |
| `S_U_CAS_POP` | `sp==0` | `S_U_LOOP` | `k++` |
| | else | `S_XP_A`->`S_U_CAS_NB` | pop `s`, `h ^= key pair`, `j=0` |
| `S_U_CAS_NB` | `j==4` | `S_U_CAS_POP` | — |
| | skip | `S_U_CAS_NB` | `j++` |
| | else | `S_FIND_WALK`->`S_U_CAS_FIND` | non-compressing find |
| `S_U_CAS_FIND` | root match | `S_U_CAS_NB` | push `n`, mark removed, `j++` |
| | else | `S_U_CAS_NB` | `j++` |
| `S_M_START` | — | `S_XP_A`->`S_M_INIT` | `hash ^= key pair` |
| `S_M_INIT` | — | `S_M_LOOP` | commit colour/ref/ledges/used, clear scratch |
| `S_M_LOOP` | `k==4` | `S_IDLE` (`done`) | — |
| | `!valid(k)` | `S_M_LOOP` | `k++` |
| | `color[n]==EMPTY` | `S_M_LOOP` | `ledges[pos]++`, `k++` |
| | else | `S_FIND_WALK`->`S_M_FIND_DONE` | compressing find |
| `S_M_FIND_DONE` | friend, `r!=pos` | `S_M_LOOP` | merge, `k++` |
| | friend, `r==pos` | `S_M_LOOP` | `ledges[pos]--`, `k++` |
| | enemy, `ledges[r]>1` | `S_M_LOOP` | `ledges[r]--`, `k++` |
| | enemy, `ledges[r]==1` | `S_M_RC_POP` | `ledges[r]=0`, push `n` |
| `S_M_RC_POP` | `sp==0` | `S_M_LOOP` | `k++` |
| | else | `S_XP_A`->`S_M_RC_NB` | pop `s`, `color[s]=EMPTY`, `hash ^= key pair` |
| `S_M_RC_NB` | `j==4` | `S_M_RC_POP` | — |
| | skip | `S_M_RC_NB` | `j++` |
| | else | `S_FIND_WALK`->`S_M_RC_FIND` | compressing find |
| `S_M_RC_FIND` | root match | `S_M_RC_NB` | push `n`, mark removed, `j++` |
| | else | `S_M_RC_NB` | `ledges[r2]++`, `j++` |

Outputs are Moore (registered): `done`, `res_*`, `cur_hash`.

### 6.2 DFS stack

Both flood fills mark a square `removed` at *push* time rather than at pop
time.  That is equivalent to the model (the marked set is the same connected
component, and both the hash XOR and the `ledges[r2]++` increments are
order-independent), and it bounds the stack at one entry per point: 81 x 7 b.

### 6.3 Critical path

The longest combinational path is in `S_M_FIND_DONE`:
`ledges[cur_pos] + ledges[find_root] - 1` — two 81:1 9-bit read muxes into a
9-bit adder.  Comparable paths are the chained `neigh_rom[pos][k] -> color[n]`
mux pair in `S_U_LOOP`/`S_M_LOOP` and the `ref[find_p]` mux in `S_FIND_WALK`.
At 100 MHz (10 ns) these are comfortable on any modern FPGA/ASIC process; no
timing analysis was run (no tools available here).

## 7. Corner cases

- USEFUL must not write `color`/`ref`/`ledges`/`used`/`hash` — enforced by
  construction (those arrays are only written from RESET/MOVE/LOAD_KEY states)
  and checked by the trace testbench, since any leak would desync `cur_hash`.
- A neighbour emptied by a capture earlier in the *same* MOVE reads back as
  `EMPTY` on a later neighbour iteration (the colour is re-read at the top of
  each iteration).
- Two neighbours of `pos` in the same enemy group: the group's `ledges` is
  decremented twice, the capture fires on the second.
- `ref[r] != pos` already-merged guard prevents `ledges[pos] += ledges[pos]`.
- `temp[r]` going "negative": Python reaches -1, the 9-bit counter wraps to 511;
  neither equals 0, so behaviour matches.
- Suicide / zero-liberty placements are the software's problem; the block
  simply reproduces the model.
- Reset during an operation: synchronous reset returns the FSM to `S_IDLE` and
  reinitialises all board state (but not `ZKEY`).
- `cmd_ready` deasserted for the whole operation; no command queue.

## 8. Assumptions

- ASSUMPTION: reset is synchronous, active low, and also initialises the board
  arrays (`ref[i]=i` etc.) so the block is usable before the first RESET op;
  `ZKEY` is left uninitialised (it is a RAM) and `hash` resets to 0.
- ASSUMPTION: `cmd_op` values outside 0..4 behave as NOP.
- ASSUMPTION: the AXI4-Lite details listed in 4.2 (WSTRB ignored, always OKAY,
  KEY_IDX write commits, sticky-done clearing rule).
- ASSUMPTION: only one outstanding AXI transaction is supported (no burst, no
  outstanding-read pipelining).
- ASSUMPTION: `res_hash` is 0 on the USEFUL fast path (the model returns 0).
