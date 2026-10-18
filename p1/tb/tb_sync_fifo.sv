// Directed self-checking testbench for sync_fifo (p1/test_plan.md, tests S1-S17).
// Timing convention: inputs driven at posedge + 1 ns, outputs sampled at negedge.
// After cycle() returns we are at the negedge of the cycle in which the inputs were
// driven: outputs reflect every operation accepted BEFORE that cycle; the inputs just
// driven are sampled by the NEXT posedge.
// Each test keeps its own expected values (no shared reference model).
`timescale 1ns/1ps

`ifndef TB_DEPTH
  `define TB_DEPTH 16
`endif
`ifndef TB_DATA_WIDTH
  `define TB_DATA_WIDTH 32
`endif

module tb_sync_fifo;

  localparam int DEPTH = `TB_DEPTH;
  localparam int W     = `TB_DATA_WIDTH;
  localparam int AW    = $clog2(DEPTH);

  typedef logic [W-1:0] data_t;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic          clk = 1'b0;
  logic          rst_n;
  logic          wr_en;
  data_t         wr_data;
  logic          full;
  logic          overflow;
  logic          rd_en;
  data_t         rd_data;
  logic          empty;
  logic          underflow;
  logic [AW:0]   count;

  always #5 clk = ~clk;  // 10 ns period

  sync_fifo #(.DATA_WIDTH(W), .DEPTH(DEPTH)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_en     (wr_en),
    .wr_data   (wr_data),
    .full      (full),
    .overflow  (overflow),
    .rd_en     (rd_en),
    .rd_data   (rd_data),
    .empty     (empty),
    .underflow (underflow),
    .count     (count)
  );

  // ---------------------------------------------------------------------------
  // Bookkeeping
  // ---------------------------------------------------------------------------
  int    errors   = 0;
  int    n_checks = 0;   // checks executed in the current test
  string cur_test = "-";

  // Generic compare. Uses !== so X/Z on a DUT output is an error.
  function automatic void chk(string spec_id, string what,
                              logic [63:0] exp, logic [63:0] got);
    n_checks++;
    if (got !== exp) begin
      errors++;
      $display("[ERR][%s] t=%0t exp=%0h got=%0h (%s) %s",
               cur_test, $time, exp, got, spec_id, what);
    end
  endfunction

  // Data check for the FIFO head. Skipped while the DUT reports empty=1 (C-06);
  // in that case the caller's empty check has already flagged the mismatch.
  function automatic void chk_head(string spec_id, string what, data_t exp);
    if (empty === 1'b0) chk(spec_id, what, exp, rd_data);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive helpers
  // ---------------------------------------------------------------------------
  // One clock cycle: drive at posedge + 1 ns, return at the following negedge.
  task automatic cycle(input logic we, input data_t wd, input logic re);
    @(posedge clk);
    #1;
    wr_en   = we;
    wr_data = wd;
    rd_en   = re;
    @(negedge clk);
    chk("S-02", "full and empty never both 1", 1'b0, (full === 1'b1 && empty === 1'b1));
  endtask

  // Same as cycle() but also drives rst_n (used by S17).
  task automatic cycle_rst(input logic rst, input logic we, input data_t wd,
                           input logic re);
    @(posedge clk);
    #1;
    rst_n   = rst;
    wr_en   = we;
    wr_data = wd;
    rd_en   = re;
    @(negedge clk);
    chk("S-02", "full and empty never both 1", 1'b0, (full === 1'b1 && empty === 1'b1));
  endtask

  task automatic idle(input int n = 1);
    repeat (n) cycle(1'b0, '0, 1'b0);
  endtask

  // Synchronous reset: n rising edges sample rst_n=0 with enables low.
  // Returns at the negedge of the first cycle after release.
  task automatic do_reset(input int n = 3);
    @(posedge clk);
    #1;
    rst_n   = 1'b0;
    wr_en   = 1'b0;
    rd_en   = 1'b0;
    wr_data = '0;
    repeat (n) @(posedge clk);
    #1;
    rst_n = 1'b1;
    @(negedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Tests (one task per test plan row)
  // ---------------------------------------------------------------------------
  // S1: flags right after reset.
  task automatic s1_reset();
    chk("C-05", "empty after reset",     1'b1, empty);
    chk("C-05", "full after reset",      1'b0, full);
    chk("C-05", "count after reset",     0,    count);
    chk("C-05", "overflow after reset",  1'b0, overflow);
    chk("C-05", "underflow after reset", 1'b0, underflow);
    // Must still hold one idle cycle later (no spurious state change).
    idle();
    chk("C-05", "empty 1 cycle after reset", 1'b1, empty);
    chk("C-05", "count 1 cycle after reset", 0,    count);
  endtask

  // S2: write one element, then read it.
  task automatic s2_write_read_one();
    data_t d;
    d = data_t'('h21);
    cycle(1'b1, d, 1'b0);  // write driven, not yet sampled
    chk("S-02", "empty before write is sampled", 1'b1, empty);
    chk("S-04", "count before write is sampled", 0,    count);
    idle();                // write accepted at previous edge
    chk("S-02", "empty falls after write", 1'b0, empty);
    chk("S-04", "count 0->1",              1,    count);
    chk_head("C-01", "head after write", d);
    cycle(1'b0, '0, 1'b1); // read driven, not yet sampled
    chk("S-02", "empty still 0 before read is sampled", 1'b0, empty);
    chk_head("C-01", "head before read is sampled", d);
    idle();                // read accepted
    chk("S-02", "empty rises after read", 1'b1, empty);
    chk("S-04", "count 1->0",             0,    count);
    chk("C-04", "no underflow on accepted read", 1'b0, underflow);
  endtask

  // S3: write DEPTH elements -> full.
  task automatic s3_fill();
    for (int i = 0; i < DEPTH; i++) cycle(1'b1, data_t'('h31 + i), 1'b0);
    // DEPTH-1 writes accepted, last one not yet sampled.
    chk("S-02", "full=0 with DEPTH-1 stored", 1'b0,      full);
    chk("S-04", "count=DEPTH-1",              DEPTH - 1, count);
    idle();
    chk("S-02", "full after DEPTH writes",    1'b1,  full);
    chk("S-04", "count after DEPTH writes",   DEPTH, count);
    chk("S-02", "empty after DEPTH writes",   1'b0,  empty);
    chk("C-04", "no overflow on accepted writes", 1'b0, overflow);
  endtask

  // S4: fill, then read all elements back.
  task automatic s4_drain();
    data_t exp_q[$];
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b1, data_t'('h41 + i), 1'b0);
      exp_q.push_back(data_t'('h41 + i));
    end
    idle();
    chk("S-02", "full before drain", 1'b1, full);
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b0, '0, 1'b1);  // reads 0..i-1 accepted, read i not yet sampled
      chk("C-01", $sformatf("empty=0 before pop %0d", i), 1'b0, empty);
      chk_head("C-07", $sformatf("FIFO order element %0d", i), exp_q[i]);
    end
    idle();
    chk("C-01", "empty rises after last pop", 1'b1, empty);
    chk("S-04", "count after drain",          0,    count);
    chk("C-04", "no underflow on accepted reads", 1'b0, underflow);
  endtask

  // S5: write while full -> rejected, overflow pulse, old data intact.
  task automatic s5_write_when_full();
    data_t exp_q[$];
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b1, data_t'('h51 + i), 1'b0);
      exp_q.push_back(data_t'('h51 + i));
    end
    idle();
    chk("S-02", "full before rejected write", 1'b1, full);
    // Single rejected attempt.
    cycle(1'b1, data_t'('h51 + DEPTH), 1'b0);
    chk("C-04", "no overflow before attempt is sampled", 1'b0, overflow);
    idle();
    chk("C-04", "overflow pulse 1 cycle after attempt", 1'b1,  overflow);
    chk("C-03", "count unchanged after rejected write", DEPTH, count);
    chk("C-03", "full unchanged after rejected write",  1'b1,  full);
    chk_head("C-03", "head unchanged after rejected write", exp_q[0]);
    idle();
    chk("C-04", "overflow lasts exactly 1 cycle", 1'b0, overflow);
    // Two consecutive rejected attempts -> two consecutive pulse cycles.
    cycle(1'b1, data_t'('h52 + DEPTH), 1'b0);
    cycle(1'b1, data_t'('h53 + DEPTH), 1'b0);
    chk("C-04", "overflow for 1st of 2 consecutive attempts", 1'b1, overflow);
    idle();
    chk("C-04", "overflow for 2nd of 2 consecutive attempts", 1'b1, overflow);
    idle();
    chk("C-04", "overflow ends after consecutive attempts", 1'b0, overflow);
    chk("C-03", "count unchanged after 3 rejected writes", DEPTH, count);
    // Read back everything: original data only.
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b0, '0, 1'b1);
      chk("C-01", $sformatf("empty=0 before pop %0d", i), 1'b0, empty);
      chk_head("C-03", $sformatf("old data intact element %0d", i), exp_q[i]);
    end
    idle();
    chk("C-03", "empty after reading DEPTH (rejected data not stored)", 1'b1, empty);
  endtask

  // S6: read while empty -> rejected, underflow pulse, state unchanged.
  task automatic s6_read_when_empty();
    data_t d;
    d = data_t'('h61);
    cycle(1'b0, '0, 1'b1);
    chk("C-04", "no underflow before attempt is sampled", 1'b0, underflow);
    chk("S-02", "empty before rejected read",             1'b1, empty);
    idle();
    chk("C-04", "underflow pulse 1 cycle after attempt", 1'b1, underflow);
    chk("C-03", "empty unchanged after rejected read",   1'b1, empty);
    chk("C-03", "count unchanged after rejected read",   0,    count);
    idle();
    chk("C-04", "underflow lasts exactly 1 cycle", 1'b0, underflow);
    // Two consecutive rejected attempts -> two consecutive pulse cycles.
    cycle(1'b0, '0, 1'b1);
    cycle(1'b0, '0, 1'b1);
    chk("C-04", "underflow for 1st of 2 consecutive attempts", 1'b1, underflow);
    idle();
    chk("C-04", "underflow for 2nd of 2 consecutive attempts", 1'b1, underflow);
    idle();
    chk("C-04", "underflow ends after consecutive attempts", 1'b0, underflow);
    chk("C-03", "count unchanged after 3 rejected reads", 0,    count);
    chk("C-03", "empty unchanged after 3 rejected reads", 1'b1, empty);
    // Pointers must not have moved: one write/read round trip behaves normally.
    cycle(1'b1, d, 1'b0);
    idle();
    chk("C-03", "count=1 after write following rejected read", 1,    count);
    chk("C-03", "empty=0 after write following rejected read", 1'b0, empty);
    chk_head("C-03", "head after write following rejected read", d);
    cycle(1'b0, '0, 1'b1);
    idle();
    chk("C-03", "empty after round trip", 1'b1, empty);
    chk("C-03", "count after round trip", 0,    count);
  endtask

  // S7: simultaneous read and write at mid occupancy.
  task automatic s7_rdwr_mid();
    data_t exp_q[$];
    int    half;
    int    seq;
    half = DEPTH / 2;  // 1..DEPTH-1 for DEPTH >= 2: neither empty nor full
    seq  = 'h71;
    for (int i = 0; i < half; i++) begin
      cycle(1'b1, data_t'(seq), 1'b0);
      exp_q.push_back(data_t'(seq));
      seq++;
    end
    for (int i = 0; i < 2 * DEPTH; i++) begin
      cycle(1'b1, data_t'(seq), 1'b1);
      // State reflects simultaneous ops 0..i-1.
      chk("S-03", $sformatf("count unchanged, simul op %0d", i), half, count);
      chk("S-02", $sformatf("empty=0, simul op %0d", i),          1'b0, empty);
      chk("S-02", $sformatf("full=0, simul op %0d", i),           1'b0, full);
      chk_head("C-07", $sformatf("head order, simul op %0d", i), exp_q[0]);
      exp_q.push_back(data_t'(seq));
      void'(exp_q.pop_front());
      seq++;
    end
    idle();
    chk("S-03", "count unchanged after simultaneous ops", half, count);
    chk("C-04", "no overflow during simultaneous ops",  1'b0, overflow);
    chk("C-04", "no underflow during simultaneous ops", 1'b0, underflow);
    for (int i = 0; i < half; i++) begin
      cycle(1'b0, '0, 1'b1);
      chk_head("C-07", $sformatf("drain order element %0d", i), exp_q[i]);
    end
    idle();
    chk("S-02", "empty after drain", 1'b1, empty);
  endtask

  // S8: simultaneous read and write while empty.
  task automatic s8_rdwr_empty();
    data_t d;
    d = data_t'('h81);
    cycle(1'b1, d, 1'b1);
    chk("S-02", "empty before simultaneous op", 1'b1, empty);
    idle();
    chk("S-03", "write accepted: count=1",      1,    count);
    chk("S-03", "write accepted: empty=0",      1'b0, empty);
    chk("C-04", "read rejected: underflow=1",   1'b1, underflow);
    chk("C-04", "write accepted: overflow=0",   1'b0, overflow);
    chk_head("S-03", "written element is head", d);
    idle();
    chk("C-04", "underflow lasts exactly 1 cycle", 1'b0, underflow);
    chk("S-03", "count still 1",                   1,    count);
    cycle(1'b0, '0, 1'b1);
    idle();
    chk("S-02", "empty after reading the element", 1'b1, empty);
  endtask

  // S9: simultaneous read and write while full.
  task automatic s9_rdwr_full();
    data_t exp_q[$];
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b1, data_t'('h91 + i), 1'b0);
      exp_q.push_back(data_t'('h91 + i));
    end
    idle();
    chk("S-02", "full before simultaneous op", 1'b1, full);
    cycle(1'b1, data_t'('h91 + DEPTH), 1'b1);
    idle();
    void'(exp_q.pop_front());  // read accepted; write rejected
    chk("S-03", "count=DEPTH-1",               DEPTH - 1, count);
    chk("S-02", "full=0 after accepted read",  1'b0,      full);
    chk("C-04", "write rejected: overflow=1",  1'b1,      overflow);
    chk("C-04", "read accepted: underflow=0",  1'b0,      underflow);
    chk_head("S-03", "head advanced by accepted read", exp_q[0]);
    idle();
    chk("C-04", "overflow lasts exactly 1 cycle", 1'b0, overflow);
    for (int i = 0; i < DEPTH - 1; i++) begin
      cycle(1'b0, '0, 1'b1);
      chk_head("C-03", $sformatf("drain order element %0d", i), exp_q[i]);
    end
    idle();
    chk("C-03", "empty after DEPTH-1 reads (rejected data not stored)", 1'b1, empty);
  endtask

  // S10 helper: from empty, fill to full then drain to empty; flags checked every cycle.
  task automatic s10_fill_drain(input string tag, input int base);
    data_t exp_q[$];
    int    cnt;
    cnt = 0;
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b1, data_t'(base + i), 1'b0);
      chk("S-02", {tag, " empty during fill"}, cnt == 0,     empty);
      chk("S-02", {tag, " full during fill"},  cnt == DEPTH, full);
      exp_q.push_back(data_t'(base + i));
      cnt++;
    end
    idle();
    chk("S-02", {tag, " full at fill end"},  1'b1,  full);
    chk("S-02", {tag, " empty at fill end"}, 1'b0,  empty);
    chk("S-01", {tag, " count at fill end"}, DEPTH, count);
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b0, '0, 1'b1);
      chk("S-02", {tag, " empty during drain"}, cnt == 0,     empty);
      chk("S-02", {tag, " full during drain"},  cnt == DEPTH, full);
      chk_head("C-07", {tag, $sformatf(" drain element %0d", i)}, exp_q[i]);
      cnt--;
    end
    idle();
    chk("S-02", {tag, " empty at drain end"}, 1'b1, empty);
    chk("S-02", {tag, " full at drain end"},  1'b0, full);
  endtask

  // S10 helper: move both pointers forward by k (write then read in chunks <= DEPTH).
  task automatic s10_advance(input int k, input int base);
    int rem;
    int n;
    int seq;
    rem = k;
    seq = base;
    while (rem > 0) begin
      n = (rem < DEPTH) ? rem : DEPTH;
      for (int i = 0; i < n; i++) cycle(1'b1, data_t'(seq + i), 1'b0);
      idle();
      chk("S-01", $sformatf("advance %0d: count after %0d writes", k, n), n, count);
      for (int i = 0; i < n; i++) begin
        cycle(1'b0, '0, 1'b1);
        chk_head("C-07", $sformatf("advance %0d: element %0d", k, i), data_t'(seq + i));
      end
      idle();
      chk("S-02", $sformatf("advance %0d: empty after chunk", k), 1'b1, empty);
      rem -= n;
      seq += n;
    end
  endtask

  // S10: wrap-around. Part A: 3 laps from offset 0 (6*DEPTH ops).
  // Part B: fill to full from non-zero pointer offsets, MSB=0 (k<DEPTH) and MSB=1 (k>DEPTH).
  task automatic s10_wraparound();
    int offs[$];
    for (int lap = 0; lap < 3; lap++)
      s10_fill_drain($sformatf("lap %0d", lap), 'h11 + lap * DEPTH);
    offs = '{1, DEPTH / 2, DEPTH - 1, DEPTH + 1, DEPTH + DEPTH / 2, 2 * DEPTH - 1};
    offs = offs.unique();
    foreach (offs[j]) begin
      if (offs[j] == 0 || offs[j] == DEPTH) continue;  // not a non-zero offset
      do_reset();
      s10_advance(offs[j], 'h11);
      s10_fill_drain($sformatf("offset %0d (MSB=%0d)", offs[j], offs[j] >= DEPTH),
                     'h11 + offs[j]);
    end
  endtask

  // S11: reset while holding data, then new data only.
  task automatic s11_reset_with_data();
    int n_new;
    for (int i = 0; i < DEPTH; i++) cycle(1'b1, data_t'('hB1 + i), 1'b0);
    idle();
    chk("S-02", "full before mid-run reset", 1'b1, full);
    do_reset(2);
    chk("C-05", "empty after mid-run reset",     1'b1, empty);
    chk("C-05", "full after mid-run reset",      1'b0, full);
    chk("C-05", "count after mid-run reset",     0,    count);
    chk("C-05", "overflow after mid-run reset",  1'b0, overflow);
    chk("C-05", "underflow after mid-run reset", 1'b0, underflow);
    n_new = (DEPTH / 2 > 0) ? DEPTH / 2 : 1;
    for (int i = 0; i < n_new; i++) cycle(1'b1, data_t'('hC1 + i), 1'b0);
    idle();
    chk("C-05", "count = new writes only", n_new, count);
    for (int i = 0; i < n_new; i++) begin
      cycle(1'b0, '0, 1'b1);
      chk("C-05", $sformatf("empty=0 before new pop %0d", i), 1'b0, empty);
      chk_head("C-05", $sformatf("new data only, element %0d", i), data_t'('hC1 + i));
    end
    idle();
    chk("C-05", "empty after new data read (no old data left)", 1'b1, empty);
  endtask

  // S12: data patterns all-0, all-1, 0101, 1010, walking-1.
  task automatic s12_data_patterns();
    data_t pats[$];
    data_t alt01;
    data_t batch[$];
    for (int b = 0; b < W; b++) alt01[b] = (b % 2 == 0);  // ...0101
    pats.push_back('0);
    pats.push_back('1);
    pats.push_back(alt01);
    pats.push_back(~alt01);                                 // ...1010
    for (int b = 0; b < W; b++) pats.push_back(data_t'(1) << b);
    while (pats.size() > 0) begin
      batch.delete();
      while (pats.size() > 0 && batch.size() < DEPTH) batch.push_back(pats.pop_front());
      foreach (batch[i]) cycle(1'b1, batch[i], 1'b0);
      idle();
      chk("S-04", "count after pattern batch", batch.size(), count);
      foreach (batch[i]) begin
        cycle(1'b0, '0, 1'b1);
        chk("C-01", $sformatf("empty=0 before pattern pop %0d", i), 1'b0, empty);
        chk_head("C-07", $sformatf("pattern %0h", batch[i]), batch[i]);
      end
      idle();
      chk("S-02", "empty after pattern batch", 1'b1, empty);
    end
  endtask

  // S13: write every cycle while full=0, then read every cycle while empty=0.
  // full/empty are the test's expected values (they equal the DUT flags on a correct DUT).
  task automatic s13_burst();
    int cnt;
    cnt = 0;
    while (cnt < DEPTH) begin       // expected full=0
      cycle(1'b1, data_t'('hD1 + cnt), 1'b0);
      chk("S-04", $sformatf("count during write burst, cycle %0d", cnt), cnt,  count);
      chk("S-02", $sformatf("full=0 during write burst, cycle %0d", cnt), 1'b0, full);
      chk("C-04", $sformatf("no overflow, write cycle %0d", cnt),         1'b0, overflow);
      cnt++;                        // every write accepted: no gap
    end
    idle();
    chk("S-02", "full after write burst",  1'b1,  full);
    chk("S-04", "count after write burst", DEPTH, count);
    chk("C-04", "no overflow after write burst", 1'b0, overflow);
    for (int i = 0; i < DEPTH; i++) begin  // expected empty=0
      cycle(1'b0, '0, 1'b1);
      chk("S-04", $sformatf("count during read burst, cycle %0d", i), DEPTH - i, count);
      chk("C-01", $sformatf("empty=0 during read burst, cycle %0d", i), 1'b0, empty);
      chk_head("C-07", $sformatf("burst element %0d", i), data_t'('hD1 + i));
      chk("C-04", $sformatf("no overflow, read cycle %0d", i),  1'b0, overflow);
      chk("C-04", $sformatf("no underflow, read cycle %0d", i), 1'b0, underflow);
    end
    idle();
    chk("S-02", "empty after read burst", 1'b1, empty);
    chk("C-04", "no underflow after read burst", 1'b0, underflow);
  endtask

  // S14: FWFT timing. Head checked every cycle while not empty; occupancy <= 2.
  task automatic s14_fwft_timing();
    localparam int N = 12;
    logic  we [N] = '{1, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0};
    logic  re [N] = '{0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 0};
    data_t exp_q[$];
    int    seq;
    int    sz;
    seq = 'hE1;
    for (int k = 0; k <= N; k++) begin
      if (k < N) cycle(we[k], data_t'(seq), re[k]);
      else       idle();
      // State reflects ops 0..k-1.
      chk("S-02", $sformatf("empty, cycle %0d", k), exp_q.size() == 0, empty);
      chk("S-04", $sformatf("count, cycle %0d", k), exp_q.size(),      count);
      if (exp_q.size() > 0)
        chk_head("C-01", $sformatf("head, cycle %0d", k), exp_q[0]);
      chk("C-04", $sformatf("no overflow, cycle %0d", k),  1'b0, overflow);
      chk("C-04", $sformatf("no underflow, cycle %0d", k), 1'b0, underflow);
      if (k < N) begin
        sz = exp_q.size();  // decisions use pre-edge occupancy
        if (re[k] && sz > 0)     void'(exp_q.pop_front());
        if (we[k] && sz < DEPTH) begin exp_q.push_back(data_t'(seq)); seq++; end
      end
    end
  endtask

  // S15: re-run S1-S13 with the current TB_DEPTH / TB_DATA_WIDTH.
  // The parameter sweep (DEPTH=2, DEPTH=4, DATA_WIDTH=8) is done by separate runs
  // with +define+TB_DEPTH=<n> / +define+TB_DATA_WIDTH=8.
  task automatic s15_param_sweep();
    for (int i = 1; i <= 13; i++) begin
      cur_test = $sformatf("S15/S%0d", i);
      do_reset();
      run_body($sformatf("S%0d", i));
    end
    cur_test = "S15";
  endtask

  // S16: count checked every cycle during fill (S3), drain (S4), simultaneous R/W (S7).
  task automatic s16_count_every_cycle();
    int cnt;
    int half;
    int seq;
    cnt = 0;
    seq = 'hF1;
    // Fill
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b1, data_t'(seq++), 1'b0);
      chk("S-04", $sformatf("count during fill, cycle %0d", i), cnt, count);
      cnt++;
    end
    idle();
    chk("S-01", "count=DEPTH at full", cnt, count);
    // Drain
    for (int i = 0; i < DEPTH; i++) begin
      cycle(1'b0, '0, 1'b1);
      chk("S-04", $sformatf("count during drain, cycle %0d", i), cnt, count);
      cnt--;
    end
    idle();
    chk("S-01", "count=0 at empty", cnt, count);
    // Simultaneous R/W at mid occupancy
    half = DEPTH / 2;
    for (int i = 0; i < half; i++) begin
      cycle(1'b1, data_t'(seq++), 1'b0);
      chk("S-04", $sformatf("count during half fill, cycle %0d", i), cnt, count);
      cnt++;
    end
    for (int i = 0; i < 2 * DEPTH; i++) begin
      cycle(1'b1, data_t'(seq++), 1'b1);
      chk("S-04", $sformatf("count during simultaneous R/W, cycle %0d", i), cnt, count);
      // accepted write + accepted read: cnt unchanged
    end
    idle();
    chk("S-04", "count after simultaneous R/W", cnt, count);
  endtask

  // S17: wr_en/rd_en while rst_n=0 have no effect and produce no pulses.
  // Phases (3 reset edges each): wr_en only, rd_en only, both.
  task automatic s17_reset_ignores_en();
    data_t d;
    d = data_t'('h17A);
    for (int ph = 0; ph < 3; ph++) begin
      for (int c = 0; c < 3; c++) begin
        cycle_rst(1'b0, ph != 1, data_t'('h171 + c), ph != 0);
        chk("C-08", $sformatf("no overflow in reset, phase %0d cycle %0d", ph, c),  1'b0, overflow);
        chk("C-08", $sformatf("no underflow in reset, phase %0d cycle %0d", ph, c), 1'b0, underflow);
        chk("C-08", $sformatf("count stays 0 in reset, phase %0d cycle %0d", ph, c), 0,   count);
        chk("C-08", $sformatf("empty stays 1 in reset, phase %0d cycle %0d", ph, c), 1'b1, empty);
      end
    end
    // Release with enables low; last reset edge sampled wr_en=rd_en=1.
    cycle_rst(1'b1, 1'b0, '0, 1'b0);
    chk("C-08", "empty after release",        1'b1, empty);
    chk("C-08", "count after release",        0,    count);
    chk("C-08", "full after release",         1'b0, full);
    chk("C-08", "no overflow after release",  1'b0, overflow);
    chk("C-08", "no underflow after release", 1'b0, underflow);
    idle();
    chk("C-08", "empty 1 cycle after release",        1'b1, empty);
    chk("C-08", "no overflow 1 cycle after release",  1'b0, overflow);
    chk("C-08", "no underflow 1 cycle after release", 1'b0, underflow);
    // FIFO operates normally after release.
    cycle(1'b1, d, 1'b0);
    idle();
    chk("C-08", "count=1 after first write post-release", 1,    count);
    chk("C-08", "empty=0 after first write post-release", 1'b0, empty);
    chk_head("C-01", "head after first write post-release", d);
    cycle(1'b0, '0, 1'b1);
    idle();
    chk("C-08", "empty after round trip post-release", 1'b1, empty);
  endtask

  // ---- TESTS END ----

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------
  task automatic run_body(input string id);
    case (id)
      "S1":  s1_reset();
      "S2":  s2_write_read_one();
      "S3":  s3_fill();
      "S4":  s4_drain();
      "S5":  s5_write_when_full();
      "S6":  s6_read_when_empty();
      "S7":  s7_rdwr_mid();
      "S8":  s8_rdwr_empty();
      "S9":  s9_rdwr_full();
      "S10": s10_wraparound();
      "S11": s11_reset_with_data();
      "S12": s12_data_patterns();
      "S13": s13_burst();
      "S14": s14_fwft_timing();
      "S15": s15_param_sweep();
      "S16": s16_count_every_cycle();
      "S17": s17_reset_ignores_en();
      default: begin
        errors++;
        $display("[ERR][%s] t=%0t unknown test id", id, $time);
      end
    endcase
  endtask

  // Full reset, run one test, print its verdict.
  task automatic run_test(input string id);
    int err0;
    err0     = errors;
    n_checks = 0;
    cur_test = id;
    do_reset();
    run_body(id);
    $display("INFO %s checks=%0d errors=%0d", id, n_checks, errors - err0);
    if (errors == err0) $display("TEST %s PASS", id);
    else                $display("TEST %s FAIL", id);
  endtask

  initial begin
    string test_sel;
    $timeformat(-9, 0, "ns", 0);
    if (W > 64) $fatal(1, "tb_sync_fifo: TB_DATA_WIDTH > 64 not supported by chk()");
    rst_n   = 1'b0;
    wr_en   = 1'b0;
    rd_en   = 1'b0;
    wr_data = '0;
    $display("INFO tb_sync_fifo DEPTH=%0d DATA_WIDTH=%0d", DEPTH, W);

    if ($value$plusargs("TEST=%s", test_sel)) begin
      run_test(test_sel);
    end else begin
      for (int i = 1; i <= 17; i++) run_test($sformatf("S%0d", i));
    end

    if (errors == 0) $display("TB PASS");
    else             $display("TB FAIL (%0d errors)", errors);
    $finish;
  end

  // Watchdog: 1 ms of simulated time.
  initial begin
    #1ms;
    $display("TB FAIL (timeout)");
    $finish;
  end

endmodule
