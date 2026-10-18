# P1 Specification: Sync FIFO and Async FIFO

Status: v1.0. This document is the single source of truth for RTL (p1/rtl),
directed tests (p1/tb), and later for the P2 scoreboard and P3 SVA/formal.
Requirement IDs (C-xx, S-xx, A-xx) are referenced by test_plan.md.

## 1. Scope

In scope:
- `sync_fifo`: single-clock FIFO, first-word fall-through (FWFT) read.
- `async_fifo`: dual-clock FIFO, 2-FF synchronizers, gray-coded pointers.

Out of scope: almost_full/almost_empty flags, ECC/parity, multi-beat packets,
reset synchronizers, sign-off CDC analysis. Verilator lint is not a CDC check;
P1 does not claim "CDC verified", only test- and design-argument-based evidence.

## 2. Conventions

- All logic is sampled on the rising clock edge.
- "Cycle k" is the interval after clock edge k. A value "sampled at edge k" is the
  value present just before edge k.
- Reset is synchronous and active low (`rst_n`, `wrst_n`, `rrst_n`).
- RTL style: SystemVerilog, `always_ff` / `always_comb`, `logic`, `localparam`,
  one module per file, files named after the module.
- Active-low signals end with `_n`. Parameters are UPPER_CASE.

## 3. Parameters

| Name | Default | Constraint |
| --- | --- | --- |
| `DATA_WIDTH` | 32 | >= 1 |
| `DEPTH` | 16 | power of 2, >= 2 |
| `ADDR_W` (derived) | `$clog2(DEPTH)` | do not override |

- An illegal `DEPTH` must cause an elaboration-time fatal error.
- Overriding ADDR_W, or an illegal DATA_WIDTH or DEPTH, is an elaboration-time fatal error.

## 4. Interface

| Signal | Dir | Sync FIFO | Async FIFO |
| --- | --- | --- | --- |
| `clk` | in | clock | n/a |
| `wclk`, `rclk` | in | n/a | write / read clock |
| `rst_n` | in | reset | n/a |
| `wrst_n`, `rrst_n` | in | n/a | write / read domain reset |
| `wr_en` | in | write request | write request (wclk domain) |
| `wr_data[DATA_WIDTH-1:0]` | in | write data | write data |
| `full` | out | full flag | full flag (wclk domain) |
| `overflow` | out | 1-cycle pulse | 1-cycle pulse (wclk domain) |
| `rd_en` | in | read request | read request (rclk domain) |
| `rd_data[DATA_WIDTH-1:0]` | out | head of queue | head of queue |
| `empty` | out | empty flag | empty flag (rclk domain) |
| `underflow` | out | 1-cycle pulse | 1-cycle pulse (rclk domain) |
| `count[ADDR_W:0]` | out | occupancy | not present |

## 5. Common behavior (both FIFOs)

- C-01 FWFT: while `empty=0`, `rd_data` is the oldest stored element. `rd_en` pops
  that element; `rd_data` shows the next element in the cycle after the pop.
- C-02 A write is accepted iff `wr_en && !full` at the clock edge. A read is accepted
  iff `rd_en && !empty` at the clock edge. Flags used are the pre-edge values.
- C-03 A rejected operation changes no state: no data is overwritten, no pointer moves.
- C-04 Rejected write: `overflow` is high for exactly one cycle after the edge at which
  it was sampled (registered output). Rejected read: same for `underflow`.
  Consecutive rejected attempts give consecutive pulse cycles.
- C-05 After reset: `empty=1`, `full=0`, `overflow=0`, `underflow=0`, (sync) `count=0`.
  The memory array is not cleared. From the first rising edge that samples the reset low, outputs take their reset values; before that edge they still show the previous state.
- C-06 `rd_data` is don't-care while `empty=1`. Testbenches must not check it then.
- C-07 Data order is FIFO. No element is lost or duplicated.
- C-08 `wr_en`/`rd_en` sampled while the relevant reset is asserted have no effect and
  produce no `overflow`/`underflow` pulse. No memory write occurs while reset is asserted.

## 6. Sync FIFO (`sync_fifo`)

- S-01 Pointers `wptr`, `rptr` are `ADDR_W+1` bits wide. The memory index is the low
  `ADDR_W` bits. `count = wptr - rptr` (modulo 2^(ADDR_W+1)), range 0..DEPTH.
- S-02 `empty` is high iff `wptr == rptr`. `full` is high iff the low `ADDR_W` bits are
  equal and the MSBs differ. Both are combinational functions of registered state
  (zero latency): the flags of cycle k reflect all operations accepted before edge k.
  `empty` and `full` are never both high (DEPTH >= 2).
- S-03 Simultaneous read and write (decision uses current-cycle flags only):

| State | Write | Read | Next count |
| --- | --- | --- | --- |
| neither empty nor full | accepted | accepted | unchanged |
| empty | accepted | rejected (`underflow`) | 1 |
| full | rejected (`overflow`) | accepted | DEPTH-1 |

- S-04 `count` next = `count` + accepted_write - accepted_read.

## 7. Async FIFO (`async_fifo`)

- A-01 `wclk` and `rclk` are unrelated: any frequency ratio and phase.
- A-02 `full` and `empty` are registered flags in their own domain. Each rises with no
  extra latency in its own domain, computed from the local pointer and the
  synchronized remote pointer.
- A-03 Flag deassertion latency (derived for 2-FF synchronizers with registered flags):
  - `empty` falls no later than the 3rd `rclk` edge after the `wclk` edge that accepted
    the write (an `rclk` edge coincident with that `wclk` edge is not counted).
  - `full` falls no later than the 3rd `wclk` edge after the `rclk` edge that accepted
    the read (same rule).
  - N = 3 is a design bound for RTL simulation. Metastability is not modeled; on silicon
    one more synchronizer stage may be needed.
- A-04 Flags are pessimistic, never optimistic: `empty` may be high while data exists
  (not yet visible); `empty` is never low while the FIFO is truly empty. `full` may be
  high while space exists; `full` is never low while the FIFO is truly full.
- A-05 Pointers crossing domains are gray-coded and synchronized by 2 FFs. Internal
  signals `wptr_gray` and `rptr_gray` (ADDR_W+1 bits) must keep these names. Each changes
  by at most one bit per own-clock edge.
- A-06 Reset: `wrst_n` and `rrst_n` must be asserted together, overlapping for at least
  4 rising edges of each clock. No transaction is issued until both are released.
  Reset synchronization (async assert / sync release) is out of scope.
- A-07 No `count` output.
- A-08 `overflow` is in the `wclk` domain, `underflow` in the `rclk` domain.

## 8. Verification hooks

- Fault injection by `ifdef BUG_<NAME>` inside RTL. Reserved names:
  `BUG_FULL_OFFBYONE`, `BUG_WRAP_MSB`, `BUG_WRITE_WHEN_FULL`, `BUG_RDWR_FULL`,
  `BUG_GRAY_BINARY`. P1 injects at least one; P2 injects more.
- Formal properties are wrapped in `ifdef FORMAL` (used from P3).
- Passing defines: `./sim/run.sh p1 <top> +define+BUG_FULL_OFFBYONE`.
- Files: `p1/rtl/sync_fifo.sv`, `p1/rtl/async_fifo.sv`,
  `p1/tb/tb_sync_fifo.sv`, `p1/tb/tb_async_fifo.sv`.
- Bug definitions (sync_fifo):
  - BUG_FULL_OFFBYONE: `full` asserts at DEPTH-1 stored entries instead of DEPTH.
  - BUG_RDWR_FULL: a write is accepted while full if a read occurs in the same cycle,
    violating S-03.
  Remaining reserved names (BUG_WRAP_MSB, BUG_WRITE_WHEN_FULL, BUG_GRAY_BINARY)
  are defined in P2 or in the async FIFO stage.

## 9. Reuse in later projects

- P2: scoreboard queue models C-07 and S-04; for async it checks only C-07 and A-04.
- P3: invariants for SVA/formal come from S-01, S-02, S-04, A-04, A-05. Use DEPTH 4 or 8.
- P5 onward: FIFO may be reused as a buffer in the cache/AXI-lite path.