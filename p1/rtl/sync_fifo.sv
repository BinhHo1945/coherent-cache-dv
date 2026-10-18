// Synchronous FIFO with first-word fall-through read (p1/spec.md sections 3, 5, 6).
module sync_fifo #(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = 16,
  parameter int ADDR_W     = $clog2(DEPTH)  // derived, do not override (sec. 3)
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  wr_en,
  input  logic [DATA_WIDTH-1:0] wr_data,
  output logic                  full,
  output logic                  overflow,
  input  logic                  rd_en,
  output logic [DATA_WIDTH-1:0] rd_data,
  output logic                  empty,
  output logic                  underflow,
  output logic [ADDR_W:0]       count
);

  // Sec. 3: illegal parameters are an elaboration-time fatal error.
  // Quartus Prime Standard/Lite does not accept $fatal in a generate block, so the
  // checks are hidden from Quartus (QUARTUS_SYNTH is set in the .qsf). Simulation
  // and lint still enforce them; the Quartus projects pin legal parameter values.
`ifndef QUARTUS_SYNTH
  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad_depth
    $fatal(1, "sync_fifo: DEPTH=%0d must be a power of 2 and >= 2", DEPTH);
  end
  if (DATA_WIDTH < 1) begin : g_bad_width
    $fatal(1, "sync_fifo: DATA_WIDTH=%0d must be >= 1", DATA_WIDTH);
  end
  if (ADDR_W != $clog2(DEPTH)) begin : g_bad_addr_w
    $fatal(1, "sync_fifo: ADDR_W must not be overridden");
  end
`endif

  // S-01: pointers are ADDR_W+1 bits; the low ADDR_W bits index the memory.
  logic [ADDR_W:0] wptr;
  logic [ADDR_W:0] rptr;

  // C-02: accept decisions use the current (pre-edge) flags only.
  // S-03: write and read are decided independently, so a simultaneous read and write
  // gives: mid -> both accepted; empty -> write only (underflow); full -> read only
  // (overflow). A read in the same cycle never makes room for a write while full.
  logic wr_accept;
  logic rd_accept;
`ifdef BUG_RDWR_FULL
  // Injected bug: write while full is accepted if a read happens in the same cycle.
  assign wr_accept = wr_en && (!full || rd_en);
`else
  assign wr_accept = wr_en && !full;
`endif
  assign rd_accept = rd_en && !empty;

  // S-02: flags are combinational functions of the registered pointers (zero latency).
  assign empty = (wptr == rptr);
`ifdef BUG_FULL_OFFBYONE
  // Injected bug: full asserts one entry early (at DEPTH-1).
  assign full  = (count == (ADDR_W + 1)'(DEPTH - 1));
`else
  assign full  = (wptr[ADDR_W-1:0] == rptr[ADDR_W-1:0]) && (wptr[ADDR_W] != rptr[ADDR_W]);
`endif

  // S-01, S-04: occupancy is the pointer difference modulo 2^(ADDR_W+1).
  assign count = wptr - rptr;

  // Pointers and pulse registers, synchronous active-low reset (sec. 2, C-05).
  // C-08: enables sampled during reset have no effect (reset branch has priority).
  // C-04: overflow/underflow are registered, high for the one cycle after a rejected
  // attempt; consecutive rejected attempts give consecutive pulse cycles.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr      <= '0;
      rptr      <= '0;
      overflow  <= 1'b0;
      underflow <= 1'b0;
    end else begin
      if (wr_accept) wptr <= wptr + 1'b1;
      if (rd_accept) rptr <= rptr + 1'b1;
      overflow  <= wr_en && !wr_accept;
      underflow <= rd_en && !rd_accept;
    end
  end

  // Storage. Not reset: C-05 says the memory array is not cleared.
  logic [DATA_WIDTH-1:0] mem [DEPTH];

  // C-03: a rejected write does not overwrite any entry. C-08: no write in reset.
  always_ff @(posedge clk) begin
    if (rst_n && wr_accept) mem[wptr[ADDR_W-1:0]] <= wr_data;
  end

  // C-01 FWFT: rd_data is the element at the read pointer, no read latency.
  // Don't-care while empty (C-06).
  assign rd_data = mem[rptr[ADDR_W-1:0]];

endmodule
