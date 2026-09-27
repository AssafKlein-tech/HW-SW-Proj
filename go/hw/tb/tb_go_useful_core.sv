// ---------------------------------------------------------------------------
// tb_go_useful_core.sv
//
// Main self-checking testbench for go_useful_core: replays the recorded
// operation stream sw_with_hw_interface/ops_trace.txt (81,747 ops dumped from a real
// benchmark run against the Python model) and checks
//   * {res_fast, res_cond, res_hash} on every USEFUL
//   * cur_hash on every MOVE
// $fatal on the first mismatch.  Also measures per-op-type cycle counts.
//
// Trace record: "op a b c d", op decimal, the rest hex
//   1 key_index key   0            0            LOAD_KEY
//   2 0         0     0            0            RESET
//   3 pos       color expect_hash  0            MOVE
//   4 pos       color expect_hash  {fast,cond}  USEFUL
// (note: the trace opcodes are NOT the hardware opcodes; they are remapped)
//
// Run:  iverilog -g2012 -o tb_core tb/tb_go_useful_core.sv rtl/go_useful_core.sv
//       vvp tb_core [+trace=<path>] [+maxops=<n>] [+vcd]
// ---------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

// Board size is overridable so that the parameterisation of go_useful_core can
// be proved on non-default geometries:  iverilog -g2012 -DTB_SIZE=5 ...
`ifndef TB_SIZE
  `define TB_SIZE 9
`endif

module tb_go_useful_core;

  localparam int SIZE   = `TB_SIZE;
  localparam int NPTS   = SIZE * SIZE;
  localparam int POSW   = $clog2(NPTS);
  localparam int LEDGEW = $clog2(4 * NPTS + 1);
  localparam int ZW     = 63;
  // 9 b on the 9x9 build to match the register-map spec, wider if the board is
  localparam int ZAW    = ($clog2(3 * NPTS) > 9) ? $clog2(3 * NPTS) : 9;

  // hardware opcodes
  localparam logic [3:0] OP_NOP      = 4'd0;
  localparam logic [3:0] OP_RESET    = 4'd1;
  localparam logic [3:0] OP_MOVE     = 4'd2;
  localparam logic [3:0] OP_USEFUL   = 4'd3;
  localparam logic [3:0] OP_LOAD_KEY = 4'd4;

  // trace opcodes
  localparam int T_LOAD_KEY = 1;
  localparam int T_RESET    = 2;
  localparam int T_MOVE     = 3;
  localparam int T_USEFUL   = 4;

  // ------------------------------------------------------------------- DUT
  logic            clk = 1'b0;
  logic            rst_n;
  logic            cmd_valid;
  wire             cmd_ready;
  logic [3:0]      cmd_op;
  logic [POSW-1:0] cmd_pos;
  logic [1:0]      cmd_color;
  logic [ZW-1:0]   cmd_key;
  logic [ZAW-1:0]  cmd_key_idx;
  wire             busy;
  wire             done;
  wire             res_fast;
  wire             res_cond;
  wire [ZW-1:0]    res_hash;
  wire [ZW-1:0]    cur_hash;

  go_useful_core #(
      .SIZE   (SIZE),
      .NPTS   (NPTS),
      .POSW   (POSW),
      .LEDGEW (LEDGEW),
      .ZW     (ZW),
      .ZAW    (ZAW)
  ) u_dut (
      .clk         (clk),
      .rst_n       (rst_n),
      .cmd_valid   (cmd_valid),
      .cmd_ready   (cmd_ready),
      .cmd_op      (cmd_op),
      .cmd_pos     (cmd_pos),
      .cmd_color   (cmd_color),
      .cmd_key     (cmd_key),
      .cmd_key_idx (cmd_key_idx),
      .busy        (busy),
      .done        (done),
      .res_fast    (res_fast),
      .res_cond    (res_cond),
      .res_hash    (res_hash),
      .cur_hash    (cur_hash)
  );

  always #5 clk = ~clk;                  // 100 MHz

  // free-running cycle counter (increments on the same edge as the DUT)
  integer cycle_count = 0;
  always @(posedge clk) cycle_count = cycle_count + 1;

  // ------------------------------------------------------------- statistics
  // classes: 0 = LOAD_KEY, 1 = RESET, 2 = MOVE, 3 = USEFUL fast, 4 = USEFUL full
  integer cls_n    [0:4];
  integer cls_min  [0:4];
  integer cls_max  [0:4];
  real    cls_sum  [0:4];
  string  cls_name [0:4];

  integer op_start;
  integer op_cycles;
  integer errors = 0;
  integer nops   = 0;

  // latency buckets (USEFUL full path / MOVE), for the performance write-up
  integer u_gt50 = 0, u_gt100 = 0, u_gt200 = 0, u_gt300 = 0;
  integer m_gt50 = 0, m_gt100 = 0, m_gt200 = 0, m_gt300 = 0;

  // ---- USEFUL must not mutate committed state --------------------------
  // cur_hash is checked on every USEFUL; the full array snapshot is compared
  // every SNAP_EVERY'th USEFUL (cheap, and a leak would show up quickly).
  localparam int SNAP_EVERY = 500;
  logic [ZW-1:0]     snap_hash;
  logic [1:0]        snap_color  [0:NPTS-1];
  logic [POSW-1:0]   snap_ref    [0:NPTS-1];
  logic [LEDGEW-1:0] snap_ledges [0:NPTS-1];
  logic [NPTS-1:0] snap_used;
  integer          snaps = 0;
  integer          si;

  task automatic snapshot_take;
    begin
      snap_hash = cur_hash;
      snap_used = u_dut.used;
      for (si = 0; si < NPTS; si = si + 1) begin
        snap_color[si]  = u_dut.color_arr[si];
        snap_ref[si]    = u_dut.ref_arr[si];
        snap_ledges[si] = u_dut.ledges_arr[si];
      end
    end
  endtask

  task automatic snapshot_check;
    begin
      snaps = snaps + 1;
      if (snap_used !== u_dut.used) begin
        errors = errors + 1;
        $display("FAIL op %0d: USEFUL modified used[]", nops);
      end
      for (si = 0; si < NPTS; si = si + 1) begin
        if (snap_color[si] !== u_dut.color_arr[si] ||
            snap_ref[si]   !== u_dut.ref_arr[si]   ||
            snap_ledges[si]!== u_dut.ledges_arr[si]) begin
          errors = errors + 1;
          $display("FAIL op %0d: USEFUL modified committed state at square %0d",
                   nops, si);
        end
      end
      if (errors != 0) $fatal(1, "USEFUL mutated committed state");
    end
  endtask

  // ---------------------------------------------------------------- driving
  task automatic issue(input logic [3:0]      op,
                       input logic [POSW-1:0] pos,
                       input logic [1:0]      colr,
                       input logic [ZW-1:0]   key,
                       input logic [ZAW-1:0]  kidx);
    begin
      @(negedge clk);
      while (cmd_ready !== 1'b1) @(negedge clk);
      cmd_op      = op;
      cmd_pos     = pos;
      cmd_color   = colr;
      cmd_key     = key;
      cmd_key_idx = kidx;
      cmd_valid   = 1'b1;
      op_start    = cycle_count;
      @(negedge clk);                    // the posedge in between accepted it
      cmd_valid   = 1'b0;
      cmd_op      = OP_NOP;
      while (done !== 1'b1) begin
        @(negedge clk);
        if ((cycle_count - op_start) > 20000) begin
          $display("FAIL: watchdog - op %0d (hw op %0d pos %0d) never completed",
                   nops, op, pos);
          $fatal(1, "watchdog timeout");
        end
      end
      op_cycles = cycle_count - op_start;
    end
  endtask

  task automatic record(input int cls);
    begin
      cls_n[cls]   = cls_n[cls] + 1;
      cls_sum[cls] = cls_sum[cls] + real'(op_cycles);
      if (op_cycles < cls_min[cls]) cls_min[cls] = op_cycles;
      if (op_cycles > cls_max[cls]) cls_max[cls] = op_cycles;
    end
  endtask

  // ------------------------------------------------------------------- main
  integer      fh;
  integer      r;
  integer      top;
  logic [63:0] fa, fb, fc, fd;
  logic [63:0] got_hash;
  logic [1:0]  got_fc;
  string       tracefile;
  integer      maxops;
  integer      c;
  integer      running;

  initial begin
    for (c = 0; c < 5; c = c + 1) begin
      cls_n[c]   = 0;
      cls_sum[c] = 0.0;
      cls_min[c] = 1000000;
      cls_max[c] = 0;
    end
    cls_name[0] = "LOAD_KEY     ";
    cls_name[1] = "RESET        ";
    cls_name[2] = "MOVE         ";
    cls_name[3] = "USEFUL fast  ";
    cls_name[4] = "USEFUL full  ";

    if (!$value$plusargs("trace=%s", tracefile))
      tracefile = "sw_with_hw_interface/ops_trace.txt";
    if (!$value$plusargs("maxops=%d", maxops))
      maxops = 0;                        // 0 = whole file

    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_go_useful_core.vcd");
      $dumpvars(0, tb_go_useful_core);
    end

    cmd_valid   = 1'b0;
    cmd_op      = OP_NOP;
    cmd_pos     = '0;
    cmd_color   = 2'd0;
    cmd_key     = '0;
    cmd_key_idx = '0;
    rst_n       = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    fh = $fopen(tracefile, "r");
    if (fh == 0) $fatal(1, "cannot open trace file %s", tracefile);
    $display("[tb] replaying %s  (SIZE=%0d, NPTS=%0d, POSW=%0d, LEDGEW=%0d)",
             tracefile, SIZE, NPTS, POSW, LEDGEW);

    running = 1;
    while (running) begin
      r = $fscanf(fh, "%d %h %h %h %h\n", top, fa, fb, fc, fd);
      if (r != 5) begin
        if (r != -1)
          $display("[tb] WARNING: malformed record after %0d ops (r=%0d)", nops, r);
        running = 0;
      end else begin
      nops = nops + 1;

      case (top)
        // ---------------------------------------------------- LOAD_KEY
        T_LOAD_KEY: begin
          issue(OP_LOAD_KEY, '0, 2'd0, fb[ZW-1:0], fa[ZAW-1:0]);
          record(0);
        end

        // ------------------------------------------------------- RESET
        T_RESET: begin
          issue(OP_RESET, '0, 2'd0, '0, '0);
          record(1);
        end

        // -------------------------------------------------------- MOVE
        T_MOVE: begin
          issue(OP_MOVE, fa[POSW-1:0], fb[1:0], '0, '0);
          record(2);
          if (op_cycles >  50) m_gt50  = m_gt50  + 1;
          if (op_cycles > 100) m_gt100 = m_gt100 + 1;
          if (op_cycles > 200) m_gt200 = m_gt200 + 1;
          if (op_cycles > 300) m_gt300 = m_gt300 + 1;
          got_hash = {1'b0, cur_hash};
          if (got_hash !== fc) begin
            errors = errors + 1;
            $display("FAIL op %0d MOVE pos=%0d color=%0d: cur_hash exp %016h got %016h",
                     nops, fa[POSW-1:0], fb[1:0], fc, got_hash);
            $fatal(1, "MOVE hash mismatch");
          end
        end

        // ------------------------------------------------------ USEFUL
        T_USEFUL: begin
          snap_hash = cur_hash;
          if ((nops % SNAP_EVERY) == 0) snapshot_take();
          issue(OP_USEFUL, fa[POSW-1:0], fb[1:0], '0, '0);
          record(res_fast ? 3 : 4);
          if (!res_fast) begin
            if (op_cycles >  50) u_gt50  = u_gt50  + 1;
            if (op_cycles > 100) u_gt100 = u_gt100 + 1;
            if (op_cycles > 200) u_gt200 = u_gt200 + 1;
            if (op_cycles > 300) u_gt300 = u_gt300 + 1;
          end
          if (snap_hash !== cur_hash) begin
            errors = errors + 1;
            $display("FAIL op %0d: USEFUL changed the committed hash (%016h -> %016h)",
                     nops, snap_hash, cur_hash);
            $fatal(1, "USEFUL mutated cur_hash");
          end
          if ((nops % SNAP_EVERY) == 0) snapshot_check();
          got_fc   = {res_fast, res_cond};
          got_hash = {1'b0, res_hash};
          if ((got_fc !== fd[1:0]) || (got_hash !== fc)) begin
            errors = errors + 1;
            $display("FAIL op %0d USEFUL pos=%0d color=%0d:", nops, fa[POSW-1:0], fb[1:0]);
            $display("      exp {fast,cond}=%02b hash=%016h", fd[1:0], fc);
            $display("      got {fast,cond}=%02b hash=%016h", got_fc, got_hash);
            $fatal(1, "USEFUL result mismatch");
          end
        end

        default: begin
          errors = errors + 1;
          $display("FAIL op %0d: unknown trace opcode %0d", nops, top);
          $fatal(1, "bad trace opcode");
        end
      endcase

      if ((nops % 10000) == 0)
        $display("[tb] %0d ops replayed, %0d cycles, 0 errors", nops, cycle_count);
      if ((maxops != 0) && (nops >= maxops)) running = 0;
      end
    end
    $fclose(fh);

    // ------------------------------------------------------------ summary
    $display("");
    $display("=============================================================");
    $display(" go_useful_core trace replay summary");
    $display("=============================================================");
    $display(" ops replayed : %0d", nops);
    $display(" sim cycles   : %0d  (%0.1f us at 100 MHz)",
             cycle_count, real'(cycle_count) / 100.0);
    $display("");
    $display(" op class        count      min     mean      max   (cycles)");
    for (c = 0; c < 5; c = c + 1) begin
      if (cls_n[c] > 0)
        $display("  %s %7d  %7d  %7.2f  %7d", cls_name[c], cls_n[c],
                 cls_min[c], cls_sum[c] / real'(cls_n[c]), cls_max[c]);
      else
        $display("  %s %7d        -        -        -", cls_name[c], cls_n[c]);
    end
    $display("");
    $display(" latency tail        >50cy   >100cy  >200cy  >300cy");
    $display("  USEFUL full      %7d  %7d %7d %7d", u_gt50, u_gt100, u_gt200, u_gt300);
    $display("  MOVE             %7d  %7d %7d %7d", m_gt50, m_gt100, m_gt200, m_gt300);
    $display(" USEFUL no-mutation snapshots compared: %0d", snaps);
    $display("");
    if (errors == 0)
      $display(" PASS - all %0d ops matched the golden model", nops);
    else
      $display(" FAIL (%0d errors)", errors);
    $display("=============================================================");
    if (errors != 0) $fatal(1, "FAIL (%0d errors)", errors);
    $finish;
  end

  // global watchdog
  initial begin
    #300000000;                          // 300 ms of sim time
    $display("FAIL: global watchdog expired at %0d cycles (%0d ops)",
             cycle_count, nops);
    $fatal(1, "global timeout");
  end

endmodule

`default_nettype wire
