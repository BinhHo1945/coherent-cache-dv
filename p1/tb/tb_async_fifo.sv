// Directed self-checking testbench for async_fifo (p1/test_plan.md, tests A1-A12).
//
// Timing conventions (per clock domain):
// - Inputs are driven 1 ns after the posedge of their own clock.
// - Checks sample outputs at the negedge of the observing clock, i.e. just before the
//   next posedge. The value seen there is the value that next posedge will sample.
// - Drivers that must obey "wr_en only when full=0 / rd_en only when empty=0" read the
//   flag at posedge + 1 ns. full/empty are registered in their own domain (A-02), so the
//   value at posedge + 1 ns is the value present just before the next posedge, i.e. the
//   value the DUT uses to accept or reject the operation being driven.
// - Acceptance is decided from the negedge sample: accepted = en && flag==0 just before
//   the edge (C-02).
// Each test keeps its own expected values (no shared reference model).
`timescale 1ns/1ps

`ifndef TB_DEPTH
  `define TB_DEPTH 16
`endif
`ifndef TB_DATA_WIDTH
  `define TB_DATA_WIDTH 32
`endif

module tb_async_fifo;

  localparam int DEPTH = `TB_DEPTH;
  localparam int W     = `TB_DATA_WIDTH;
  localparam int AW    = $clog2(DEPTH);
  localparam int N_SYNC_BOUND = 3;  // A-03 flag deassertion bound (edges)

  typedef logic [W-1:0] data_t;

  // ---------------------------------------------------------------------------
  // Clocks: generators read the half-period variables every half cycle.
  // set_clocks() parks both generators (clocks low), updates the periods and the
  // rclk phase offset, then restarts them together.
  // ---------------------------------------------------------------------------
  logic wclk = 1'b0;
  logic rclk = 1'b0;
  real  w_half  = 5.0;
  real  r_half  = 5.0;
  real  r_phase = 0.0;
  bit   clk_on  = 1'b0;

  always begin
    wait (clk_on);
    wclk = 1'b0;
    while (clk_on) begin
      #(w_half) wclk = 1'b1;
      #(w_half) wclk = 1'b0;
    end
  end

  always begin
    wait (clk_on);
    rclk = 1'b0;
    #(r_phase);
    while (clk_on) begin
      #(r_half) rclk = 1'b1;
      #(r_half) rclk = 1'b0;
    end
  end

  task automatic set_clocks(input real w_period, input real r_period, input real phase);
    real park;
    park = 4.0 * ((w_half > r_half) ? w_half : r_half) + r_phase + 1.0;
    clk_on = 1'b0;
    #(park);            // both generators have finished their current period
    w_half  = w_period / 2.0;
    r_half  = r_period / 2.0;
    r_phase = phase;
    clk_on  = 1'b1;
  endtask

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic  wrst_n;
  logic  rrst_n;
  logic  wr_en;
  data_t wr_data;
  logic  full;
  logic  overflow;
  logic  rd_en;
  data_t rd_data;
  logic  empty;
  logic  underflow;

  async_fifo #(.DATA_WIDTH(W), .DEPTH(DEPTH)) dut (
    .wclk      (wclk),
    .rclk      (rclk),
    .wrst_n    (wrst_n),
    .rrst_n    (rrst_n),
    .wr_en     (wr_en),
    .wr_data   (wr_data),
    .full      (full),
    .overflow  (overflow),
    .rd_en     (rd_en),
    .rd_data   (rd_data),
    .empty     (empty),
    .underflow (underflow)
  );

  // ---------------------------------------------------------------------------
  // Bookkeeping
  // ---------------------------------------------------------------------------
  int    errors   = 0;
  int    n_checks = 0;
  string cur_test = "-";

  // Generic compare. Uses !== so X/Z on a DUT output is an error.
  function automatic void chk(string spec_id, string what,
                              logic [63:0] exp, logic [63:0] got);
    n_checks++;
    if (got !== exp) begin
      errors++;
      $display("[ERR][%s] t=%0t exp=%0h got=%0h (%s) %s",
               cur_test, $realtime, exp, got, spec_id, what);
    end
  endfunction

  // Unconditional failure (stall / timeout inside a test).
  function automatic void fail(string spec_id, string what);
    n_checks++;
    errors++;
    $display("[ERR][%s] t=%0t exp=- got=- (%s) %s", cur_test, $realtime, spec_id, what);
  endfunction

  // Head-of-queue data check. Skipped while the DUT reports empty=1 (C-06).
  function automatic void chk_head(string spec_id, string what, data_t exp);
    if (empty === 1'b0) chk(spec_id, what, exp, rd_data);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive helpers (one cycle of the named domain)
  // ---------------------------------------------------------------------------
  // Drive at wclk posedge + 1 ns, return at the following wclk negedge.
  task automatic wcyc(input logic we, input data_t wd);
    @(posedge wclk);
    #1;
    wr_en   = we;
    wr_data = wd;
    @(negedge wclk);
  endtask

  // Drive at rclk posedge + 1 ns, return at the following rclk negedge.
  task automatic rcyc(input logic re);
    @(posedge rclk);
    #1;
    rd_en = re;
    @(negedge rclk);
  endtask

  // Reset both domains (A-06): wrst_n and rrst_n asserted together and held for
  // more than 4 rising edges of each clock; each is released 1 ns after a posedge
  // of its own clock. Enables are low throughout. Returns when both are released.
  task automatic do_reset();
    wr_en   = 1'b0;
    rd_en   = 1'b0;
    wr_data = '0;
    wrst_n  = 1'b0;
    rrst_n  = 1'b0;
    fork
      repeat (5) @(posedge wclk);
      repeat (5) @(posedge rclk);
    join
    fork
      begin @(posedge wclk); #1; wrst_n = 1'b1; end
      begin @(posedge rclk); #1; rrst_n = 1'b1; end
    join
  endtask

  // ---------------------------------------------------------------------------
  // Tests (one task per test plan row)
  // ---------------------------------------------------------------------------
  // Stimulus helper: write n words base, base+1, ... asserting wr_en only while
  // full=0. Stops with an error if no progress is possible. Returns at wclk posedge+1
  // after the last write was sampled (wr_en already low).
  task automatic write_n(input int n, input int base, input string tag);
    int k;
    int guard;
    k     = 0;
    guard = 0;
    while (k < n && guard < 20 * n + 20) begin
      @(posedge wclk);
      #1;
      wr_en   = (full === 1'b0);
      wr_data = data_t'(base + k);
      @(negedge wclk);
      if (wr_en && full === 1'b0) k++;  // accepted at the next posedge
      guard++;
    end
    @(posedge wclk);
    #1;
    wr_en = 1'b0;
    if (k < n) fail("A-04", $sformatf("%s: write stalled after %0d of %0d words", tag, k, n));
  endtask

  // Stimulus + check helper: read n words while empty=0 and check that they are
  // base, base+1, ... in order (C-07). If chk_empty_after, empty must be 1 right
  // after the last pop (A-02: empty rises with no extra latency). Returns at the
  // rclk negedge after the last pop.
  task automatic read_n(input int n, input int base, input string tag,
                        input bit chk_empty_after);
    int k;
    int guard;
    k     = 0;
    guard = 0;
    while (k < n && guard < 20 * n + 20) begin
      @(posedge rclk);
      #1;
      rd_en = (empty === 1'b0);
      @(negedge rclk);
      if (rd_en && empty === 1'b0) begin
        chk_head("C-07", $sformatf("%s: element %0d", tag, k), data_t'(base + k));
        k++;                              // accepted at the next posedge
      end
      guard++;
    end
    @(posedge rclk);
    #1;
    rd_en = 1'b0;
    @(negedge rclk);
    if (k < n) fail("A-04", $sformatf("%s: read stalled after %0d of %0d words", tag, k, n));
    else if (chk_empty_after)
      chk("A-02", $sformatf("%s: empty right after last pop", tag), 1'b1, empty);
  endtask

  // Wait (up to max_edges rclk negedges) until empty has the given value.
  task automatic wait_empty(input logic val, input int max_edges, input string what);
    for (int i = 0; i < max_edges; i++) begin
      @(negedge rclk);
      if (empty === val) return;
    end
    fail("A-03", $sformatf("%s: empty did not become %0b within %0d rclk edges",
                           what, val, max_edges));
  endtask

  // Wait (up to max_edges wclk negedges) until full has the given value.
  task automatic wait_full(input logic val, input int max_edges, input string what);
    for (int i = 0; i < max_edges; i++) begin
      @(negedge wclk);
      if (full === val) return;
    end
    fail("A-03", $sformatf("%s: full did not become %0b within %0d wclk edges",
                           what, val, max_edges));
  endtask

  // A1: initial state after reset, checked in both domains for 4 cycles each.
  task automatic a1_reset();
    fork
      for (int i = 0; i < 4; i++) begin
        @(negedge wclk);
        chk("C-05", $sformatf("full after reset, wclk cycle %0d", i),     1'b0, full);
        chk("C-05", $sformatf("overflow after reset, wclk cycle %0d", i), 1'b0, overflow);
      end
      for (int i = 0; i < 4; i++) begin
        @(negedge rclk);
        chk("C-05", $sformatf("empty after reset, rclk cycle %0d", i),     1'b1, empty);
        chk("C-05", $sformatf("underflow after reset, rclk cycle %0d", i), 1'b0, underflow);
      end
    join
  endtask

  // A2: write one element; empty must fall no later than the 3rd rclk edge after
  // the accepting wclk edge (a coincident rclk edge is not counted), and must stay
  // 1 at every rclk edge up to and including that wclk edge (A-04). Then read it.
  task automatic a2_write_one();
    data_t d;
    real   t_acc;
    d     = data_t'('hA2A2_0001);
    t_acc = 1.0e18;  // "not yet accepted"
    fork
      begin : writer
        @(posedge wclk);
        #1;
        wr_en   = 1'b1;
        wr_data = d;
        @(negedge wclk);
        chk("C-02", "full=0 so the write is accepted", 1'b0, full);
        @(posedge wclk);
        t_acc = $realtime;   // accepting wclk edge
        #1;
        wr_en = 1'b0;
      end
      begin : observer
        int  n_after;
        real t_edge;
        n_after = 0;
        forever begin
          @(posedge rclk);
          t_edge = $realtime;
          @(negedge rclk);   // value produced by the edge at t_edge
          if (t_edge <= t_acc) begin
            chk("A-04", "empty=1 at rclk edge not after the accepting wclk edge", 1'b1, empty);
          end else begin
            n_after++;
            if (empty === 1'b0) break;
            if (n_after >= N_SYNC_BOUND) begin
              chk("A-03", "empty fell by the 3rd rclk edge after the write", 1'b0, empty);
              break;
            end
          end
        end
        $display("INFO %s empty fell at rclk edge %0d after the write", cur_test, n_after);
      end
    join
    // Read the element back (C-01), then empty rises with no extra latency (A-02).
    @(posedge rclk);
    #1;
    rd_en = 1'b1;
    @(negedge rclk);
    chk("A-04", "empty=0 before the read", 1'b0, empty);
    chk_head("C-01", "read returns the written element", d);
    @(posedge rclk);
    #1;
    rd_en = 1'b0;
    @(negedge rclk);
    chk("A-02", "empty rises right after the pop", 1'b1, empty);
    chk("C-04", "no underflow on accepted read",   1'b0, underflow);
  endtask

  // A3: from reset, write continuously with no reads. full must be 0 while fewer
  // than DEPTH are stored and 1 right after the DEPTH-th accepted write (A-02);
  // it then stays 1. Read back to show nothing was overwritten.
  task automatic a3_fill();
    int base;
    base = 'hA300;
    for (int i = 0; i <= DEPTH; i++) begin
      @(posedge wclk);
      #1;
      wr_en   = (i < DEPTH);
      wr_data = data_t'(base + i);
      @(negedge wclk);
      // i writes accepted so far (one per previous edge).
      chk("A-02", $sformatf("full with %0d stored", i), i == DEPTH, full);
      chk("C-04", $sformatf("no overflow with %0d stored", i), 1'b0, overflow);
    end
    @(posedge wclk);
    #1;
    wr_en = 1'b0;
    for (int i = 0; i < 4; i++) begin
      @(negedge wclk);
      chk("A-04", $sformatf("full stays 1 with no reads, cycle %0d", i), 1'b1, full);
    end
    wait_empty(1'b0, 20, "A3 data visible");
    read_n(DEPTH, base, "no overwrite", 1'b1);
  endtask

  // A4: fill, then read all. FIFO order; empty stays 0 until the last pop and rises
  // right after it; full falls no later than the 3rd wclk edge after the rclk edge
  // that accepted the first pop, and stays 1 at every wclk edge up to that edge.
  task automatic a4_drain();
    int  base;
    real t_pop;
    base  = 'hA400;
    t_pop = 1.0e18;
    write_n(DEPTH, base, "A4 fill");
    @(negedge wclk);
    chk("A-02", "full after DEPTH writes", 1'b1, full);
    wait_empty(1'b0, 20, "A4 data visible");
    repeat (N_SYNC_BOUND) @(negedge rclk);  // let all DEPTH elements cross (A-03), not just the first
    fork
      begin : reader
        for (int i = 0; i <= DEPTH; i++) begin
          @(posedge rclk);
          if (i == 1) t_pop = $realtime;  // edge that accepted the first pop
          #1;
          rd_en = (i < DEPTH);
          @(negedge rclk);
          if (i < DEPTH) begin
            chk("A-04", $sformatf("empty=0 before pop %0d (all data visible)", i), 1'b0, empty);
            chk_head("C-07", $sformatf("FIFO order element %0d", i), data_t'(base + i));
          end else begin
            chk("A-02", "empty rises right after the last pop", 1'b1, empty);
          end
        end
        @(posedge rclk);
        #1;
        rd_en = 1'b0;
      end
      begin : observer
        int  n_after;
        real t_edge;
        n_after = 0;
        forever begin
          @(posedge wclk);
          t_edge = $realtime;
          @(negedge wclk);
          if (t_edge <= t_pop) begin
            chk("A-04", "full=1 at wclk edge not after the first pop", 1'b1, full);
          end else begin
            n_after++;
            if (full === 1'b0) break;
            if (n_after >= N_SYNC_BOUND) begin
              chk("A-03", "full fell by the 3rd wclk edge after the first pop", 1'b0, full);
              break;
            end
          end
        end
        $display("INFO %s full fell at wclk edge %0d after the first pop", cur_test, n_after);
      end
    join
  endtask

  // Streaming transfer of n words with concurrent writer and reader (driver rule:
  // wr_en only when full=0, rd_en only when empty=0). The reader checks every popped
  // word against its own incrementing counter (C-07: no loss, no duplicate, order).
  // No rejected operation is driven, so overflow/underflow must stay 0 (C-04).
  // At the end: empty=1 right after the last pop (A-02) and full=0 within the A-03
  // bound in the write domain.
  task automatic stream(input int n, input int base, input string tag);
    int nw;
    int nr;
    nw = 0;
    nr = 0;
    fork
      begin : writer
        int guard;
        guard = 0;
        while (nw < n && guard < 40 * n + 40) begin
          @(posedge wclk);
          #1;
          wr_en   = (full === 1'b0);
          wr_data = data_t'(base + nw);
          @(negedge wclk);
          chk("C-04", {tag, ": no overflow (no write while full)"}, 1'b0, overflow);
          if (wr_en && full === 1'b0) nw++;
          guard++;
        end
        @(posedge wclk);
        #1;
        wr_en = 1'b0;
        if (nw < n) fail("A-04", $sformatf("%s: writer stalled at %0d of %0d", tag, nw, n));
      end
      begin : reader
        int guard;
        guard = 0;
        while (nr < n && guard < 40 * n + 40) begin
          @(posedge rclk);
          #1;
          rd_en = (empty === 1'b0);
          @(negedge rclk);
          chk("C-04", {tag, ": no underflow (no read while empty)"}, 1'b0, underflow);
          if (rd_en && empty === 1'b0) begin
            chk_head("C-07", $sformatf("%s: word %0d", tag, nr), data_t'(base + nr));
            nr++;
          end
          guard++;
        end
        @(posedge rclk);
        #1;
        rd_en = 1'b0;
        @(negedge rclk);
        if (nr < n) fail("A-04", $sformatf("%s: reader stalled at %0d of %0d", tag, nr, n));
        else chk("A-02", {tag, ": empty right after the last pop"}, 1'b1, empty);
      end
    join
    // full must be 0 by the A-03 bound (3 wclk edges after the last pop). The extra 2
    // edges absorb the phase between the last pop and the return of the reader.
    repeat (N_SYNC_BOUND + 2) @(negedge wclk);
    chk("A-03", {tag, ": full=0 after the transfer"}, 1'b0, full);
  endtask

  // A5-A7: >= 1000 words at the clock ratio set by prepare().
  task automatic a5_write_faster();
    stream(1000, 'h5_0000, "wclk 10 / rclk 30");
  endtask

  task automatic a6_read_faster();
    stream(1000, 'h6_0000, "wclk 30 / rclk 10");
  endtask

  task automatic a7_unrelated_ratio();
    stream(1000, 'h7_0000, "wclk 7 / rclk 5 +1.3");
  endtask

  // A8: read while empty, then write while full. Rejected; underflow pulses for one
  // rclk cycle, overflow for one wclk cycle (C-04, A-08); no state change (C-03).
  task automatic a8_rejected_ops();
    int base;
    int base2;
    base  = 'hA800;
    base2 = 'hA880;
    // --- read while empty ---
    rcyc(1'b1);
    chk("C-04", "no underflow before the attempt is sampled", 1'b0, underflow);
    chk("C-02", "empty=1 so the read is rejected",            1'b1, empty);
    rcyc(1'b0);
    chk("A-08", "underflow pulse in the rclk cycle after the attempt", 1'b1, underflow);
    chk("C-03", "empty unchanged after rejected read",                1'b1, empty);
    rcyc(1'b0);
    chk("C-04", "underflow lasts exactly 1 rclk cycle", 1'b0, underflow);
    rcyc(1'b1);
    rcyc(1'b1);
    chk("C-04", "underflow for 1st of 2 consecutive attempts", 1'b1, underflow);
    rcyc(1'b0);
    chk("C-04", "underflow for 2nd of 2 consecutive attempts", 1'b1, underflow);
    rcyc(1'b0);
    chk("C-04", "underflow ends after consecutive attempts", 1'b0, underflow);
    chk("C-03", "empty unchanged after 3 rejected reads",    1'b1, empty);
    @(negedge wclk);
    chk("A-08", "no overflow from rejected reads", 1'b0, overflow);
    // Read pointer must not have moved: a round trip behaves normally.
    write_n(1, base, "A8 round trip");
    wait_empty(1'b0, 20, "A8 round trip visible");
    read_n(1, base, "after rejected reads", 1'b1);
    // --- write while full ---
    write_n(DEPTH, base2, "A8 fill");
    @(negedge wclk);
    chk("A-02", "full after DEPTH writes", 1'b1, full);
    wcyc(1'b1, data_t'('hDEAD));
    chk("C-04", "no overflow before the attempt is sampled", 1'b0, overflow);
    wcyc(1'b0, '0);
    chk("A-08", "overflow pulse in the wclk cycle after the attempt", 1'b1, overflow);
    chk("C-03", "full unchanged after rejected write",               1'b1, full);
    wcyc(1'b0, '0);
    chk("C-04", "overflow lasts exactly 1 wclk cycle", 1'b0, overflow);
    wcyc(1'b1, data_t'('hBEEF));
    wcyc(1'b1, data_t'('hCAFE));
    chk("C-04", "overflow for 1st of 2 consecutive attempts", 1'b1, overflow);
    wcyc(1'b0, '0);
    chk("C-04", "overflow for 2nd of 2 consecutive attempts", 1'b1, overflow);
    wcyc(1'b0, '0);
    chk("C-04", "overflow ends after consecutive attempts", 1'b0, overflow);
    chk("C-03", "full unchanged after 3 rejected writes",   1'b1, full);
    @(negedge rclk);
    chk("A-08", "no underflow from rejected writes", 1'b0, underflow);
    // Data intact: exactly the DEPTH original words, then empty.
    read_n(DEPTH, base2, "data intact after rejected writes", 1'b1);
  endtask

  // A9 counters. Cross-domain alignment:
  // - a9_w_cnt counts writes accepted at wclk edges; it is incremented by the wclk
  //   monitor at the accepting edge itself, and a9_w_last records that edge's time.
  // - a9_r_cnt / a9_r_last: the same for reads at rclk edges.
  // - The check at an edge at time t uses "accepted strictly before t" in both domains:
  //   the own-domain counter is read before the current edge is counted; the
  //   other-domain counter is corrected by -1 if its last increment happened at the
  //   same time t (coincident edge, whichever process ran first). Operations accepted at
  //   an edge coincident with the checking edge are not part of the occupancy seen just
  //   before that edge, so excluding them is exact, not conservative.
  int  a9_w_cnt;
  int  a9_r_cnt;
  real a9_w_last;
  real a9_r_last;

  // At every wclk edge: full=0 (sampled just before the edge) implies W - R < DEPTH.
  task automatic a9_wmon(input string tag);
    logic we_s;
    logic full_s;
    real  t;
    int   rb;
    forever begin
      @(negedge wclk);
      we_s   = wr_en;
      full_s = full;
      @(posedge wclk);
      t  = $realtime;
      rb = a9_r_cnt - ((a9_r_last == t) ? 1 : 0);
      if (full_s === 1'b0)
        chk("A-04", $sformatf("%s: full=0 implies W-R<DEPTH (W=%0d R=%0d)", tag, a9_w_cnt, rb),
            1'b1, (a9_w_cnt - rb) < DEPTH);
      if (we_s === 1'b1 && full_s === 1'b0) begin
        a9_w_cnt++;
        a9_w_last = t;
      end
    end
  endtask

  // At every rclk edge: empty=0 (sampled just before the edge) implies W - R >= 1.
  task automatic a9_rmon(input string tag);
    logic re_s;
    logic empty_s;
    real  t;
    int   wb;
    forever begin
      @(negedge rclk);
      re_s    = rd_en;
      empty_s = empty;
      @(posedge rclk);
      t  = $realtime;
      wb = a9_w_cnt - ((a9_w_last == t) ? 1 : 0);
      if (empty_s === 1'b0)
        chk("A-04", $sformatf("%s: empty=0 implies W-R>=1 (W=%0d R=%0d)", tag, wb, a9_r_cnt),
            1'b1, (wb - a9_r_cnt) >= 1);
      if (re_s === 1'b1 && empty_s === 1'b0) begin
        a9_r_cnt++;
        a9_r_last = t;
      end
    end
  endtask

  task automatic a9_phase(input real wp, input real rp, input real ph, input int base,
                          input string tag);
    set_clocks(wp, rp, ph);
    do_reset();
    a9_w_cnt  = 0;
    a9_r_cnt  = 0;
    a9_w_last = -1.0;
    a9_r_last = -1.0;
    fork
      stream(1000, base, tag);
      a9_wmon(tag);
      a9_rmon(tag);
    join_any
    disable fork;
    chk("C-02", {tag, ": monitor counted all accepted writes"}, 1000, a9_w_cnt);
    chk("C-02", {tag, ": monitor counted all accepted reads"},  1000, a9_r_cnt);
  endtask

  // A9: flag safety under the clock ratios of A5, A6 and A7.
  task automatic a9_flag_safety();
    a9_phase(10.0, 30.0, 0.0, 'h9_1000, "A9 wclk 10 / rclk 30");
    a9_phase(30.0, 10.0, 0.0, 'h9_2000, "A9 wclk 30 / rclk 10");
    a9_phase( 7.0,  5.0, 1.3, 'h9_3000, "A9 wclk 7 / rclk 5 +1.3");
  endtask

  // A10 white-box monitors: sample dut.wptr_gray / dut.rptr_gray once per cycle of
  // their own clock (negedge, i.e. the value present just before the next posedge)
  // and check the Hamming distance between consecutive samples is <= 1 (A-05).
  // They also count how many times the value changed.
  int a10_w_changes;
  int a10_r_changes;

  task automatic a10_mon_w();
    logic [AW:0] prev;
    logic [AW:0] cur;
    @(negedge wclk);
    prev = dut.wptr_gray;
    forever begin
      @(negedge wclk);
      cur = dut.wptr_gray;
      chk("A-05", "wptr_gray has no X/Z", 1'b0, $isunknown(cur));
      chk("A-05", $sformatf("wptr_gray %0h -> %0h changes <= 1 bit", prev, cur),
          1'b1, $countones(prev ^ cur) <= 1);
      if (cur !== prev) a10_w_changes++;
      prev = cur;
    end
  endtask

  task automatic a10_mon_r();
    logic [AW:0] prev;
    logic [AW:0] cur;
    @(negedge rclk);
    prev = dut.rptr_gray;
    forever begin
      @(negedge rclk);
      cur = dut.rptr_gray;
      chk("A-05", "rptr_gray has no X/Z", 1'b0, $isunknown(cur));
      chk("A-05", $sformatf("rptr_gray %0h -> %0h changes <= 1 bit", prev, cur),
          1'b1, $countones(prev ^ cur) <= 1);
      if (cur !== prev) a10_r_changes++;
      prev = cur;
    end
  endtask

  // A10: wrap-around for 8 laps (one lap = 2*DEPTH pointer values), data checked.
  // A gray-coded pointer that moves only on accepted operations (C-03) changes by
  // exactly one bit per accepted operation, so after the run the number of observed
  // changes must equal the number of accepted writes / reads.
  task automatic a10_gray_wrap();
    int n;
    n = 8 * 2 * DEPTH;
    a10_w_changes = 0;
    a10_r_changes = 0;
    fork
      begin
        stream(n, 'hA_1000, "A10 wrap");
        repeat (4) @(negedge wclk);   // let both monitors see the final values
        repeat (4) @(negedge rclk);
      end
      a10_mon_w();
      a10_mon_r();
    join_any
    disable fork;
    chk("A-05", "wptr_gray changed once per accepted write", n, a10_w_changes);
    chk("A-05", "rptr_gray changed once per accepted read",  n, a10_r_changes);
  endtask

  // A11: reset both domains while the FIFO holds data, then a short transfer.
  task automatic a11_reset_mid_run();
    int base_old;
    int base_new;
    base_old = 'hB100;
    base_new = 'hB200;
    write_n(DEPTH, base_old, "A11 old data");
    wait_empty(1'b0, 20, "A11 old data visible");
    read_n(1, base_old, "A11 old data", 1'b0);  // both pointers away from 0
    do_reset();
    fork
      for (int i = 0; i < 4; i++) begin
        @(negedge wclk);
        chk("C-05", $sformatf("full after mid-run reset, wclk cycle %0d", i),     1'b0, full);
        chk("C-05", $sformatf("overflow after mid-run reset, wclk cycle %0d", i), 1'b0, overflow);
      end
      for (int i = 0; i < 4; i++) begin
        @(negedge rclk);
        chk("C-05", $sformatf("empty after mid-run reset (no old data), rclk cycle %0d", i),
            1'b1, empty);
        chk("C-05", $sformatf("underflow after mid-run reset, rclk cycle %0d", i), 1'b0, underflow);
      end
    join
    stream(DEPTH, base_new, "A11 new data only");
  endtask

  // A12: re-run the key tests with the current TB_DEPTH. The DEPTH sweep itself is
  // done by separate runs with +define+TB_DEPTH=2 and +define+TB_DEPTH=16.
  task automatic a12_key_tests();
    string ids[4] = '{"A2", "A4", "A5", "A10"};
    foreach (ids[i]) begin
      cur_test = {"A12/", ids[i]};
      prepare(ids[i]);
      run_body(ids[i]);
    end
    cur_test = "A12";
  endtask

  // ---- TESTS END ----

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------
  // Clock setup per test (wclk period, rclk period, rclk phase offset), then reset.
  task automatic prepare(input string id);
    case (id)
      "A5":    set_clocks(10.0, 30.0, 0.0);
      "A6":    set_clocks(30.0, 10.0, 0.0);
      "A7":    set_clocks( 7.0,  5.0, 1.3);
      default: set_clocks(10.0, 10.0, 0.0);
    endcase
    do_reset();
  endtask

  task automatic run_body(input string id);
    case (id)
      "A1":    a1_reset();
      "A2":    a2_write_one();
      "A3":    a3_fill();
      "A4":    a4_drain();
      "A5":    a5_write_faster();
      "A6":    a6_read_faster();
      "A7":    a7_unrelated_ratio();
      "A8":    a8_rejected_ops();
      "A9":    a9_flag_safety();
      "A10":   a10_gray_wrap();
      "A11":   a11_reset_mid_run();
      "A12":   a12_key_tests();
      default: fail("-", $sformatf("unknown test id %s", id));
    endcase
  endtask

  task automatic run_test(input string id);
    int err0;
    err0     = errors;
    n_checks = 0;
    cur_test = id;
    prepare(id);
    run_body(id);
    $display("INFO %s checks=%0d errors=%0d", id, n_checks, errors - err0);
    if (errors == err0) $display("TEST %s PASS", id);
    else                $display("TEST %s FAIL", id);
  endtask

  initial begin
    string test_sel;
    $timeformat(-9, 1, "ns", 0);
    if (W > 64) $fatal(1, "tb_async_fifo: TB_DATA_WIDTH > 64 not supported by chk()");
    wrst_n  = 1'b0;
    rrst_n  = 1'b0;
    wr_en   = 1'b0;
    rd_en   = 1'b0;
    wr_data = '0;
    $display("INFO tb_async_fifo DEPTH=%0d DATA_WIDTH=%0d", DEPTH, W);

    if ($value$plusargs("TEST=%s", test_sel)) begin
      run_test(test_sel);
    end else begin
      for (int i = 1; i <= 12; i++) run_test($sformatf("A%0d", i));
    end

    if (errors == 0) $display("TB PASS");
    else             $display("TB FAIL (%0d errors)", errors);
    $finish;
  end

  // Watchdog: 5 ms of simulated time.
  initial begin
    #5ms;
    $display("TB FAIL (timeout)");
    $finish;
  end

endmodule
