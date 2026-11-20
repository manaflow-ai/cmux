# Austin's day: the P-AUSTIN load scenario

**Owner: the P-AUSTIN harness owner (agent pa-d; cmux-ad decision 2026-10-30).** Only the owner changes
this folder, in its own PR. The owner runs the A/B for each P-AUSTIN fix PR and posts the result on that
PR; the merge gate for the P-AUSTIN items reads that posted result. Fix authors never edit this folder and
never tune its load, duration or thresholds; ask the owner for the A/B. `summarize.py` refuses a head
that changes this folder ("invalid: head edits the harness").

Austin's nightly-next was unusable on 2026-10-29: about 80 terminal agents, load average 150-252,
swap 17 of 18 GB, a shared `.git` with 19,110 packs. The daemon's 64 connections were full
(55,162 refused in 2.5 hours, the app's own requests among them), the state lock waited p90 5 s and
p99 17 s, the app restarted acpmux on its 2 s time-outs, window-state saves got "no reply within
2.0 s", and closing a workspace did nothing (#27698, #27702, #27693).

This harness puts that load on a fleet capture mini against a tagged build of one commit, and
measures it. It is **held out**: B fixes are measured on it, never tuned against it. It is a fleet
bench that each agent runs itself. It is **not** a CI job or a gate (Lawrence 2026-10-23). Never
run it on a person's Mac: it fills the memory up to swap and starts 80 agents.

## Run it

From an agent VM or workstation that reaches the capture minis, in a checkout of this branch:

```sh
export CAPTURE_HOST_HOSTS="cmux17 cmux18 cmux19 cmux20 cmux21 cmux22 cmux23 cmux24"   # never cmux16
export CAPTURE_HOST_SLOT_HOSTS="$CAPTURE_HOST_HOSTS"

# One commit (a done `cmux-ci build cmux` job id, or a 40-hex sha with a done build):
scripts/cmux-next/austins-day/austins-day.sh --build <JOB|SHA> --out /work/tmp/austins-day-<name>

# A/B on the same mini: base and head alternate (base, head, base, head, ...), 5 runs each (the default):
scripts/cmux-next/austins-day/austins-day.sh --base <JOB|SHA> --head <JOB|SHA> --out /work/tmp/ad-<name>
```

Build a commit first if it has no build:
`cmux-ci build cmux --ref <SHA> --tag <tag> --backend-mode local --workspace <unique key>`
(run it from a checkout whose HEAD is that SHA).

Each run takes its own `capture-host acquire --slot --exclusive` lease (no fleet step runs on the
mini meanwhile; at most 10 minutes), stages the build and the pack fixture once per host, launches
the app in the slot, runs the load for what the lease leaves (about 5 minutes), quits the app with
its sessions ended, and releases the lease. The A/B arms run on the host of the first run
(`--prefer`); `summary.txt` says whether each round stayed on one host. Compare arms only on one host.

Options after `--` go to `driver.py`: `--agents 80`, `--per-workspace 4`, `--tool-gap 3.0` (mean
seconds between an agent's tool calls), `--cli-every 3`, `--wave-size 25`, `--wave-period 60`,
`--swap-gb 14`, `--stream-cps 300`, `--cpu 0.15`, `--close-every 30`, `--baseline 10`. The defaults are Austin's shape; change them only
to explore, and say so next to any number you cite.

## The load

- **80 terminal agents** in 20 workspaces. Each terminal runs `claude` the way a person does: the
  cmux `claude` shim and `cmux-tui agent claude-wrapper` run, find `fake_claude.py` as the real
  Claude, and give it the hook settings file. `fake_claude.py` then does what Claude Code does with
  those hooks: on each tool call it runs the PreToolUse and PostToolUse hook commands
  (`$CMUX_TUI_HOOK claude <event>`) and on each turn end the Stop hook, with Claude Code's payload.
  It waits for sync hooks and lets `async` hooks run on. Each tool call is real git or file work in
  the agent's worktree. **Main arm (from 2026-10-30): the agents make no `cmux` CLI calls** (`--cli-every
  0`, the default): no shipped hook, plugin or status line calls `cmux workspace list` per turn, and hooks
  send only `session.journal.append`. The earlier scenario's one `cmux workspace list` per 3 tool calls had
  no evidence; it filled the 64-slot pool with CLI calls and drove 43 % of the registry lock busy share. It
  stays as a labeled "assumed" sensitivity arm (`-- --cli-every 3`). Results of the two arms are never
  compared with each other: the summary refuses runs with mixed rates. Between tool calls it
  draws to its terminal as Claude Code's TUI does (a spinner rewritten 10 times a second and about
  300 characters a second of streamed text) and keeps 15 % of a core busy.
- **The shared repo**: `packs.py` builds a `--filter=blob:none` partial clone with 8 worktrees and
  19,110 promisor packs (a few real fetches, then valid one-blob packs written directly), once per
  host under `/Users/Shared/cmux-capture/austins-day/`.
- **Chief waves**: every 60 s, 25 acpmux sessions opened at once on the app's acpmux (the acpmux
  test agent as harness `ad-fake`), each with a streamed prompt.
- **Memory pressure**: `hog.py` holds incompressible memory until swap used is 14 GB above the start
  (Austin: 17 of 18 GB swap), at most 90 % of physical memory.
  When the kernel's free-memory level falls to 12 it gives memory back, and it ends by itself at the
  end of the load.
- **Workspace close**: every 30 s a new workspace is made and closed through the app's
  `closeWorkspace` action (the sidebar's close).

## When a result counts

- **The base must reproduce Austin's day.** Each run lists `austin_failure`: refused daemon connections,
  app requests with no reply in time, registry lock wait p99 over 1 s, acpmux restarts, cmux main-thread
  CODE stalls over 100 ms. If any base run shows none of them, the summary says "invalid: base did not
  reproduce" and gives no verdict.
- **The base is the PR's parent commit.** For a stacked PR that is the head of the PR below it, not
  the merge base with feat-cmux-next; base..head must be exactly the PR's own commits. The summary lists
  them, and a base that is not an ancestor of the head is invalid.
- **A revert pair is a valid base too:** a "before" ref that is the head plus one commit reverting the fix
  (the base's parent is the head and its subject starts with "Revert "). base..head is then the fix alone.
- **The head must not change the harness** ("invalid: head edits the harness").
- **Requested comparisons:** values a lead or a fix author asks for that are not verdict rows (the registry
  lock held share, the lock wait p99, the app request p99, named lock sites' hold p99 and total hold) get
  the same paired t-interval and n under "requested paired comparisons", with no verdict and no A/A check.
  A named lock site (`NAMED_LOCK_SITES`: a function and its lock lines in the builds measured; check it
  before using it on other builds) that is in neither top-20 list is 0 when the lock lists all its sites,
  else unknown: that round is dropped and "dropped N" is shown, and each run's line gives an upper bound
  instead (the smallest listed value), never mixed into the paired difference.
- **Per metric, the base must show that metric's failure**, by a budget the product or the brief states
  (`METRIC_FAILURE` in `summarize.py`): refused connections, any; lock wait p99, over the daemon's own
  100 ms stall line; app request, p99 over 50 ms or any time-out (the B3 target); workspace close, over
  the 2 s action deadline or never finished; CLI and hook latency and hook CPU, the base refused
  connections. Else that metric says "invalid: base did not reproduce". A metric the build cannot report
  (the app probe in an older build) says "not measured".
- **Noise.** For each metric the summary gives a paired t-interval: the 95 % confidence interval of
  mean(head - base) over the rounds (one base and one head run on one host per round), t with n - 1
  degrees of freedom. It says `better` or `worse` only when the whole interval is on one side of 0,
  otherwise `no difference`. Every metric is lower-is-better. (A percentile bootstrap was used before
  2026-10-30; over 5 pairs it is far too narrow, and the A/A showed it.)
- **Run order.** Rounds alternate which arm runs first (ABBA: base first in odd rounds, head first in
  even rounds). With 5 rounds, 3 start with the base, so one fifth of a position effect stays in the arm
  difference; the interval is wider than that, and the position column shows the effect apart. Each metric also gets a position estimate, second run minus first run; a metric whose
  position interval excludes 0 is flagged "POSITION EFFECT" (a warm-up or drift effect).

## A/A self-test

The A/A record (`aa-failures.json`) is kept per scenario, keyed by the agent CLI rate: `"0"` the main arm,
`"3"` the assumed sensitivity arm. An A/B whose scenario has no A/A yet says "not A/A-checked" on every
verdict.

`austins-day.sh --aa <JOB|SHA>` runs one build in both arms, the same 5 alternating rounds. Every metric
must show no difference: its 95 % interval must contain 0. A metric that fails is a harness defect (a
bias from run order, warm caches, or the host), not a product result. The owner records the failed
metrics in `aa-failures.json` in this folder, and from then on every summary marks that metric
"invalid (fails A/A)" until a later A/A passes it. The A/A runs before any A/B is cited, and again after
every harness change that could change a measurement.

## The long arm (memory over an hour)

For #27693 (the app at 20.7 GB): `--seconds 3600`, one run per arm, measuring RSS and footprint of the
app, daemon and acpmux over time (`growth_per_hour`, a least-squares slope), their open fds, and the stall
count. The 5-minute arm stays the latency A/B. **Blocked:** a capture-host lease lasts at most 10 minutes
(`MAX_SECONDS=600`), so the long arm needs a fleet step that holds an exclusive mini for an hour, and
`cmux-ci run` takes only scripts on the controller's allowlist. Until hq allowlists an Austin's-day step,
the long arm does not run. It is never a CI job (Lawrence 2026-10-23); it runs nightly by the owner's
schedule or a fleet timer.

## What it measures

Distributions are p50/p95/p99/max; the rest are counts. The harness's own samples (CLI and app probes,
memory, load, swap, hooks, closes, waves) cover the load phase. The daemon's `server-stats` histograms
(lock wait and hold, journal commit) and the app's `debug.hangs` count from their process's start, so
they also cover setup and the 10 s baseline; the app probe and the refused rate are read as differences
over the run's own window.
`OUT/summary.json` holds every run and the median per arm; `OUT/summary.txt` is the short form.
Each run directory keeps `run.json` (all samples), `driver.log`, `app-log.txt`, `debug-hangs.json`,
`hog.jsonl` and the agents' logs.

- `app_requests`: the app's own daemon requests, send to reply, from the app probe
  (`debug.daemon_requests`; `null` for a build without it), and `app_no_reply_within`, the
  "no reply within" time-outs in the app's log, by command.
- `person_cli_ms` / `person_cli_refusals`: a `cmux workspace list` from outside every terminal,
  once a second, and its refusals (`server.busy`, `session.busy`, `session.no_answer`).
- `agent_hook_ms`, `agent_hook_cpu_ms`, `agent_hook_cpu_total_s`, `agent_cli_ms`, `agent_cli_refusals`,
  `agent_tool_ms`: from the agents' logs. Hook CPU is user plus system time of each hook command and the
  children it waited for (`wait4`); a helper's detached child is not counted.
- `daemon_connections`: accepted, refused, peak, limit, and, for comparing arms, `refused_per_s` over the
  run's own server-stats window and `refused_share` of connects (the last answered server-stats comes at
  a different time in each run, so a raw cumulative count is never compared). Who fills the pool:
  `pool_holders`, during the load, counts the live hook-helper and `cmux` CLI processes and the refusals
  each client kind saw itself; `pool_holders_after_load` is the daemon's own client list (`cmux-tui client
  list`; `client` is a scope only the `cmux-tui` name accepts) by kind/name, read once right after the
  load. `lock_top_sites` is server-stats `locks`, the top 20 sites of the registry lock and mux.state by
  total and by p99 hold, also read once after the load; its numbers count since the daemon started, so
  setup and the baseline are in them. The samplers stop before these reads, so they add nothing to any
  measured window. `daemon_lock_wait_us`,
  `daemon_lock_hold_us`, `daemon_lock_top_sites`, `journal_commit_us`: from `cmux server stats`.
- `workspace_close_app_ms` / `workspace_close_daemon_ms`: time from the close action until the
  app's topology and the daemon's list no longer have the workspace; `workspace_close_not_done`.
- `acpmux_new_ms`, `acpmux_prompt_ms`, `acpmux_errors`, `acpmux_restarts` (the daemon pid changed),
  `acpmux_unresponsive_log`; `acpmux_opens`, `acpmux_open_failures`, `acpmux_open_failure_share`,
  `acpmux_host_start_timeouts` ("agent host start did not finish within 10s") and
  `acpmux_agent_start_timeouts` ("agent_start did not finish within 90s") from the Chief waves (owner of
  the fix: pa-b10). Each chat is one attempt: its `session/new`, or the connection that failed before it
  (refused, closed, no answer), which is a failed open. Verdicts use the failure share, not the count (a
  faster head runs more waves). Runs from before harness a84ddb0e414 do not record chats: their failed
  connections are not counted, an undercount.
- `memory`: RSS and footprint over time for the app, the daemon and acpmux; `growth_per_hour` (RSS,
  footprint and fds, least-squares slope); `fds` (open file descriptors, `lsof`); `load1`,
  `swap_used_mb`, `memory_level_min`.
- `stall_sites`, `stall_code_*`, `stall_wait_*`: `debug.hangs` at the end of the run (P-MAIN rule G).
  A stall over 100 ms is **CODE** when the main thread was on the CPU for at least half of it
  (`cpu_ms >= duration_ms / 2`, or the app's own `cause` when its `debug.hangs` gives one), else a
  **WAIT** (page faults, swap-ins, a lock). Only CODE stalls with a cmux frame are reds, listed by their
  top cmux symbol with the owner from `plans/cmux-next/OWNERS.md`. WAITs are counted apart (count, total
  ms, largest CPU share, page-ins) and reported next to memory and swap: under memory pressure they are
  what a person feels, and B8 (memory) owns them.
- `austin_failure`: which of Austin's failures the run showed (refused connections, app no-reply,
  lock wait p99 over 1 s, acpmux restarts, cmux CODE stalls). A run that shows none did not reproduce
  his day; say so, do not cite it as a reproduction.

## Check the harness

`python3 scripts/cmux-next/austins-day/selftest.py` checks the parts that need no Mac (the fake
Claude's hooks, the pack fixture, the summary math, the validity rules, the t-interval verdicts, the
hog's deadline) in seconds, on any host with git. Run it yourself after a harness change; it is not wired into CI.
