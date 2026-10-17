# CLAUDE.md

Guidance for AI assistants working in this repository (coherent-cache-dv).
Human owner decides WHAT to verify and WHAT is correct. The assistant writes mechanical code and reviews.

## Project overview

Hardware design verification portfolio, built as seven projects that stack into one system:
a write-back cache with MSI coherence (2 cores), AXI-lite memory side, and a full verification environment.

| ID | Content |
|----|---------|
| P1 | Sync FIFO and async FIFO (gray pointers, CDC), Verilator lint, Quartus results |
| P2 | Class-based testbench: random stimulus, scoreboard, functional coverage |
| P3 | SVA for the FIFO and light formal proofs with SymbiYosys |
| P4 | Python multi-seed runner, regression summary, AI usage log |
| P4+ | LLM-based regression triage agent (log clustering, root-cause hints) |
| P5 | Direct-mapped write-back cache, AXI-lite memory side, C++ reference model |
| P6 | UVM environment for the cache, C++ model via DPI-C, AXI-lite monitor and assertions |
| P7 | 2-core MSI coherence, atomic snoop bus, SWMR checker, litmus tests, bug injection |

Each project has its own `pN/spec.md`. Read it before touching that project. If it conflicts with this file, stop and ask.

## Repository layout

```text
common/     shared packages (cov_lite_pkg, ...)
pN/         rtl/, tb/, and optionally quartus/, formal/
sim/        run.sh (Questa command-line flow)
tools/      Python runner, triage agent
reports/    logs, coverage reports, synthesis summaries (committed as evidence)
```

## Environment

- OS: Windows with Git Bash. Paths in commands use /d/dv/... style. There is no `make`; use `sim/run.sh` or Python scripts.
- Simulator: Questa Altera Starter FPGA Edition 2025.2 (UVM-1.1d bundled). Synthesis: Quartus Prime Lite 25.1. Also: Verilator, SymbiYosys (OSS CAD Suite), Python, gcc 7.4.0 bundled with Questa.
- Run: `source env.sh` then `./sim/run.sh <project_dir> <top> [+define+X]`.
- `env.sh` holds local paths and license settings. Never commit it. Never commit license files.

## Tool limitations (verified by smoke test, do not try to work around)

The local Starter edition lacks the `svverification` license. These FAIL locally:
`randomize()` (even with constraints), `covergroup`/`cross`, `randcase`, `randsequence`, and any `uvm_do*` macro (they call randomize).

These WORK locally: SVA (`assert property`, `cover property`), UVM-1.1d (phases, sequences, driver, analysis ports, scoreboard, factory) with manual randomization (`$urandom`, `$urandom_range`, `start_item`/`finish_item`), DPI-C, statement/branch code coverage (`vlog +cover=bcesf`, `vsim -coverage`, `vcover report -details`).

Do not try to fix this by changing licenses or recompiling tools.

## Two-mode rule (P2, P6, P7)

One testbench source, two modes selected by `ifdef VERIF_LIC`:

- Not defined (local): hand-written random with `$urandom_range`, coverage counted by `common/cov_lite_pkg.sv`. It prints one line per coverage group: `COV_LITE <name>: xx.xx% (N bins)`. Scripts parse this line.
- `+define+VERIF_LIC` (university lab or EDA Playground): real `randomize()` with constraints and real `covergroup`/`cross`.

Never use `uvm_do*` macros. Use `start_item`/`finish_item`.
READMEs must state which coverage numbers come from real covergroups (tool and date) and which come from cov_lite hand counting. Never present hand-counted numbers as covergroup results. Code coverage (statement/branch) is real and available locally.

## Coding conventions

- SystemVerilog: `logic`, not `reg`/`wire` for new code; `always_ff` / `always_comb`; non-blocking assignments in sequential blocks.
- Naming: `snake_case` for signals/modules, `UPPER_CASE` for parameters, `_n` suffix for active-low, `_i`/`_o` suffix for ports where useful, `clk_wr`/`clk_rd` style for multi-clock.
- Identifiers and comments in code are always English.
- One module or class per file. File name matches module/class name.
- RTL goes in `pN/rtl/`, testbench code in `pN/tb/`. RTL must not depend on testbench code.
- Parameterize widths and depths; assert illegal parameter values at elaboration.
- Bug injection uses a parameter or `ifdef BUG_<name>`, default off. Every injected bug must be caught by a named checker; record it in the project README.

## Verification roles (important)

- The human writes: test plan, correctness rules (spec, invariants, assertions to have), reference-model design, coverage bins and crosses, choice of bugs to inject.
- The assistant writes: boilerplate (interfaces, drivers, monitors, agents, env, base test, scripts), sequences from the human's description, SVA syntax from the human's rules, covergroup/cov_lite code from the human's bins.
- Do not infer the spec and then write both RTL and checker from that one reading. That causes common-mode errors (RTL and checker wrong the same way, test passes). The reference model must follow the human-written spec.
- Generate code in small pieces (one class or module at a time), each with a short explanation and the usual pitfalls.
- If the human has not provided a test plan or design, ask short guiding questions instead of deciding for them.
- Debug from evidence (log, waveform description, assertion message). State a hypothesis and how to test it before proposing a fix.

## Git rules

- Commit only when green: it compiles, the relevant tests ran, and results match the message.
- Small commits, one idea each. Do not mix RTL, testbench and README in one commit when they can be split.
- Messages in English, Conventional Commits, with this body:

```text
<type>(<scope>): <summary, imperative, <= 72 chars>

What:
- <main change>
Why:
- <reason>
Verify:
- <command run> -> <PASS/FAIL, seeds, coverage %>
Mode: local | VERIF_LIC (lab) | both
AI-assist: none | partial | heavy
```

- `type`: feat, fix, test, docs, refactor, chore, perf. `scope`: common, p1..p7, p4plus.
- `git add` specific paths. Never `git add .`.
- Never commit: `*.dat`, `license/`, `env.sh`, `work/`, `transcript`, `*.wlf`, `*.ucdb`, `*.vcd`, Quartus `db/`, `incremental_db/`, `output_files/`.
- Allowed from Quartus: `.qpf`, `.qsf`, `.sdc`, and summary reports copied into `reports/` (`*.fit.summary`, `*.sta.summary`).
- Tag each finished project: `p1-done`, `p2-done`, ... and `v1.0` for the final state.

## Definition of done for a project

1. `pN/spec.md` is complete and matches the implementation.
2. All tests pass locally (and with `VERIF_LIC` where the project requires two modes).
3. Injected bugs are caught; results are recorded.
4. README section for the project has real numbers (no `TODO` placeholders), with the tool and mode that produced each number.
5. No license files or build artifacts in the commit. Tag pushed.

## Do not

- Do not create diagrams, images, or extra files unless asked.
- Do not use internal or copyrighted third-party documents as input data.
- Do not state a number in a README that was not produced by a run recorded in `reports/`.