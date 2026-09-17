// ---------------------------------------------------------------------------
// go_useful_accel.sv
//
// Thin AXI4-Lite (32-bit) slave wrapper around go_useful_core.
//
//   offset  name      dir  fields
//   0x00    CMD       W    [31:28] op, [8:7] color, [6:0] pos - write starts op
//   0x04    STAT      R    [0] busy, [1] done (sticky), [2] useful_cond,
//                          [3] fast_path
//   0x08    RES_LO    R    hash [31:0]
//   0x0C    RES_HI    R    [30:0] hash [62:32], [31] done (sticky)
//   0x10    KEY_LO    W    key [31:0]
//   0x14    KEY_HI    W    key [62:32]
//   0x18    KEY_IDX   W    [8:0] index = sq*3 + color; the write commits the key
//
// Assumptions (see docs/SPEC.md):
//   * clk / rst_n are the AXI ACLK / ARESETn; reset is treated as SYNCHRONOUS
//     and active low, matching the core.
//   * WSTRB is ignored (all register writes are full 32-bit words).
//   * RESP is always OKAY.  Unmapped reads return 0, unmapped writes are
//     dropped (but still complete with OKAY).
//   * A write to KEY_IDX issues LOAD_KEY by itself; a CMD write with
//     op = LOAD_KEY (4) also works and uses the last KEY_IDX written.
//   * The sticky done bit is set by the core's done pulse and cleared by a
//     read of RES_LO or by the start of a new command.
//   * RES_LO/RES_HI hold the USEFUL candidate hash after a USEFUL, and the
//     committed board hash after any other op.
//   * One outstanding transaction per channel; a CMD/KEY_IDX write to a busy
//     core back-pressures the write channel (BVALID is withheld) rather than
//     being dropped.
//
// CRITICAL PATH: entirely inside go_useful_core (see that file's header); the
// wrapper is a handful of registers and a 3-entry read mux.
// ---------------------------------------------------------------------------
`default_nettype none

module go_useful_accel #(
    parameter int ADDRW = 5,          // byte address bits decoded (0x00..0x18)
    parameter int DATAW = 32,         // AXI4-Lite data width (fixed at 32)
    parameter int POSW  = 7,
    parameter int ZW    = 63,
    parameter int ZAW   = 9
) (
    input  wire              clk,            // AXI ACLK, 100 MHz target
    input  wire              rst_n,          // AXI ARESETn (used synchronously)

    // AXI4-Lite write address channel
    input  wire [ADDRW-1:0]  s_axi_awaddr,   // byte address
    input  wire [2:0]        s_axi_awprot,   // ignored
    input  wire              s_axi_awvalid,
    output wire              s_axi_awready,

    // AXI4-Lite write data channel
    input  wire [DATAW-1:0]  s_axi_wdata,
    input  wire [DATAW/8-1:0] s_axi_wstrb,   // ignored
    input  wire              s_axi_wvalid,
    output wire              s_axi_wready,

    // AXI4-Lite write response channel
    output logic [1:0]       s_axi_bresp,    // always OKAY
    output logic             s_axi_bvalid,
    input  wire              s_axi_bready,

    // AXI4-Lite read address channel
    input  wire [ADDRW-1:0]  s_axi_araddr,
    input  wire [2:0]        s_axi_arprot,   // ignored
    input  wire              s_axi_arvalid,
    output wire              s_axi_arready,

    // AXI4-Lite read data channel
    output logic [DATAW-1:0] s_axi_rdata,
    output logic [1:0]       s_axi_rresp,    // always OKAY
    output logic             s_axi_rvalid,
    input  wire              s_axi_rready
);

  // ------------------------------------------------------------- constants
  localparam logic [ADDRW-1:0] A_CMD     = 5'h00;
  localparam logic [ADDRW-1:0] A_STAT    = 5'h04;
  localparam logic [ADDRW-1:0] A_RES_LO  = 5'h08;
  localparam logic [ADDRW-1:0] A_RES_HI  = 5'h0C;
  localparam logic [ADDRW-1:0] A_KEY_LO  = 5'h10;
  localparam logic [ADDRW-1:0] A_KEY_HI  = 5'h14;
  localparam logic [ADDRW-1:0] A_KEY_IDX = 5'h18;

  localparam logic [3:0] OP_NOP      = 4'd0;
  localparam logic [3:0] OP_LOAD_KEY = 4'd4;

  localparam logic [1:0] RESP_OKAY = 2'b00;

  // AXI4-Lite signals this slave deliberately ignores: PROT (no protection
  // checking) and WSTRB (all register writes are full 32-bit words).
  wire _unused_ok = &{1'b0, s_axi_awprot, s_axi_arprot, s_axi_wstrb};

  // --------------------------------------------------------- core instance
  logic            cmd_valid;
  wire             cmd_ready;
  logic [3:0]      cmd_op;
  logic [POSW-1:0] cmd_pos;
  logic [1:0]      cmd_color;
  wire  [ZW-1:0]   cmd_key;
  logic [ZAW-1:0]  cmd_key_idx;
  wire             core_busy;
  wire             core_done;
  wire             core_fast;
  wire             core_cond;
  wire  [ZW-1:0]   core_res_hash;
  wire  [ZW-1:0]   core_cur_hash;

  // wrapper-held key staging registers
  logic [31:0] key_lo;
  logic [30:0] key_hi;
  assign cmd_key = {key_hi, key_lo};

  go_useful_core u_core (
      .clk         (clk),
      .rst_n       (rst_n),
      .cmd_valid   (cmd_valid),
      .cmd_ready   (cmd_ready),
      .cmd_op      (cmd_op),
      .cmd_pos     (cmd_pos),
      .cmd_color   (cmd_color),
      .cmd_key     (cmd_key),
      .cmd_key_idx (cmd_key_idx),
      .busy        (core_busy),
      .done        (core_done),
      .res_fast    (core_fast),
      .res_cond    (core_cond),
      .res_hash    (core_res_hash),
      .cur_hash    (core_cur_hash)
  );

  // ------------------------------------------------------- result capture
  logic          done_sticky;
  logic          st_fast, st_cond;
  logic [ZW-1:0] st_hash;
  logic          op_was_useful;          // selects which hash to latch

  // --------------------------------------------------------- write channel
  typedef enum logic [1:0] { W_IDLE, W_CMD, W_RESP } wstate_e;
  wstate_e wstate;

  wire wr_accept = (wstate == W_IDLE) && s_axi_awvalid && s_axi_wvalid;

  // AXI permits READY to depend on VALID; VALID never depends on READY here.
  assign s_axi_awready = wr_accept;
  assign s_axi_wready  = wr_accept;

  // a write to CMD or KEY_IDX launches a core command
  function automatic logic launches(input logic [ADDRW-1:0] a);
    launches = (a == A_CMD) || (a == A_KEY_IDX);
  endfunction

  // ---------------------------------------------------------- read channel
  typedef enum logic [0:0] { R_IDLE, R_RESP } rstate_e;
  rstate_e rstate;

  logic [ADDRW-1:0] raddr_q;
  assign s_axi_arready = (rstate == R_IDLE);

  logic [DATAW-1:0] rdata_mux;
  always_comb begin
    unique case (raddr_q)
      A_STAT:   rdata_mux = {28'd0, st_fast, st_cond, done_sticky, core_busy};
      A_RES_LO: rdata_mux = st_hash[31:0];
      A_RES_HI: rdata_mux = {done_sticky, st_hash[62:32]};
      default:  rdata_mux = 32'd0;      // unmapped / write-only -> 0
    endcase
  end

  // ----------------------------------------------------------- sequential
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wstate        <= W_IDLE;
      rstate        <= R_IDLE;
      raddr_q       <= '0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= RESP_OKAY;
      s_axi_rvalid  <= 1'b0;
      s_axi_rresp   <= RESP_OKAY;
      s_axi_rdata   <= '0;
      cmd_valid     <= 1'b0;
      cmd_op        <= OP_NOP;
      cmd_pos       <= '0;
      cmd_color     <= 2'd0;
      cmd_key_idx   <= '0;
      key_lo        <= '0;
      key_hi        <= '0;
      done_sticky   <= 1'b0;
      st_fast       <= 1'b0;
      st_cond       <= 1'b0;
      st_hash       <= '0;
      op_was_useful <= 1'b0;
    end else begin
      // ---- result capture ------------------------------------------------
      if (core_done) begin
        done_sticky <= 1'b1;
        st_fast     <= core_fast;
        st_cond     <= core_cond;
        st_hash     <= op_was_useful ? core_res_hash : core_cur_hash;
      end

      // ---- write channel -------------------------------------------------
      unique case (wstate)
        W_IDLE: begin
          if (wr_accept) begin
            unique case (s_axi_awaddr)
              A_KEY_LO:  key_lo <= s_axi_wdata;
              A_KEY_HI:  key_hi <= s_axi_wdata[30:0];
              A_KEY_IDX: cmd_key_idx <= s_axi_wdata[ZAW-1:0];
              default:   ;                      // CMD and unmapped: nothing
            endcase
            if (launches(s_axi_awaddr)) begin
              // launch: CMD carries its own opcode, KEY_IDX implies LOAD_KEY
              if (s_axi_awaddr == A_CMD) begin
                cmd_op        <= s_axi_wdata[31:28];
                cmd_pos       <= s_axi_wdata[POSW-1:0];
                cmd_color     <= s_axi_wdata[8:7];
                op_was_useful <= (s_axi_wdata[31:28] == 4'd3);
              end else begin
                cmd_op        <= OP_LOAD_KEY;
                op_was_useful <= 1'b0;
              end
              cmd_valid   <= 1'b1;
              done_sticky <= 1'b0;                // new command clears done
              wstate      <= W_CMD;
            end else begin
              s_axi_bvalid <= 1'b1;
              wstate       <= W_RESP;
            end
          end
        end

        W_CMD: begin
          if (cmd_ready) begin                    // command accepted by core
            cmd_valid    <= 1'b0;
            s_axi_bvalid <= 1'b1;
            wstate       <= W_RESP;
          end
        end

        W_RESP: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            wstate       <= W_IDLE;
          end
        end

        default: wstate <= W_IDLE;
      endcase

      // ---- read channel --------------------------------------------------
      unique case (rstate)
        R_IDLE: begin
          if (s_axi_arvalid) begin
            raddr_q <= s_axi_araddr;
            rstate  <= R_RESP;
          end
        end

        R_RESP: begin
          s_axi_rvalid <= 1'b1;
          s_axi_rdata  <= rdata_mux;
          if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            rstate       <= R_IDLE;
            if (raddr_q == A_RES_LO) done_sticky <= 1'b0;  // results consumed
          end
        end

        default: rstate <= R_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n) begin
      if (s_axi_bvalid && (s_axi_bresp !== RESP_OKAY))
        $error("%m: unexpected write response");
      if (cmd_valid && !cmd_ready && (wstate != W_CMD))
        $error("%m: cmd_valid asserted outside W_CMD");
    end
  end
`endif

endmodule

`default_nettype wire
