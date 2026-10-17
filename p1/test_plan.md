# P1 Directed Test Plan

Scope: directed, self-checking tests only (constrained random starts in P2).
Spec: p1/spec.md (requirement IDs in the "Spec" column).

## Testbench rules

- Drive inputs after the clock edge (nonblocking or #1); sample outputs just before the edge.
- Each test keeps its own expected values (hand-written counters/arrays), no shared model.
- Data uses an incrementing sequence unless the test says otherwise (detects loss/duplication).
- Never check `rd_data` while `empty=1` (C-06).
- On mismatch: print the test ID, time, expected, actual; increment an error counter.
- End: print `TB PASS` if errors == 0, else `TB FAIL (<n> errors)`.

## Sync FIFO (default DEPTH=16, DATA_WIDTH=32)

| ID | Spec | Scenario | Expected |
| --- | --- | --- | --- |
| S1 | C-05 | After reset | `empty=1`, `full=0`, `count=0`, `overflow=0`, `underflow=0` |
| S2 | C-01, S-04 | Write 1 element, then read it | `empty` falls then rises; data correct; `count` 0->1->0 |
| S3 | S-02 | Write DEPTH elements | `full=1`, `count=DEPTH`, `empty=0` |
| S4 | C-01, C-07 | Read all elements | FIFO order; `empty` rises only after the last pop; `rd_data` not checked when empty |
| S5 | C-03, C-04 | Write while full | Write ignored; `overflow` pulse 1 cycle after the attempt; old data intact (read back all) |
| S6 | C-03, C-04, C-06 | Read while empty | Read ignored; `underflow` pulse; state unchanged |
| S7 | S-03 | Simultaneous read and write, mid occupancy | `count` unchanged; data in order |
| S8 | S-03, C-04 | Simultaneous read and write while empty | Write accepted, read rejected with `underflow` pulse, `count=1` |
| S9 | S-03, C-04 | Simultaneous read and write while full | Write rejected with `overflow` pulse, read accepted, `count=DEPTH-1` |
| S10 | S-01, S-02 | Wrap-around: at least 3*DEPTH operations; also fill to full starting from non-zero pointer offsets in both MSB states | Data correct; `full`/`empty` correct at every wrap state |
| S11 | C-05, C-06 | Reset while holding data, then write new data and read | Only the new data is read; flags per C-05 |
| S12 | C-07 | Data patterns: all-0, all-1, alternating 0101/1010, walking-1 | No bit errors |
| S13 | C-07 | Write every cycle (while `full=0`), then read every cycle (while `empty=0`) | No loss, no gap; `overflow` pulses only when attempted while full |
| S14 | C-01 | FWFT timing | `rd_data` = head whenever `empty=0`; changes to next element in the cycle after a pop |
| S15 | Sec. 3 | Repeat S1-S13 with DEPTH=2, DEPTH=4, and once with DATA_WIDTH=8 | Same results |
| S16 | S-01, S-04 | Check `count` every cycle during S3, S4, S7 | Equals test-side reference counter |
| S17 | C-08 | Assert `wr_en`/`rd_en` while `rst_n=0` | No state change, no pulses; after release `empty=1` |
| S18 | Sec. 3 | Manual check: elaborate with DEPTH=3 and DEPTH=1 | Elaboration-time fatal error (not part of the regression) |

## Async FIFO (default DEPTH=16, DATA_WIDTH=32, N=3)

Driver rule for A5-A7: assert `wr_en` only when `full=0` and `rd_en` only when `empty=0`,
unless the test is explicitly about rejected operations (A8).

| ID | Spec | Scenario | Expected |
| --- | --- | --- | --- |
| A1 | C-05, A-06 | Reset both domains (overlap >= 4 edges each) | `empty=1`, `full=0`, `overflow=0`, `underflow=0` |
| A2 | A-03, C-01 | Write 1 element, wait | `empty` falls within <= 3 `rclk` edges; read returns correct data |
| A3 | A-02, A-03 | Start from reset or after waiting >= 3 `wclk` edges since the last read; write continuously with no reads | `full` rises exactly when DEPTH elements are stored; no overwrite |
| A4 | A-03, C-07 | Read all | FIFO order; `empty` rises after the last pop; `full` falls within <= 3 `wclk` edges after the first pop |
| A5 | C-07 | `wclk` period 1, `rclk` period 3 (write faster), >= 1000 words | No loss, no duplicate, order preserved |
| A6 | C-07 | `rclk` faster than `wclk` (3:1), >= 1000 words | Same as A5 |
| A7 | C-07, A-01 | Unrelated ratio (7:5) with phase offset, >= 1000 words | Same as A5 |
| A8 | C-03, C-04, A-08 | Write while full, read while empty | Rejected; `overflow` in `wclk` domain, `underflow` in `rclk` domain; data intact |
| A9 | A-04 | At every `rclk` edge check `empty=0` implies accepted writes minus accepted reads (before the edge) >= 1; at every `wclk` edge check `full=0` implies that difference < DEPTH | Never violated, under all clock ratios of A5-A7 |
| A10 | A-05 | Wrap-around, many laps; white-box check of `wptr_gray`, `rptr_gray` | Hamming distance between consecutive values <= 1; data correct |
| A11 | C-05, A-06 | Reset both domains mid-run, then run a short transfer | Back to initial state; new data only |
| A12 | Sec. 3 | Repeat key tests (A2, A4, A5, A10) with DEPTH=2 and DEPTH=16 | Same results |

## Coverage of requirements

Every requirement in spec.md must appear in at least one test row. Gaps found while
writing the testbench are recorded here and the spec is updated first, then the test.