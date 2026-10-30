# Austin's day: the P-AUSTIN load scenario

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

# A/B on the same mini: base and head alternate (base, head, base, head), 2 runs each:
scripts/cmux-next/austins-day/austins-day.sh --base <JOB|SHA> --head <JOB|SHA> --runs 2 --out /work/tmp/ad-<name>
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
`--swap-gb 6`, `--close-every 30`, `--baseline 10`. The defaults are Austin's shape; change them only
to explore, and say so next to any number you cite.

## The load

- **80 terminal agents** in 20 workspaces. Each terminal runs `claude` the way a person does: the
  cmux `claude` shim and `cmux-tui agent claude-wrapper` run, find `fake_claude.py` as the real
  Claude, and give it the hook settings file. `fake_claude.py` then does what Claude Code does with
  those hooks: on each tool call it runs the PreToolUse and PostToolUse hook commands
  (`$CMUX_TUI_HOOK claude <event>`) and on each turn end the Stop hook, with Claude Code's payload.
  It waits for sync hooks and lets `async` hooks run on. Each tool call is real git or file work in
  the agent's worktree, and every third call is also one `cmux` CLI call.
- **The shared repo**: `packs.py` builds a `--filter=blob:none` partial clone with 8 worktrees and
  19,110 promisor packs (a few real fetches, then valid one-blob packs written directly), once per
  host under `/Users/Shared/cmux-capture/austins-day/`.
- **Chief waves**: every 60 s, 25 acpmux sessions opened at once on the app's acpmux (the acpmux
  test agent as harness `ad-fake`), each with a streamed prompt.
- **Memory pressure**: `hog.py` holds incompressible memory until swap used is 6 GB above the start.
  When the kernel's free-memory level falls to 12 it gives memory back, and it ends by itself at the
  end of the load.
- **Workspace close**: every 30 s a new workspace is made and closed through the app's
  `closeWorkspace` action (the sidebar's close).

## What it measures

Everything is over the load phase. Distributions are p50/p95/p99/max; the rest are counts.
`OUT/summary.json` holds every run and the median per arm; `OUT/summary.txt` is the short form.
Each run directory keeps `run.json` (all samples), `driver.log`, `app-log.txt`, `debug-hangs.json`,
`hog.jsonl` and the agents' logs.

- `app_requests`: the app's own daemon requests, send to reply, from the app probe
  (`debug.daemon_requests`; `null` for a build without it), and `app_no_reply_within`, the
  "no reply within" time-outs in the app's log, by command.
- `person_cli_ms` / `person_cli_refusals`: a `cmux workspace list` from outside every terminal,
  once a second, and its refusals (`server.busy`, `session.busy`, `session.no_answer`).
- `agent_hook_ms`, `agent_cli_ms`, `agent_cli_refusals`, `agent_tool_ms`: from the agents' logs.
- `daemon_connections` (accepted, refused, peak, limit), `daemon_lock_wait_us`,
  `daemon_lock_hold_us`, `daemon_lock_top_sites`, `journal_commit_us`: from `cmux server stats`.
- `workspace_close_app_ms` / `workspace_close_daemon_ms`: time from the close action until the
  app's topology and the daemon's list no longer have the workspace; `workspace_close_not_done`.
- `acpmux_new_ms`, `acpmux_prompt_ms`, `acpmux_errors`, `acpmux_restarts` (the daemon pid changed),
  `acpmux_unresponsive_log`.
- `memory`: RSS and footprint over time for the app, the daemon and acpmux; `load1`,
  `swap_used_mb`, `memory_level_min`.
- `stall_sites`: `debug.hangs` at the end of the run. Each stall over 100 ms with a cmux frame is
  listed by its top cmux symbol, with the owner from `plans/cmux-next/OWNERS.md` (P-MAIN rule G).
- `austin_failure`: which of Austin's failures the run showed (refused connections, app no-reply,
  lock wait p99 over 1 s, acpmux restarts, cmux stalls). A run that shows none did not reproduce
  his day; say so, do not cite it as a reproduction.

## Check the harness

`python3 scripts/cmux-next/austins-day/selftest.py` checks the parts that need no Mac (the fake
Claude's hooks, the pack fixture, the summary math, the hog's deadline) in seconds, on any host
with git. Run it yourself after a harness change; it is not wired into CI.
