# perf100: cmux NEXT, cmux-tui, acpmux and the ACP stack, 100x cheaper

Owner: the coordinator session (Lawrence's request, 2026-10-20 20:15 PDT).
Goal (Lawrence): CPU, RAM, disk and IO cost 100x lower wherever physics allows, with no
loss of correctness or features. Every claim needs a before and an after number from the
same scenario on the same host. Where 100x is not physically possible, measure the floor
and say why; do not hide it.

## Real-world baseline (Lawrence's laptop, NIGHTLY 3952613909201, 2026-10-20 20:10 PDT, read-only ps/top)

| Process | CPU | RSS / footprint | Threads | Idle wakeups/s |
| --- | --- | --- | --- | --- |
| NIGHTLY total (76 processes) | 79% | 12.9 GB RSS | | |
| app `MacOS/cmux` (pid 36263) | 16.6% while idle | 1.49 GB footprint | 119 | 22 |
| `cmux-tui --headless --session cmux-app` (31929) | 40% (old build, PR 22811 not shipped) | 394 MB RSS / 701 MB footprint | 677 | |
| `cmux-tui --headless --session cmux-chief-*` (19566) | 1.7% | 265 MB RSS | **1743** | |
| `acpmux daemon run` (92997, 40 min) | 0% | **2.0 GB RSS** | 28 | |
| `acpmux daemon run --ready-fd 3` (32125) | 0% | 146 MB | 28 | |
| two acpmux daemons run at the same time | | | | |
| `claude` agent CLIs started by acpmux (~25) | low | 150-350 MB each, ~6 GB | | |
| Chromium renderers (7) | 0.5% | 1.3 GB | | |
| Chromium GPU process | 15% while idle | 157 MB | | |
| `cmux mcp serve` (4) | 0 | ~38 MB each | | |
| Disk: `~/Library/Application Support/cmux-tui` | | **53 GB** | | |
| Disk: idle terminal journal writes (before PR 22811) | | ~25 MB/s | | |

## Metrics every lane reports (before and after, same scenario, same host)

CPU: idle % over 60 s, and CPU-seconds per scenario. Wakeups/s while idle.
RAM: RSS and phys_footprint (`footprint` / `vmmap --summary`) at steady state, and per unit
(per terminal, per tab, per agent session). Threads.
Disk: bytes written per minute while idle and per scenario; on-disk size after the scenario.
IO: syscalls or bytes over sockets per scenario where relevant (e.g. per streamed agent token).
Latency (must not get worse): keystroke-to-glyph, agent token-to-screen, launch-to-interactive.

## Standard scenarios (deterministic, scripted, seeded)

S0 idle: app open, 10 terminals with idle shells, 3 idle agent TUIs that only blink a cursor,
   5 browser tabs, 60 s.
S1 terminal flood: `yes | head -c 200M` style output in 1 terminal, then 10 at once.
S2 agent streaming: 10 agent sessions streaming long Markdown replies (recorded fixtures,
   not live model calls), plus 100 agents for the scale case.
S3 scale: 200 workspaces, 1000 terminals (headless where possible).
S4 cold start and quit, and restart-to-update with the S3 session.

Fixtures and the runner live in one place (the perf-harness lane builds them); lanes may run
the subset that covers their area. No live model calls in benchmarks.

## Where to run (never the laptop)
Rust: rbx or Blacksmith Testbox. Headless Swift: `cmux-ci run` on the AWS Macs. GUI app and
whole-app scenarios: `nx-remote --needs gui` on cmux-lawrence-2 (detach + wait). The laptop is
only for read-only `ps`/`top`/`sample` of Lawrence's own running NIGHTLY.

## Rules
- Correctness first: every change keeps or adds behavior tests at a real boundary; no unit
  tests (lane rules). Existing suites stay green (or are proven red on the base).
- No feature removal and no lower defaults to win a number. A real trade-off (e.g. slower
  resume of an idle agent) goes to the coordinator as a decision with numbers, not into code.
- No sleeps or polling for synchronization; event-driven.
- One PR per root cause into `feat-cmux-next` (merging there is authorized; never main),
  correctness-first review subagent, findings posted on the PR, land with gate-run + safe-push.
- Add a CI regression guard for each win (a budget test at a real boundary that fails if the
  number regresses by more than a margin; run on the host that measured it).
- Report: a table per metric with before, after, ratio, scenario, host, commit SHAs.

## Lane ownership (do not edit another lane's files; send findings to the coordinator)
- perf-harness: scenarios, fixtures, runner, baseline table, CI budget framework.
- acpmux: the acpmux daemon (RAM, CPU, IO, duplicate daemons, per-session cost, agent process lifecycle).
- acp-fork: private forks of third-party ACP code + cmux-codex-acp efficiency.
- tui: cmux-tui service except the journal/output store (threads, terminal state memory, render/diff, socket protocol, fanout).
- app: the Swift app's idle CPU, wakeups, RAM, timers, layout, view memory (not hangs).
- browser: CEF/Chromium processes, tab RAM, GPU idle CPU, hibernation.
- Already running elsewhere (do not duplicate): terminal output store + journal migration
  (output-store lane), main-thread hangs audit, crash-to-hang (PR 22843), selector scanner,
  GUI fuzzer, slow quit/launch on update.
