// ---------------------------------------------------------------------------
// go_useful_core.sv
//
// Shadow copy of a 9x9 Go board's group/liberty structure: union-find over
// stones, per-group liberty counts and an incremental 63-bit Zobrist hash.
// Executes NOP / RESET / MOVE / USEFUL / LOAD_KEY from a simple synchronous
// command port.  Bit-exact with bm_go_hw/accel_model.py (the golden model).
//
// Parameters
//   SIZE   board edge (9).  NPTS/POSW/LEDGEW are derived from it.
//   ZW     Zobrist key and hash width (63).
//   ZAW    ZKEY address width (9; only 3*NPTS = 243 entries exist).
//
// Key assumptions (see docs/SPEC.md for the full list)
//   * reset is SYNCHRONOUS, ACTIVE LOW, and initialises the board arrays
//     (ref[i]=i, everything else zero).  The ZKEY RAM is not reset.
//   * USEFUL commits nothing: color/ref/ledges/used/hash are written only from
//     the RESET, MOVE and LOAD_KEY states.
//   * res_hash is driven to 0 whenever res_fast is 1 (the model returns 0 for
//     the fast path; the trace records 0 there).
//   * cmd_op outside 0..4 behaves as NOP.
//   * one operation in flight; cmd_ready == (state == S_IDLE).
//
// CRITICAL PATH (100 MHz target, no timing analysis was run here):
//   the longest combinational path is in S_M_FIND_DONE,
//       ledges[cur_pos] + ledges[find_root] - 1
//   i.e. two 81:1 9-bit read muxes feeding a 9-bit adder and the array write
//   decoder.  Runners-up: the chained neigh_rom[pos][k] -> color[n] mux pair in
//   S_U_LOOP/S_M_LOOP, and the ref[find_p] mux that closes the FIND hop loop.
//   All are flat mux+add structures with no arithmetic depth; 10 ns is easy.
// ---------------------------------------------------------------------------
`default_nettype none

module go_useful_core #(
    parameter int SIZE   = 9,                      // board edge
    parameter int NPTS   = SIZE * SIZE,            // 81 points
    parameter int POSW   = $clog2(NPTS),           // 7
    parameter int LEDGEW = $clog2(4 * NPTS + 1),   // 9
    parameter int ZW     = 63,                     // Zobrist width
    parameter int ZAW    = 9                       // ZKEY address width
) (
    input  wire                clk,          // single clock domain
    input  wire                rst_n,        // synchronous, active low

    // command port ---------------------------------------------------------
    input  wire                cmd_valid,    // command request
    output wire                cmd_ready,    // core idle, accepts this cycle
    input  wire [3:0]          cmd_op,       // opcode, see OP_* below
    input  wire [POSW-1:0]     cmd_pos,      // point 0..80
    input  wire [1:0]          cmd_color,    // EMPTY/WHITE/BLACK
    input  wire [ZW-1:0]       cmd_key,      // LOAD_KEY payload
    input  wire [ZAW-1:0]      cmd_key_idx,  // LOAD_KEY index = sq*3 + color

    // results --------------------------------------------------------------
    output wire                busy,         // state != IDLE
    output logic               done,         // 1-cycle completion pulse
    output logic               res_fast,     // USEFUL took the fast path
    output logic               res_cond,     // USEFUL predicate result
    output logic [ZW-1:0]      res_hash,     // USEFUL candidate hash (0 if fast)
    output logic [ZW-1:0]      cur_hash      // committed board hash
);

  // ---------------------------------------------------------------- constants
  // Colours: EMPTY=0, WHITE=1, BLACK=2.  Only EMPTY is compared against, the
  // stone colours travel through as opaque 2-bit values.
  localparam logic [1:0] C_EMPTY = 2'd0;

  localparam logic [3:0] OP_NOP      = 4'd0;
  localparam logic [3:0] OP_RESET    = 4'd1;
  localparam logic [3:0] OP_MOVE     = 4'd2;
  localparam logic [3:0] OP_USEFUL   = 4'd3;
  localparam logic [3:0] OP_LOAD_KEY = 4'd4;

  localparam int ZKAW = $clog2(3 * NPTS);  // real ZKEY RAM address width (8)
  localparam int NDIR = 4;                 // up to 4 neighbours per point
  localparam int CNTW = 3;                 // 0..4 neighbour counters
  localparam int SPW  = POSW + 1;          // DFS stack pointer, 0..NPTS

  // ------------------------------------------- elaboration-time parameter checks
`ifndef SYNTHESIS
  initial begin
    if (NPTS != SIZE * SIZE)
      $fatal(1, "go_useful_core: NPTS (%0d) must equal SIZE*SIZE (%0d)",
             NPTS, SIZE * SIZE);
    if (SIZE < 2)
      $fatal(1, "go_useful_core: SIZE (%0d) must be at least 2", SIZE);
    if (POSW < $clog2(NPTS))
      $fatal(1, "go_useful_core: POSW (%0d) too narrow for %0d points", POSW, NPTS);
    if (LEDGEW < $clog2(4 * NPTS + 1))
      $fatal(1, "go_useful_core: LEDGEW (%0d) too narrow for %0d liberties",
             LEDGEW, 4 * NPTS);
    if (ZAW < ZKAW)
      $fatal(1, "go_useful_core: ZAW (%0d) too narrow for %0d ZKEY entries",
             ZAW, 3 * NPTS);
    if (ZW < 2)
      $fatal(1, "go_useful_core: ZW (%0d) must be at least 2", ZW);
  end
`endif

  // cmd_key_idx bits above the real ZKEY depth are intentionally ignored
  generate
    if (ZAW > ZKAW) begin : g_keyidx_unused
      wire _unused_key_idx_hi = &{1'b0, cmd_key_idx[ZAW-1:ZKAW]};
    end
  endgenerate

  // -------------------------------------------------- NEIGH ROM (elaborated)
  // Neighbour order is the model's: (-1,0), (1,0), (0,-1), (0,1), compacted by
  // dropping off-board directions.  ledges accumulation on the MOVE path is
  // order sensitive, so this order is normative.
  // Entry format: {valid, pos}.
  function automatic logic [POSW:0] neigh_entry(input int p, input int k);
    int x, y, d, nx, ny, dx, dy, cnt;
    begin
      x   = p % SIZE;
      y   = p / SIZE;
      cnt = 0;
      neigh_entry = {1'b0, {POSW{1'b0}}};
      for (d = 0; d < NDIR; d++) begin
        case (d)
          0:       begin dx = -1; dy =  0; end
          1:       begin dx =  1; dy =  0; end
          2:       begin dx =  0; dy = -1; end
          default: begin dx =  0; dy =  1; end
        endcase
        nx = x + dx;
        ny = y + dy;
        if (nx >= 0 && nx < SIZE && ny >= 0 && ny < SIZE) begin
          if (cnt == k) neigh_entry = {1'b1, POSW'(ny * SIZE + nx)};
          cnt = cnt + 1;
        end
      end
    end
  endfunction

  logic [POSW:0] neigh_rom [0:NPTS-1][0:NDIR-1];
  generate
    for (genvar gp = 0; gp < NPTS; gp++) begin : g_nrow
      for (genvar gk = 0; gk < NDIR; gk++) begin : g_ncol
        assign neigh_rom[gp][gk] = neigh_entry(gp, gk);
      end
    end
  endgenerate

  // ZKEY index helper: sq*3 + color
  function automatic logic [ZKAW-1:0] zk_idx(input logic [POSW-1:0] p,
                                             input logic [1:0]      c);
    zk_idx = (ZKAW'(p) * ZKAW'(3)) + ZKAW'(c);
  endfunction

  // ------------------------------------------------------------ board state
  logic [1:0]        color_arr  [0:NPTS-1];
  logic [POSW-1:0]   ref_arr    [0:NPTS-1];
  logic [LEDGEW-1:0] ledges_arr [0:NPTS-1];
  logic [LEDGEW-1:0] temp_arr   [0:NPTS-1];   // scratch, USEFUL only
  logic [NPTS-1:0]   used;
  logic [NPTS-1:0]   root_seen;               // scratch, per op
  logic [NPTS-1:0]   removed;                 // scratch, per op
  logic [ZW-1:0]     hash;

  // --------------------------------------------------------------- ZKEY RAM
  logic [ZW-1:0]   zkey_mem [0:3*NPTS-1];  // inferred block RAM
  logic [ZKAW-1:0] zkey_addr;
  logic [ZW-1:0]   zkey_q;
  logic            zkey_we;

  // ------------------------------------------------------------------ states
  typedef enum logic [4:0] {
    S_IDLE,
    S_RST_CLR, S_RST_ADDR, S_RST_ACC,
    S_LDKEY,
    S_XP_A, S_XP_B, S_XP_C,               // XOR-pair sub-routine
    S_FIND_WALK, S_FIND_CMP,              // FIND sub-routine
    S_U_START, S_U_HINIT, S_U_LOOP, S_U_FIND_DONE,
    S_U_CAS_POP, S_U_CAS_NB, S_U_CAS_FIND,
    S_M_START, S_M_INIT, S_M_LOOP, S_M_FIND_DONE,
    S_M_RC_POP, S_M_RC_NB, S_M_RC_FIND
  } state_e;

  state_e state, xp_ret, find_ret;

  // ------------------------------------------------------- working registers
  logic [POSW-1:0] cur_pos;
  logic [1:0]      cur_color;
  logic [ZW-1:0]   cur_key;
  logic [ZKAW-1:0] cur_key_idx;         // cmd_key_idx, narrowed to the RAM

  logic [CNTW-1:0] k;                 // outer neighbour index (0..4)
  logic [CNTW-1:0] j;                 // DFS neighbour index   (0..4)
  logic [1:0]      op_nc;             // latched colour of neighbour k

  logic [CNTW-1:0] empties, opps, weak_opps, neighs, weak_neighs;
  logic [ZW-1:0]   h_cand;            // USEFUL candidate hash

  logic [POSW-1:0] find_p, find_start, find_root, find_cp;
  logic            find_cmp;          // path-compress after the walk

  logic [ZKAW-1:0] xp_a0, xp_a1;      // XOR-pair operand addresses
  logic            xp_sel;            // 0 = accumulate into hash, 1 = h_cand

  logic [POSW-1:0] dfs_stack [0:NPTS-1];
  logic [SPW-1:0]  sp;
  logic [POSW-1:0] dfs_root, dfs_s;

  logic [POSW-1:0] rst_sq;

  // stack indices, narrowed to the array depth (sp itself is one bit wider so
  // that the "stack full" value NPTS is representable)
  logic [POSW-1:0] sp_tos;             // top of stack  = sp-1
  logic [POSW-1:0] sp_push;            // next push slot = sp
  logic [POSW-1:0] tos_sq;             // the square on top of the stack
  assign sp_tos  = POSW'(sp - SPW'(1));
  assign sp_push = POSW'(sp);
  assign tos_sq  = dfs_stack[sp_tos];

  // ------------------------------------------------- combinational selectors
  // Neighbour k of the centre square, and neighbour j of the DFS square.
  logic [POSW:0] k_ent, j_ent;
  assign k_ent = neigh_rom[cur_pos][k[1:0]];
  assign j_ent = neigh_rom[dfs_s ][j[1:0]];

  logic            k_vld, j_vld;
  logic [POSW-1:0] k_nb,  j_nb;
  assign k_vld = k_ent[POSW];
  assign k_nb  = k_ent[POSW-1:0];
  assign j_vld = j_ent[POSW];
  assign j_nb  = j_ent[POSW-1:0];

  // USEFUL fast path: untouched point with at least one empty neighbour
  logic [NDIR-1:0] fast_nb_empty;
  generate
    for (genvar gf = 0; gf < NDIR; gf++) begin : g_fast
      logic [POSW:0] fe;
      assign fe = neigh_rom[cur_pos][gf];
      assign fast_nb_empty[gf] = fe[POSW] && (color_arr[fe[POSW-1:0]] == C_EMPTY);
    end
  endgenerate

  logic fast_ok;
  assign fast_ok = !used[cur_pos] && (|fast_nb_empty);

  // USEFUL predicate
  logic cond_calc;
  assign cond_calc = (empties != '0) || (weak_opps != '0) ||
                     ((neighs != weak_neighs) &&
                      ((opps != weak_opps) || (weak_neighs != '0)));

  // temp_ledges[r] after this neighbour's decrement
  logic [LEDGEW-1:0] temp_next;
  assign temp_next = (root_seen[find_root] ? temp_arr[find_root]
                                           : ledges_arr[find_root]) - LEDGEW'(1);

  // path-compression: the node that gets repointed at the root
  logic [POSW-1:0] cmp_q;
  assign cmp_q = ref_arr[find_cp];

  // ZKEY read address mux (registered read -> data valid the following state)
  always_comb begin
    unique case (state)
      S_XP_A:     zkey_addr = xp_a0;
      S_XP_B:     zkey_addr = xp_a1;
      S_RST_ADDR: zkey_addr = zk_idx(rst_sq, C_EMPTY);
      default:    zkey_addr = xp_a0;
    endcase
  end

  assign zkey_we   = (state == S_LDKEY);
  assign cmd_ready = (state == S_IDLE);
  assign busy      = (state != S_IDLE);
  assign cur_hash  = hash;

  always_ff @(posedge clk) begin
    if (zkey_we) zkey_mem[cur_key_idx] <= cur_key;
    zkey_q <= zkey_mem[zkey_addr];
  end

  // ------------------------------------------------------------- sequencer
  integer i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      xp_ret      <= S_IDLE;
      find_ret    <= S_IDLE;
      done        <= 1'b0;
      res_fast    <= 1'b0;
      res_cond    <= 1'b0;
      res_hash    <= '0;
      hash        <= '0;
      cur_pos     <= '0;
      cur_color   <= C_EMPTY;
      cur_key     <= '0;
      cur_key_idx <= '0;
      k           <= '0;
      j           <= '0;
      op_nc       <= C_EMPTY;
      empties     <= '0;
      opps        <= '0;
      weak_opps   <= '0;
      neighs      <= '0;
      weak_neighs <= '0;
      h_cand      <= '0;
      find_p      <= '0;
      find_start  <= '0;
      find_root   <= '0;
      find_cp     <= '0;
      find_cmp    <= 1'b0;
      xp_a0       <= '0;
      xp_a1       <= '0;
      xp_sel      <= 1'b0;
      sp          <= '0;
      dfs_root    <= '0;
      dfs_s       <= '0;
      rst_sq      <= '0;
      used        <= '0;
      root_seen   <= '0;
      removed     <= '0;
      // verilator lint_off BLKLOOPINIT
      // (Verilator 4.x cannot code-generate a non-blocking array assignment
      //  inside a loop; it is ordinary parallel-clear RTL for synthesis.)
      for (i = 0; i < NPTS; i = i + 1) begin
        color_arr[i]  <= C_EMPTY;
        ref_arr[i]    <= POSW'(i);
        ledges_arr[i] <= '0;
        temp_arr[i]   <= '0;
        dfs_stack[i]  <= '0;
      end
      // verilator lint_on BLKLOOPINIT
    end else begin
      done <= 1'b0;                       // default: single-cycle pulse

      unique case (state)

        // ---------------------------------------------------------- dispatch
        S_IDLE: begin
          if (cmd_valid) begin
            cur_pos     <= cmd_pos;
            cur_color   <= cmd_color;
            cur_key     <= cmd_key;
            cur_key_idx <= cmd_key_idx[ZKAW-1:0];
            unique case (cmd_op)
              OP_RESET:    state <= S_RST_CLR;
              OP_MOVE:     state <= S_M_START;
              OP_USEFUL:   state <= S_U_START;
              OP_LOAD_KEY: state <= S_LDKEY;
              default: done <= 1'b1;         // NOP and undefined opcodes
            endcase
          end
        end

        // ------------------------------------------------------------- RESET
        S_RST_CLR: begin
          // verilator lint_off BLKLOOPINIT
          for (i = 0; i < NPTS; i = i + 1) begin
            color_arr[i]  <= C_EMPTY;
            ref_arr[i]    <= POSW'(i);
            ledges_arr[i] <= '0;
          end
          // verilator lint_on BLKLOOPINIT
          used   <= '0;
          hash   <= '0;
          rst_sq <= '0;
          state  <= S_RST_ADDR;
        end

        S_RST_ADDR: begin                    // drive zkey_addr = rst_sq*3+EMPTY
          state <= S_RST_ACC;
        end

        S_RST_ACC: begin
          hash <= hash ^ zkey_q;
          if (rst_sq == POSW'(NPTS - 1)) begin
            done  <= 1'b1;
            state <= S_IDLE;
          end else begin
            rst_sq <= rst_sq + POSW'(1);
            state  <= S_RST_ADDR;
          end
        end

        // ---------------------------------------------------------- LOAD_KEY
        S_LDKEY: begin                       // zkey_we is asserted in this state
          done  <= 1'b1;
          state <= S_IDLE;
        end

        // ------------------------------------------- XOR-pair sub-routine
        // acc ^= ZKEY[xp_a0] ^ ZKEY[xp_a1];  acc = hash or h_cand
        S_XP_A: state <= S_XP_B;

        S_XP_B: begin
          if (xp_sel) h_cand <= h_cand ^ zkey_q;
          else        hash   <= hash   ^ zkey_q;
          state <= S_XP_C;
        end

        S_XP_C: begin
          if (xp_sel) h_cand <= h_cand ^ zkey_q;
          else        hash   <= hash   ^ zkey_q;
          state <= xp_ret;
        end

        // ----------------------------------------------- FIND sub-routine
        S_FIND_WALK: begin
          if (ref_arr[find_p] == find_p) begin
            find_root <= find_p;
            if (find_cmp) begin
              find_cp <= find_start;
              state   <= S_FIND_CMP;
            end else begin
              state <= find_ret;
            end
          end else begin
            find_p <= ref_arr[find_p];
          end
        end

        // Mirrors CPython's `p, ref[p] = ref[p], root`: the *new* p is the
        // node that gets repointed, so the first node keeps its parent.
        S_FIND_CMP: begin
          if (ref_arr[find_cp] == find_root) begin
            state <= find_ret;
          end else begin
            ref_arr[cmp_q] <= find_root;
            find_cp        <= cmp_q;
          end
        end

        // -------------------------------------------------------- USEFUL
        S_U_START: begin
          root_seen   <= '0;
          removed     <= '0;
          empties     <= '0;
          opps        <= '0;
          weak_opps   <= '0;
          neighs      <= '0;
          weak_neighs <= '0;
          k           <= '0;
          if (fast_ok) begin
            res_fast <= 1'b1;
            res_cond <= 1'b1;
            res_hash <= '0;                 // fast path returns hash 0
            done     <= 1'b1;
            state    <= S_IDLE;
          end else begin
            state <= S_U_HINIT;
          end
        end

        // h = hash ^ ZKEY[pos*3+color[pos]] ^ ZKEY[pos*3+color_in]
        S_U_HINIT: begin
          h_cand <= hash;
          xp_a0  <= zk_idx(cur_pos, color_arr[cur_pos]);
          xp_a1  <= zk_idx(cur_pos, cur_color);
          xp_sel <= 1'b1;
          xp_ret <= S_U_LOOP;
          state  <= S_XP_A;
        end

        S_U_LOOP: begin
          if (k == CNTW'(NDIR)) begin
            res_fast <= 1'b0;
            res_cond <= cond_calc;
            res_hash <= h_cand;
            done     <= 1'b1;
            state    <= S_IDLE;
          end else if (!k_vld) begin
            k <= k + CNTW'(1);
          end else if (color_arr[k_nb] == C_EMPTY) begin
            empties <= empties + CNTW'(1);
            k       <= k + CNTW'(1);
          end else begin
            op_nc      <= color_arr[k_nb];
            find_p     <= k_nb;
            find_start <= k_nb;
            find_cmp   <= 1'b0;             // USEFUL must not mutate ref
            find_ret   <= S_U_FIND_DONE;
            state      <= S_FIND_WALK;
          end
        end

        S_U_FIND_DONE: begin
          if (!root_seen[find_root]) begin
            root_seen[find_root] <= 1'b1;
            if (op_nc == cur_color) neighs <= neighs + CNTW'(1);
            else                    opps   <= opps   + CNTW'(1);
          end
          temp_arr[find_root] <= temp_next;
          if (temp_next == '0) begin
            if (op_nc == cur_color) begin
              weak_neighs <= weak_neighs + CNTW'(1);
              k           <= k + CNTW'(1);
              state       <= S_U_LOOP;
            end else begin
              weak_opps            <= weak_opps + CNTW'(1);
              dfs_root             <= find_root;
              dfs_stack[0]         <= find_root;
              sp                   <= SPW'(1);
              removed[find_root]   <= 1'b1;
              state                <= S_U_CAS_POP;
            end
          end else begin
            k     <= k + CNTW'(1);
            state <= S_U_LOOP;
          end
        end

        // speculative capture flood fill (no committed state is touched)
        S_U_CAS_POP: begin
          if (sp == '0) begin
            k     <= k + CNTW'(1);
            state <= S_U_LOOP;
          end else begin
            dfs_s  <= tos_sq;
            sp     <= sp - SPW'(1);
            xp_a0  <= zk_idx(tos_sq, color_arr[tos_sq]);
            xp_a1  <= zk_idx(tos_sq, C_EMPTY);
            xp_sel <= 1'b1;
            xp_ret <= S_U_CAS_NB;
            j      <= '0;
            state  <= S_XP_A;
          end
        end

        S_U_CAS_NB: begin
          if (j == CNTW'(NDIR)) begin
            state <= S_U_CAS_POP;
          end else if (!j_vld || (color_arr[j_nb] == C_EMPTY) || removed[j_nb]) begin
            j <= j + CNTW'(1);
          end else begin
            find_p     <= j_nb;
            find_start <= j_nb;
            find_cmp   <= 1'b0;
            find_ret   <= S_U_CAS_FIND;
            state      <= S_FIND_WALK;
          end
        end

        S_U_CAS_FIND: begin
          if (find_root == dfs_root) begin  // same group -> visit it
            dfs_stack[sp_push] <= j_nb;
            sp             <= sp + SPW'(1);
            removed[j_nb]  <= 1'b1;
          end
          j     <= j + CNTW'(1);
          state <= S_U_CAS_NB;
        end

        // ---------------------------------------------------------- MOVE
        // hash ^= ZKEY[pos*3+color[pos]] ^ ZKEY[pos*3+color_in]
        S_M_START: begin
          xp_a0  <= zk_idx(cur_pos, color_arr[cur_pos]);
          xp_a1  <= zk_idx(cur_pos, cur_color);
          xp_sel <= 1'b0;
          xp_ret <= S_M_INIT;
          state  <= S_XP_A;
        end

        S_M_INIT: begin
          color_arr[cur_pos]  <= cur_color;
          ref_arr[cur_pos]    <= cur_pos;
          ledges_arr[cur_pos] <= '0;
          used[cur_pos]       <= 1'b1;
          root_seen           <= '0;
          removed             <= '0;
          k                   <= '0;
          state               <= S_M_LOOP;
        end

        S_M_LOOP: begin
          if (k == CNTW'(NDIR)) begin
            res_fast <= 1'b0;
            res_cond <= 1'b0;
            res_hash <= hash;
            done     <= 1'b1;
            state    <= S_IDLE;
          end else if (!k_vld) begin
            k <= k + CNTW'(1);
          end else if (color_arr[k_nb] == C_EMPTY) begin
            ledges_arr[cur_pos] <= ledges_arr[cur_pos] + LEDGEW'(1);
            k                   <= k + CNTW'(1);
          end else begin
            op_nc      <= color_arr[k_nb];
            find_p     <= k_nb;
            find_start <= k_nb;
            find_cmp   <= 1'b1;             // MOVE path compresses
            find_ret   <= S_M_FIND_DONE;
            state      <= S_FIND_WALK;
          end
        end

        S_M_FIND_DONE: begin
          if (op_nc == cur_color) begin
            // friendly group: merge unless it is already ours
            // (ref[r] != pos is equivalent to r != pos, r being a root)
            if (find_root != cur_pos) begin
              ledges_arr[cur_pos] <= ledges_arr[cur_pos]
                                     + ledges_arr[find_root] - LEDGEW'(1);
              ref_arr[find_root]  <= cur_pos;
            end else begin
              ledges_arr[cur_pos] <= ledges_arr[cur_pos] - LEDGEW'(1);
            end
            k     <= k + CNTW'(1);
            state <= S_M_LOOP;
          end else begin
            ledges_arr[find_root] <= ledges_arr[find_root] - LEDGEW'(1);
            if (ledges_arr[find_root] == LEDGEW'(1)) begin
              dfs_root      <= find_root;   // capture: DFS starts at neighbour k
              dfs_stack[0]  <= k_nb;
              sp            <= SPW'(1);
              removed[k_nb] <= 1'b1;
              state         <= S_M_RC_POP;
            end else begin
              k     <= k + CNTW'(1);
              state <= S_M_LOOP;
            end
          end
        end

        // committed capture flood fill
        S_M_RC_POP: begin
          if (sp == '0) begin
            k     <= k + CNTW'(1);
            state <= S_M_LOOP;
          end else begin
            dfs_s  <= tos_sq;
            sp     <= sp - SPW'(1);
            xp_a0  <= zk_idx(tos_sq, color_arr[tos_sq]);
            xp_a1  <= zk_idx(tos_sq, C_EMPTY);
            xp_sel <= 1'b0;
            xp_ret <= S_M_RC_NB;
            j      <= '0;
            color_arr[tos_sq] <= C_EMPTY;
            state  <= S_XP_A;
          end
        end

        S_M_RC_NB: begin
          if (j == CNTW'(NDIR)) begin
            state <= S_M_RC_POP;
          end else if (!j_vld || (color_arr[j_nb] == C_EMPTY) || removed[j_nb]) begin
            j <= j + CNTW'(1);
          end else begin
            find_p     <= j_nb;
            find_start <= j_nb;
            find_cmp   <= 1'b1;
            find_ret   <= S_M_RC_FIND;
            state      <= S_FIND_WALK;
          end
        end

        S_M_RC_FIND: begin
          if (find_root == dfs_root) begin        // same group -> remove it too
            dfs_stack[sp_push] <= j_nb;
            sp            <= sp + SPW'(1);
            removed[j_nb] <= 1'b1;
          end else begin                          // other group gains a liberty
            ledges_arr[find_root] <= ledges_arr[find_root] + LEDGEW'(1);
          end
          j     <= j + CNTW'(1);
          state <= S_M_RC_NB;
        end

        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  // ------------------------------------------------------------- assertions
  // (simulation only; kept simple enough for Icarus)
  always @(posedge clk) begin
    if (rst_n) begin
      if (done && res_fast && (res_hash != '0))
        $error("%m: res_hash must be 0 on the USEFUL fast path");
      if (sp > SPW'(NPTS))
        $error("%m: DFS stack overflow (sp=%0d)", sp);
      if (zkey_we && (cur_key_idx >= ZKAW'(3*NPTS)))
        $error("%m: ZKEY index %0d out of range", cur_key_idx);
      if (cmd_valid && cmd_ready && (cmd_pos >= POSW'(NPTS)))
        $error("%m: cmd_pos %0d out of range", cmd_pos);
    end
  end
`endif

endmodule

`default_nettype wire
