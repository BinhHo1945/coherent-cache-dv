// Asynchronous (dual-clock) FIFO with first-word fall-through read
// (p1/spec.md sections 3, 5, 7). Gray-coded pointers cross domains through 2-FF
// synchronizers; full/empty are registered in their own domain.
module async_fifo #(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = 16,
  parameter int ADDR_W     = $clog2(DEPTH)  // derived, do not override (sec. 3)
) (
  input  logic                  wclk,
  input  logic                  rclk,
  input  logic                  wrst_n,
  input  logic                  rrst_n,
  input  logic                  wr_en,
  input  logic [DATA_WIDTH-1:0] wr_data,
  output logic                  full,
  output logic                  overflow,
  input  logic                  rd_en,
  output logic [DATA_WIDTH-1:0] rd_data,
  output logic                  empty,
  output logic                  underflow
);

  // Sec. 3: illegal parameters are an elaboration-time fatal error.
  // Quartus Prime Standard/Lite does not accept $fatal in a generate block, so the
  // checks are hidden from Quartus (QUARTUS_SYNTH is set in the .qsf). Simulation
  // and lint still enforce them; the Quartus projects pin legal parameter values.
`ifndef QUARTUS_SYNTH
  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad_depth
    $fatal(1, "async_fifo: DEPTH=%0d must be a power of 2 and >= 2", DEPTH);
  end
  if (DATA_WIDTH < 1) begin : g_bad_width
    $fatal(1, "async_fifo: DATA_WIDTH=%0d must be >= 1", DATA_WIDTH);
  end
  if (ADDR_W != $clog2(DEPTH)) begin : g_bad_addr_w
    $fatal(1, "async_fifo: ADDR_W must not be overridden");
  end
`endif

  // ---------------------------------------------------------------------------
  // Write domain (wclk): binary pointer and gray pointer, ADDR_W+1 bits each
  // ---------------------------------------------------------------------------
  logic [ADDR_W:0] wbin;
  logic [ADDR_W:0] wbin_next;
  logic [ADDR_W:0] wgray_next;
  logic [ADDR_W:0] wptr_gray;   // A-05: name fixed, registered in wclk domain
  logic            wr_accept;
  logic            full_next;

  // C-02: a write is accepted iff wr_en && !full (registered, pre-edge flag).
`ifdef BUG_WRITE_WHEN_FULL
  // Injected bug: write accepted even while full (overwrites unread data).
  assign wr_accept  = wr_en;
`else
  assign wr_accept  = wr_en && !full;
`endif
  assign wbin_next  = wbin + (ADDR_W + 1)'(wr_accept);
`ifdef BUG_GRAY_BINARY
  // Injected bug: the binary pointer is registered and sent across domains as-is.
  assign wgray_next = wbin_next;
`else
  assign wgray_next = (wbin_next >> 1) ^ wbin_next;  // binary -> gray
`endif

  always_ff @(posedge wclk) begin
    if (!wrst_n) begin
      wbin      <= '0;
      wptr_gray <= '0;
      full      <= 1'b0;        // C-05
      overflow  <= 1'b0;        // C-05; C-08: no pulse for wr_en sampled in reset
    end else begin
      wbin      <= wbin_next;
      wptr_gray <= wgray_next;  // A-05: changes by at most one bit per wclk edge
      full      <= full_next;   // A-02: registered, computed from the NEXT pointer
      overflow  <= wr_en && !wr_accept;  // C-04, A-08: 1-cycle pulse, wclk domain
    end
  end

  // ---------------------------------------------------------------------------
  // Read domain (rclk): binary pointer and gray pointer, ADDR_W+1 bits each
  // ---------------------------------------------------------------------------
  logic [ADDR_W:0] rbin;
  logic [ADDR_W:0] rbin_next;
  logic [ADDR_W:0] rgray_next;
  logic [ADDR_W:0] rptr_gray;   // A-05: name fixed, registered in rclk domain
  logic            rd_accept;
  logic            empty_next;

  // C-02: a read is accepted iff rd_en && !empty (registered, pre-edge flag).
  assign rd_accept  = rd_en && !empty;
  assign rbin_next  = rbin + (ADDR_W + 1)'(rd_accept);
`ifdef BUG_GRAY_BINARY
  // Injected bug: the binary pointer is registered and sent across domains as-is.
  assign rgray_next = rbin_next;
`else
  assign rgray_next = (rbin_next >> 1) ^ rbin_next;  // binary -> gray
`endif

  always_ff @(posedge rclk) begin
    if (!rrst_n) begin
      rbin      <= '0;
      rptr_gray <= '0;
      empty     <= 1'b1;        // C-05
      underflow <= 1'b0;        // C-05; C-08: no pulse for rd_en sampled in reset
    end else begin
      rbin      <= rbin_next;
      rptr_gray <= rgray_next;  // A-05: changes by at most one bit per rclk edge
      empty     <= empty_next;  // A-02: registered, computed from the NEXT pointer
      underflow <= rd_en && !rd_accept;  // C-04, A-08: 1-cycle pulse, rclk domain
    end
  end

  // ---------------------------------------------------------------------------
  // CDC (A-05): each gray pointer is synchronized into the other domain by 2 FFs.
  // Only gray-coded values cross, so a sample taken during a change is either the
  // old or the new pointer (one bit differs). The *_q1 stage may go metastable on
  // silicon; it is never used by any logic other than the *_q2 stage.
  // ---------------------------------------------------------------------------
  logic [ADDR_W:0] rgray_wq1;   // rptr_gray in wclk domain, stage 1
  logic [ADDR_W:0] rgray_wq2;   // rptr_gray in wclk domain, stage 2 (safe to use)
  logic [ADDR_W:0] wgray_rq1;   // wptr_gray in rclk domain, stage 1
  logic [ADDR_W:0] wgray_rq2;   // wptr_gray in rclk domain, stage 2 (safe to use)

  always_ff @(posedge wclk) begin
    if (!wrst_n) begin
      rgray_wq1 <= '0;
      rgray_wq2 <= '0;
    end else begin
      rgray_wq1 <= rptr_gray;
      rgray_wq2 <= rgray_wq1;
    end
  end

  always_ff @(posedge rclk) begin
    if (!rrst_n) begin
      wgray_rq1 <= '0;
      wgray_rq2 <= '0;
    end else begin
      wgray_rq1 <= wptr_gray;
      wgray_rq2 <= wgray_rq1;
    end
  end

  // ---------------------------------------------------------------------------
  // Storage: written in wclk domain, read combinationally in rclk domain.
  // Not reset (C-05: memory array is not cleared).
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] mem [DEPTH];

  // C-03: a rejected write does not overwrite any entry. C-08: no write in reset.
  always_ff @(posedge wclk) begin
    if (wrst_n && wr_accept) mem[wbin[ADDR_W-1:0]] <= wr_data;
  end

  // C-01 FWFT: rd_data is the entry at the read address, no read latency.
  // Don't-care while empty (C-06). The entry is stable while it is readable:
  // the write side cannot reach it until the read pointer has moved past it (A-04).
  assign rd_data = mem[rbin[ADDR_W-1:0]];

  // ---------------------------------------------------------------------------
  // Flags (A-02, A-03, A-04)
  // ---------------------------------------------------------------------------
  // full: the next write gray pointer equals the synchronized read gray pointer with
  // its top two bits inverted (pointers DEPTH apart, gray encoding). Because full is
  // registered from the NEXT pointer, it rises at the same edge as the write that
  // fills the FIFO (no extra latency, A-02). The synchronized read pointer can only
  // lag the true one, so full may stay high too long but never falls early (A-04).
  // Fall latency after a read: rptr_gray at the read edge, then 2 synchronizer
  // edges, then the full register: by the 3rd wclk edge after the read (A-03).
`ifdef BUG_WRAP_MSB
  // Injected bug: binary full rule applied to gray pointers (only the MSB inverted,
  // the second-MSB inversion that the gray wrap needs is ignored).
  localparam logic [ADDR_W:0] FULL_MASK = (ADDR_W + 1)'(1) << ADDR_W;
`else
  localparam logic [ADDR_W:0] FULL_MASK = (ADDR_W + 1)'(3) << (ADDR_W - 1);
`endif

  assign full_next = (wgray_next == (rgray_wq2 ^ FULL_MASK));

  // empty: the next read gray pointer equals the synchronized write gray pointer.
  // Rises at the edge of the last pop (A-02); the synchronized write pointer can only
  // lag, so empty never falls early (A-04); falls by the 3rd rclk edge after the
  // accepting write edge (A-03), same chain as above.
  assign empty_next = (rgray_next == wgray_rq2);

endmodule
