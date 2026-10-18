# CLAUDE.md

Guidance for AI assistants working in this repository (coherent-cache-dv).
The human owner decides WHAT to verify and WHAT is correct. The assistant writes mechanical code and reviews.

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

Each project has its own `pN/spec.md` and (for P1 onward) `pN/test_plan.md`.
Read them before touching that project. The spec is written by the human and is the single source of truth.
If the spec conflicts with this file, or if RTL/tests conflict with the spec, STOP and ask. Never edit a spec on your own.

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
- Run simulation: `source env.sh` then `./sim/run.sh <project_dir> <top> [+define+X]`.
- Lint: `verilator_bin.exe --lint-only -Wall -sv <files> --top-module <module>` (needs VERILATOR_ROOT from env.sh).
- Formal (from P3): `sby -f <file>.sby`, with assertions wrapped in `ifdef FORMAL`.
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

## University lab sessions

The human only uses the university lab when truly needed. Never silently assume the lab is available.
Start the reply with a block beginning with `[CẦN LAB TRƯỜNG]` when:

1. A project needing real `randomize()`/`covergroup` results (P2, P6, P7) is done or nearly done and the README lacks those numbers.
2. The human asks to run or check something that needs `randomize()`, `covergroup`, `randcase`, `randsequence` or `uvm_do*` for real results.
3. A job application is near and the portfolio lacks real numbers for two-mode projects.
4. A license error (`svverification` or similar) appears that cannot be fixed by switching to local mode.
5. First lab session: check whether the lab has the `svverification` license.

The block must contain: the reason, exact commands to run at the lab (clone, `vlog -sv +define+VERIF_LIC ...`, `vsim -c -coverage ...`, `vcover report -details`, save logs to `reports/`), what to bring back and how (commit/push), estimated duration and which projects to batch, and the fallback (EDA Playground with Riviera-PRO EDU, short tests).
Safety at the lab: never store a GitHub token or personal password on the lab machine; never commit license files.

## Coding conventions

- SystemVerilog: `logic`, not `reg`/`wire` for new code; `always_ff` / `always_comb`; non-blocking assignments in sequential blocks.
- Naming: `snake_case` for signals, modules and files; `UPPER_CASE` for parameters; `_n` suffix for active-low.
- Clock and reset names follow the project spec. P1: `clk`, `rst_n` (sync FIFO); `wclk`, `rclk`, `wrst_n`, `rrst_n` (async FIFO). Do not invent other names (no `clk_wr`, no `_i`/`_o` suffixes unless the spec says so).
- Identifiers and comments in code are always English.
- One module or class per file. File name matches module/class name.
- RTL goes in `pN/rtl/`, testbench code in `pN/tb/`. RTL must not depend on testbench code.
- Parameterize widths and depths; assert illegal parameter values at elaboration (fatal error).
- Bug injection uses only `ifdef BUG_<NAME>`, passed by `+define+`, default off. Do not use parameters for this. Every injected bug must be caught by a named checker; record it in the project README.
- Tests and assertions cite the spec requirement ID (for example C-04, S-03, A-04) in a comment or message.

## Verification roles (important)

- The human writes: test plan, correctness rules (spec, invariants, assertions to have), reference-model design, coverage bins and crosses, choice of bugs to inject.
- The assistant writes: boilerplate (interfaces, drivers, monitors, agents, env, base test, scripts), sequences from the human's description, SVA syntax from the human's rules, covergroup/cov_lite code from the human's bins.
- Do not infer the spec and then write both RTL and checker from that one reading. That causes common-mode errors (RTL and checker wrong the same way, test passes). The reference model must follow the human-written spec.
- Generate code in small pieces (one class or module at a time), each with a short explanation and the usual pitfalls.
- If the human has not provided a test plan or design, ask short guiding questions instead of deciding for them.
- Do not add code the human cannot explain. If the human does not understand a part, explain it and ask them to restate it before it is committed.
- Debug from evidence (log, waveform description, assertion message). State a hypothesis and how to test it before proposing a fix.

## Language

- Talk to the human in Vietnamese unless they write in another language.
- Code identifiers and comments: English. Repo documents (spec.md, test_plan.md, README, commit messages): English.

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
- Before an application is sent: READMEs have real numbers (no `[X]`/`TODO`), no license in the repo, tags pushed.

## Definition of done for a project

1. `pN/spec.md` is complete and matches the implementation.
2. All tests pass locally (and with `VERIF_LIC` where the project requires two modes).
3. Injected bugs are caught; results are recorded.
4. README section for the project has real numbers (no `TODO` placeholders), with the tool and mode that produced each number.
5. No license files or build artifacts in the commit. Tag pushed.

## Do not

- Do not create diagrams or images unless asked.
- Do not create files beyond what the current task needs (RTL, tests, scripts, docs for the task are fine; unrequested extras are not).
- Do not use internal or copyrighted third-party documents as input data.
- Do not state a number in a README that was not produced by a run recorded in `reports/`.
- Do not modify `spec.md` or `test_plan.md` without the human's explicit approval.