# coherent-cache-dv

A hardware design-verification portfolio built as seven projects that stack into one system:
a write-back cache with MSI coherence (2 cores), an AXI-lite memory side, and a complete
verification environment (UVM, SVA, formal, coverage, regression automation).

| ID | Project | Status |
|----|---------|--------|
| P1 | Sync FIFO and async FIFO (gray pointers, 2-FF CDC), directed tests, lint, Quartus results | done |
| P2 | Class-based testbench: random stimulus, scoreboard, functional coverage | planned |
| P3 | SVA for the FIFOs and light formal proofs (SymbiYosys) | planned |
| P4 | Python multi-seed runner, regression summary, AI usage log | planned |
| P4+ | LLM-based regression triage agent | planned |
| P5 | Direct-mapped write-back cache, AXI-lite memory side, C++ reference model | planned |
| P6 | UVM environment for the cache, C++ model via DPI-C | planned |
| P7 | 2-core MSI coherence, snoop bus, SWMR checker, litmus tests, bug injection | planned |

## Tooling and honest limits

- Simulator: Questa Altera Starter FPGA Edition 2025.2 (local). Lint: Verilator 5.053. Synthesis: Quartus Prime Lite 25.1.
- The local Starter edition has no `svverification` license, so `randomize()`, `covergroup` and `uvm_do*`
  do not run locally. P1 does not need them (directed tests only). From P2 on, testbenches run in two modes
  (`VERIF_LIC` for real `randomize()`/`covergroup`, local hand-written random and counted coverage),
  and every README states which numbers come from which mode.
- Every number below is backed by a log in `reports/`.

---

# P1: Sync FIFO and Async FIFO

Documents: [`p1/spec.md`](p1/spec.md) (single source of truth, requirement IDs C-xx/S-xx/A-xx),
[`p1/test_plan.md`](p1/test_plan.md) (test IDs S1-S17, A1-A12).

## Design

| Module | Summary |
|--------|---------|
| `sync_fifo` | Single clock, first-word fall-through (FWFT) read, pointers `ADDR_W+1` bits wide, combinational `empty`/`full` from registered state, `count`, registered 1-cycle `overflow`/`underflow` pulses for rejected operations. |
| `async_fifo` | Two unrelated clocks, binary + gray pointers (`wptr_gray`, `rptr_gray`), 2-FF synchronizers, registered `full` (wclk) and `empty` (rclk) computed from the next pointer, pessimistic flags, flag deassertion latency bound N = 3 edges. |

Parameters: `DATA_WIDTH` (default 32), `DEPTH` (default 16, power of 2, >= 2). Illegal parameters are an
elaboration-time `$fatal` in Questa and Verilator (hidden from Quartus with `QUARTUS_SYNTH`).

## Verification approach

1. Spec and test plan were written first and fixed.
2. Each testbench was written from the spec only, against a dead stub (all outputs tied to 0).
   It failed on the stub: all 17 sync tests (1243 errors) and all 12 async tests (15012 errors).
3. The testbench was frozen with a checksum, and the RTL was written afterwards without editing it.
   This avoids common-mode errors (RTL and checker wrong in the same way).
4. Faults were injected into the RTL and the testbench had to fail.

Evidence: `reports/p1_sync_tb_on_stub.log`, `reports/p1_async_tb_on_stub.log`.

## Results (local mode, Questa)

| Run | sync_fifo (S1-S17) | async_fifo (A1-A12) |
|-----|--------------------|---------------------|
| default (DEPTH=16, W=32) | TB PASS | TB PASS |
| `TB_DEPTH=2` | TB PASS | TB PASS |
| `TB_DEPTH=4` | TB PASS | TB PASS |
| `TB_DATA_WIDTH=8` | TB PASS | TB PASS |

Lint: `verilator_bin.exe --lint-only -Wall` gives 0 warnings for both modules.
`-GDEPTH=3` and `-GDEPTH=1` give the expected `USERFATAL`.

Logs: `reports/p1_sync_*.log`, `reports/p1_async_*.log`. Some logs were generated before the
`QUARTUS_SYNTH` guard was added to the RTL; a full re-run afterwards gave the same pass/fail results
and the same error counts for every bug.

## Bug injection

Selected with `+define+<NAME>` (default off). Definitions are in `p1/spec.md` section 8.

| FIFO | Bug | Tests that caught it | Errors |
|------|-----|----------------------|--------|
| sync | `BUG_FULL_OFFBYONE`: `full` asserts at DEPTH-1 entries | S3, S4, S5, S9, S10, S12, S13, S15, S16 | 145 |
| sync | `BUG_RDWR_FULL`: write accepted while full if a read happens in the same cycle | S9, S15 (re-run of S9) | 8 |
| async | `BUG_WRAP_MSB`: `full` ignores the second-MSB inversion needed for gray wrap | A3, A4, A5, A8, A9, A12 | 121136 |
| async | `BUG_GRAY_BINARY`: binary pointers cross domains (the `full` comparison is also affected) | A3, A4, A5, A8, A9, A10, A12 | 121707 |
| async | `BUG_WRITE_WHEN_FULL`: write accepted while full | A8 | 9 |

The error column counts failed checks, not distinct bugs; large counts come from streaming tests that
keep failing until a guard limit.

Known gap: `BUG_RDWR_FULL` and `BUG_WRITE_WHEN_FULL` are each caught by a single directed test.
Random stimulus (P2) is expected to exercise them more.

## Synthesis (Quartus Prime Lite 25.1)

Device `5CSEMA5F31C6` (Cyclone V, DE1-SoC), slow 1100 mV 85 C model, `DEPTH=16`, `DATA_WIDTH=32`,
10 ns clock target. Clock ports are real pins; data and control ports are virtual pins, so Fmax is an
in-fabric figure.

| Module | Fmax | ALMs | Registers | Memory bits | Block RAM |
|--------|------|------|-----------|-------------|-----------|
| `sync_fifo` | clk: 237.3 MHz | 73 | 53 | 512 | 1 M10K |
| `async_fifo` | wclk/rclk: 315.06 MHz (capped by the device minimum clock period); unrestricted 353.23 / 340.25 MHz | 56 | 42 | 512 | 1 M10K |

Setup and hold slacks are positive at the 10 ns target. The FWFT read still maps to one M10K because
Quartus moves the read-pointer register into the RAM read-address register (output unregistered).
The async `.sdc` declares `wclk` and `rclk` as asynchronous clock groups.

Reports: `reports/p1_quartus_*.fit.summary`, `reports/p1_quartus_*.sta.summary`.

## Limitations

- Local mode only; no random stimulus and no functional coverage yet (P2).
- Verilator lint is not a CDC check and no CDC tool was used. P1 does not claim "CDC verified".
- RTL simulation does not model metastability; N = 3 is a design bound, silicon may need an extra stage.
- Quartus warns that read-during-write of the inferred dual-clock RAM is undefined (276027). The argument
  that it is harmless (it can only happen while empty, where `rd_data` is don't-care and `empty` falls
  3 rclk edges later) is reasoning only; no gate-level simulation was run.
- Fmax values come from one tool run on one device and speed grade.

## Reproduce

```bash
source env.sh                         # local Questa/Verilator paths (not committed)
./sim/run.sh p1 tb_sync_fifo          # add +define+TB_DEPTH=4, +define+BUG_FULL_OFFBYONE, ...
./sim/run.sh p1 tb_async_fifo         # add +define+TB_DATA_WIDTH=8, +define+BUG_WRAP_MSB, ...
verilator_bin.exe --lint-only -Wall -sv p1/rtl/async_fifo.sv --top-module async_fifo
```

Run a single test with `VSIM_ARGS=+TEST=S5` (or `A8`). Quartus projects are in `p1/quartus/`.