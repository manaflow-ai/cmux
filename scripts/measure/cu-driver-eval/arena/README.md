# Computer-use arena

Every computer-use engine the team is building, driven by the models we already use (Claude Code
with Opus and Sonnet, Codex with GPT), on one fixed task suite, in the same macOS 26.5 VM on the same
fleet Mac class. Each task is run N times per configuration, so every number is a rate, not an
anecdote. Leo, 2026-11-06: "the meaningful evals as well, like the cost efficiency, the speed, the
actual success rate and whatever, and of course, you know, the amount of CPU and RAM usage".

The engine never brings its own vision model: the harness's model sees the screen.

## Rerun it

One configuration, five runs of every task, on an idle macOS 26 measure worker:

```
cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
  --script scripts/measure/cu-driver-bench.sh --ref SHA --timeout 10800 \
  --artifact artifacts/cu-driver-eval.tgz \
  --arg=suite=arena --arg=base_url=http://HOST:PORT --arg=budget_s=10800 \
  --arg=arms=cu-fast --arg=harness=claude:claude-opus-5-5 --arg=reps=5
cmux-ci artifact STEP_ID cu-driver-eval.tgz
```

- `arms=` any of `cmux-cua`, `cua-driver-0.38.0`, `cu-fast`, `cu-rewrite`, `chief-desktop` (comma list).
- `harness=` any of `claude:MODEL` and `codex:MODEL` (comma list).
- `arena_tasks=` a comma list of task ids (default: all of `tasks.json`).
- `cu_fast=SHA`, `cu_rewrite=SHA`, `chief_desktop=SHA` measure another push of that PR than
  `pins.json` `arena.engines` names. To measure your own change, pass your branch's head here.
- `base_url=` is the team's model route as the worker reaches it; the guest reaches it as
  `127.0.0.1:4016` through the worker (cu-driver-eval/README.md, "The model route"), for Claude
  (`/v1/messages`) and Codex (`/v1/responses`) alike.

The artifact's `cu-driver-eval/arena/` holds `trials.jsonl` (one row per run), `summary.md`,
`summary.json`, `arms.json` (what each arm ran, with its commit) and `traces/` (each run's raw
harness output). `python3 arena.py summary DIR` merges any number of steps' `trials.jsonl` under
DIR into one table.

## Arms

| arm | whose | what it drives | how it sees | how it acts |
|---|---|---|---|---|
| `cmux-cua` | feat-cmux-next today | the cmux-cua helper at cmux's pin, daemon and MCP server started as cmux and acpmux start them, cmux's `skills/cmux-cua` | window screenshots plus the accessibility tree (`get_window_state`) | AX actions, else events posted to the app's pid |
| `cua-driver-0.38.0` | upstream (feat-cmux-next's "Upstream" driver) | Cua Driver 0.38.0 release, `mcp --direct`, the release's skill | the same, upstream | the same, upstream |
| `cu-fast` | Aziz, cmux#36993 | `cmux CU Engine.app`, built at the PR head, over its socket (`cmux-cu-service mcp`) | one batched AX read per node, a live ScreenCaptureKit window stream; every action returns the settled state and a JPEG | AXPress where it can, else CGEvents to the pid |
| `cu-rewrite` | Aziz, cmux#37003 | the Rust engine in its cmux Remote worker, built at the PR head, through `acpmux computer-use-mcp`; its `skills/cmux-computer-use` | `screenshot` (PNG, unchanged frames skipped) and `get_ui_tree` | AX, else events posted to the pid, policy-checked |
| `chief-desktop` | Austin, cmux#36515 | that PR's `cloud_computer` tool surface on this Mac (`chief_computer_mcp.py`), its skill's "Drive the desktop" section | a whole-screen screenshot op, nothing else | desktop-wide input at screen pixels (session tap, as xdotool on X11) |

`chief-desktop` is an emulation: cmux#36515 runs on a Linux Cloud desktop (Xvfb, cua-driver or
xdotool), which this VM is not. It measures that design (pixels only, desktop-wide input, a
screenshot when the model asks) against the accessibility-first ones on the same apps, not that
PR's Linux stack. `cu-rewrite` runs without the cmux app: `cu_rewrite_host.py` plays the two parts
the app's daemon and cmux Remote play (configure the worker, answer `computer-use-endpoint`),
because the real daemon refuses a cmux Remote that is not signed by the team.

## Tasks (`tasks.json`)

Eleven tasks, each with a check that reads the outcome itself: the arena app's own state file, a
file on disk, or the accessibility tree, never the model's word, except where the task asks for a
value. `arena_app.swift` is one AppKit app with a window per task.

| task | what | check |
|---|---|---|
| `form-fill` | fill a sign-up form (text, pop-up, checkbox) and submit | the form's state |
| `settings-pane` | open a settings pane's Advanced section, change two controls, touch nothing else | the settings' state |
| `read-label` | read a 6-character code from a label | the answer |
| `read-canvas` | the same code drawn as pixels, absent from the accessibility tree | the answer |
| `modal-recover` | a sheet blocks the window; dismiss it, then fill and save | the window's state |
| `list-scroll` | mark one invoice of 60 as paid; the target needs scrolling | only that row is paid |
| `minimized-recover` | the form starts minimized in the Dock | the form's state |
| `two-windows` | read a code in one window, type it into another, submit | the form holds the code |
| `textedit-save` | open TextEdit, type a sentence, save it to Documents through the save panel | the saved file |
| `calculator` | compute 4817 × 293 in Calculator | the answer and Calculator's display (AX) |
| `finder-move` | make a folder on the Desktop in Finder and move a file into it | the file system |

Every model gets the same words (`preamble` plus the task's prompt), and no prompt names a tool.
Claude Code runs with no built-in tools (`--tools ""`), so the engine's tools are its only way to
act; Codex runs with its shell, its own computer use, browser and apps switched off. A run that
still reaches a shell fails.

## What each run records

`arena.py` writes one row per run: passed and why not, wall seconds, tool calls (split into actions
and observations), model calls, screenshots (image blocks returned), tool errors, input tokens
(uncached, cached reads, cache writes) and output tokens, timeouts, and CPU (average and peak, % of
one core) and resident memory (peak and average MB) of four groups sampled twice a second: the
harness (the agent CLI), the engine (its MCP server, daemons and workers), the task's apps, and
WindowServer. Cost is reported in tokens and time only.

Model calls: Claude Code's are counted per assistant message; Codex exec reports none, so they are
one per batch of tool calls plus the closing answer (`model_calls_approx`).

## Not here yet

- A Linux desktop arm for cmux#36515's own stack (Xvfb, cua-driver on Linux), and cmux#37003's
  Linux and Windows desktops.
- cmux itself as a target app (it is on two engines' default deny lists).
- Codex's own computer use (`computer_use`) as a baseline arm: its helper ships with the Codex app.
