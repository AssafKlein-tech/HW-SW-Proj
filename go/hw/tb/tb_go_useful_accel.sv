// ---------------------------------------------------------------------------
// tb_go_useful_accel.sv
//
// AXI4-Lite smoke test for go_useful_accel:
//   * reset behaviour and write-only / unmapped register reads
//   * KEY_LO / KEY_HI / KEY_IDX key loading (the KEY_IDX write commits)
//   * STAT.busy during a long op (RESET), sticky done, done cleared by a
//     RES_LO read and by a new command
//   * replays the first N ops of the real trace through the bus and checks
//     MOVE hashes and USEFUL {fast,cond,hash} against the golden values
//
// Run: iverilog -g2012 -o tb_axil tb/tb_go_useful_accel.sv \
//               rtl/go_useful_accel.sv rtl/go_useful_core.sv
//      vvp tb_axil
// ---------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module tb_go_useful_accel;

  localparam int ADDRW = 5;

  localparam logic [ADDRW-1:0] A_CMD     = 5'h00;
  localparam logic [ADDRW-1:0] A_STAT    = 5'h04;
  localparam logic [ADDRW-1:0] A_RES_LO  = 5'h08;
  localparam logic [ADDRW-1:0] A_RES_HI  = 5'h0C;
  localparam logic [ADDRW-1:0] A_KEY_LO  = 5'h10;
  localparam logic [ADDRW-1:0] A_KEY_HI  = 5'h14;
  localparam logic [ADDRW-1:0] A_KEY_IDX = 5'h18;

  localparam logic [3:0] OP_NOP    = 4'd0;
  localparam logic [3:0] OP_RESET  = 4'd1;
  localparam logic [3:0] OP_MOVE   = 4'd2;
  localparam logic [3:0] OP_USEFUL = 4'd3;

  localparam int T_LOAD_KEY = 1;
  localparam int T_RESET    = 2;
  localparam int T_MOVE     = 3;
  localparam int T_USEFUL   = 4;

  localparam int SMOKE_OPS = 400;       // ops of the trace replayed over AXI

  // ------------------------------------------------------------------- DUT
  logic        clk = 1'b0;
  logic        rst_n;

  logic [ADDRW-1:0] awaddr;
  logic             awvalid;
  wire              awready;
  logic [31:0]      wdata;
  logic [3:0]       wstrb;
  logic             wvalid;
  wire              wready;
  wire  [1:0]       bresp;
  wire              bvalid;
  logic             bready;
  logic [ADDRW-1:0] araddr;
  logic             arvalid;
  wire              arready;
  wire  [31:0]      rdata;
  wire  [1:0]       rresp;
  wire              rvalid;
  logic             rready;

  go_useful_accel u_dut (
      .clk           (clk),
      .rst_n         (rst_n),
      .s_axi_awaddr  (awaddr),
      .s_axi_awprot  (3'b000),
      .s_axi_awvalid (awvalid),
      .s_axi_awready (awready),
      .s_axi_wdata   (wdata),
      .s_axi_wstrb   (wstrb),
      .s_axi_wvalid  (wvalid),
      .s_axi_wready  (wready),
      .s_axi_bresp   (bresp),
      .s_axi_bvalid  (bvalid),
      .s_axi_bready  (bready),
      .s_axi_araddr  (araddr),
      .s_axi_arprot  (3'b000),
      .s_axi_arvalid (arvalid),
      .s_axi_arready (arready),
      .s_axi_rdata   (rdata),
      .s_axi_rresp   (rresp),
      .s_axi_rvalid  (rvalid),
      .s_axi_rready  (rready)
  );

  always #5 clk = ~clk;                 // 100 MHz

  integer errors = 0;

  task automatic chk(input logic cond_ok, input string what);
    begin
      if (!cond_ok) begin
        errors = errors + 1;
        $display("FAIL: %s", what);
      end else begin
        $display("  ok : %s", what);
      end
    end
  endtask

  // --------------------------------------------------------- AXI4-Lite BFM
  // Both READY signals here are combinational on VALID, so the BFM drives on
  // the negedge, lets the combinational logic settle (#1) and samples READY
  // before the posedge that performs the transfer.
  task automatic axi_write(input logic [ADDRW-1:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      awaddr  = addr;
      wdata   = data;
      wstrb   = 4'hF;
      awvalid = 1'b1;
      wvalid  = 1'b1;
      bready  = 1'b1;
      #1;
      while (!(awready && wready)) begin
        @(negedge clk);
        #1;
      end
      @(negedge clk);                      // the posedge in between accepted it
      awvalid = 1'b0;
      wvalid  = 1'b0;
      #1;
      while (!bvalid) begin
        @(negedge clk);
        #1;
      end
      if (bresp !== 2'b00) begin
        errors = errors + 1;
        $display("FAIL: BRESP %b on write to 0x%02h", bresp, addr);
      end
      @(negedge clk);                      // B handshake completed at the posedge
      bready = 1'b0;
    end
  endtask

  task automatic axi_read(input logic [ADDRW-1:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      araddr  = addr;
      arvalid = 1'b1;
      rready  = 1'b1;
      #1;
      while (!arready) begin
        @(negedge clk);
        #1;
      end
      @(negedge clk);                      // the posedge in between accepted AR
      arvalid = 1'b0;
      #1;
      while (!rvalid) begin
        @(negedge clk);
        #1;
      end
      data = rdata;
      if (rresp !== 2'b00) begin
        errors = errors + 1;
        $display("FAIL: RRESP %b on read of 0x%02h", rresp, addr);
      end
      @(negedge clk);                      // R handshake completed at the posedge
      rready = 1'b0;
    end
  endtask

  // --------------------------------------------------------------- helpers
  logic [31:0] rd, st, hi, lo;

  task automatic poll_done;
    begin
      hi = 32'd0;
      while (!hi[31]) axi_read(A_RES_HI, hi);     // poll one register
    end
  endtask

  task automatic get_result(output logic [1:0] fc, output logic [63:0] h);
    begin
      poll_done();
      axi_read(A_STAT,   st);
      axi_read(A_RES_LO, lo);                     // this read clears done
      fc = {st[3], st[2]};
      h  = {1'b0, hi[30:0], lo};
    end
  endtask

  task automatic load_key(input logic [8:0] idx, input logic [62:0] key);
    begin
      axi_write(A_KEY_LO,  key[31:0]);
      axi_write(A_KEY_HI,  {1'b0, key[62:32]});
      axi_write(A_KEY_IDX, {23'd0, idx});         // commits the key
      poll_done();
      axi_read(A_RES_LO, lo);                     // clear sticky done
    end
  endtask

  // ------------------------------------------------------------------- main
  integer      fh, r, top, nops;
  logic [63:0] fa, fb, fc_h, fd;
  logic [1:0]  got_fc;
  logic [63:0] got_h;
  integer      running;
  string       tracefile;

  initial begin
    awaddr = '0; awvalid = 1'b0; wdata = '0; wstrb = 4'h0; wvalid = 1'b0;
    bready = 1'b0; araddr = '0; arvalid = 1'b0; rready = 1'b0;
    rst_n  = 1'b0;

    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_go_useful_accel.vcd");
      $dumpvars(0, tb_go_useful_accel);
    end
    if (!$value$plusargs("trace=%s", tracefile))
      tracefile = "sw_with_hw_interface/ops_trace.txt";

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    $display("--- 1. state after reset -------------------------------------");
    axi_read(A_STAT, rd);
    chk(rd == 32'd0, "STAT reads 0 after reset (idle, no done)");
    axi_read(A_RES_LO, rd);
    chk(rd == 32'd0, "RES_LO reads 0 after reset");
    axi_read(A_RES_HI, rd);
    chk(rd == 32'd0, "RES_HI reads 0 after reset");
    axi_read(A_CMD, rd);
    chk(rd == 32'd0, "write-only CMD reads back 0");
    axi_read(5'h1C, rd);
    chk(rd == 32'd0, "unmapped 0x1C reads 0");
    axi_write(5'h1C, 32'hDEAD_BEEF);
    chk(1'b1, "unmapped write completes with OKAY");

    $display("--- 2. NOP: done becomes sticky, cleared by RES_LO read -------");
    axi_write(A_CMD, {OP_NOP, 28'd0});
    axi_read(A_STAT, st);
    chk(st[1] == 1'b1, "STAT.done set after NOP");
    axi_read(A_STAT, st);
    chk(st[1] == 1'b1, "STAT.done still set (sticky) on a second read");
    axi_read(A_RES_HI, hi);
    chk(hi[31] == 1'b1, "RES_HI.done set (poll register)");
    axi_read(A_RES_LO, lo);
    axi_read(A_STAT, st);
    chk(st[1] == 1'b0, "STAT.done cleared by the RES_LO read");

    $display("--- 3. key load + RESET, STAT.busy during the long op ---------");
    fh = $fopen(tracefile, "r");
    if (fh == 0) $fatal(1, "cannot open trace %s", tracefile);

    // load the first 243 keys straight from the trace
    for (r = 0; r < 243; r = r + 1) begin
      if ($fscanf(fh, "%d %h %h %h %h\n", top, fa, fb, fc_h, fd) != 5)
        $fatal(1, "short trace");
      if (top != T_LOAD_KEY) $fatal(1, "expected LOAD_KEY at record %0d", r);
      load_key(fa[8:0], fb[62:0]);
    end
    chk(1'b1, "243 ZKEY entries loaded over the bus");
    nops = 243;

    axi_write(A_CMD, {OP_RESET, 28'd0});          // ~164 cycles
    axi_read(A_STAT, st);
    chk(st[0] == 1'b1, "STAT.busy set while RESET runs");
    chk(st[1] == 1'b0, "STAT.done clear while RESET runs");
    poll_done();
    axi_read(A_STAT, st);
    chk(st[0] == 1'b0, "STAT.busy clear after RESET");
    axi_read(A_RES_LO, lo);
    axi_read(A_STAT, st);
    chk(lo != 32'd0, "RES_LO holds a non-zero empty-board hash after RESET");
    chk(st[1] == 1'b0, "STAT.done cleared again by the RES_LO read");

    $display("--- 4. replay the next trace ops over AXI --------------------");
    running = 1;
    while (running) begin
      r = $fscanf(fh, "%d %h %h %h %h\n", top, fa, fb, fc_h, fd);
      if (r != 5) running = 0;
      else begin
        nops = nops + 1;
        case (top)
          T_LOAD_KEY: load_key(fa[8:0], fb[62:0]);
          T_RESET: begin
            axi_write(A_CMD, {OP_RESET, 28'd0});
            poll_done();
            axi_read(A_RES_LO, lo);
          end
          T_MOVE: begin
            axi_write(A_CMD, {OP_MOVE, 19'd0, fb[1:0], fa[6:0]});
            get_result(got_fc, got_h);
            if (got_h !== fc_h) begin
              errors = errors + 1;
              $display("FAIL: op %0d MOVE pos=%0d exp hash %016h got %016h",
                       nops, fa[6:0], fc_h, got_h);
            end
          end
          T_USEFUL: begin
            axi_write(A_CMD, {OP_USEFUL, 19'd0, fb[1:0], fa[6:0]});
            get_result(got_fc, got_h);
            if ((got_fc !== fd[1:0]) || (got_h !== fc_h)) begin
              errors = errors + 1;
              $display("FAIL: op %0d USEFUL pos=%0d exp {f,c}=%02b h=%016h got %02b %016h",
                       nops, fa[6:0], fd[1:0], fc_h, got_fc, got_h);
            end
          end
          default: begin
            errors = errors + 1;
            $display("FAIL: unknown trace opcode %0d", top);
          end
        endcase
        if (nops >= SMOKE_OPS) running = 0;
      end
    end
    $fclose(fh);
    chk(errors == 0, $sformatf("%0d trace ops replayed over AXI4-Lite", nops));

    $display("");
    $display("=============================================================");
    if (errors == 0) $display(" PASS - go_useful_accel AXI4-Lite smoke test");
    else             $display(" FAIL (%0d errors)", errors);
    $display("=============================================================");
    if (errors != 0) $fatal(1, "FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("FAIL: global watchdog expired");
    $fatal(1, "timeout");
  end

endmodule

`default_nettype wire
