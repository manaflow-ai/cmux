# perf100 measurement system

The shared runner, fixtures, baseline and budget gate of the perf100 effort
([SPEC.md](SPEC.md)). Every lane measures with it, so a before and an after come from the
same scenario, seed and host. Code: `scripts/perf100/`. Baseline: [baseline/](baseline/).

## Where it runs (never a laptop)

| What | Host | Command |
|---|---|---|
| GUI scenarios S0-S4 + headless parts, one job | cmux-lawrence-2 (`nx-remote --needs gui`, app from the AWS fleet) | `nx-remote --detach --needs gui --allow-agents --no-route --app-from-fleet cmux --tag <tag> --ref <sha> --timeout 7200 -- 'bash scripts/perf100/nx-job.sh'`, then `nx-remote wait <job-id>` (exit 75: wait again; never resubmit). Results: `artifacts/nx-remote/<job-id>/perf100/`. |
| Headless cmux-tui and acpmux, Linux | rbx | `$HQ_ROOT/build-fleet/rust-builder/rbx --lane <lane> --cwd . -- bash scripts/perf100/rbx-headless.sh > rbx.log`, then `python3 scripts/perf100/perf100.py extract rbx.log --out DIR` |
| Headless, macOS, alone on the worker | AWS Mac (`cmux-ci run --class exclusive --measurement`) | `cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/perf100.sh --ref <sha> --artifact artifacts/perf100/results.json [--arg=mode=headless] [--arg=gate=1]`, then `cmux-ci artifact <step> results.json` and `perf100.py extract results.json --out DIR` |
| GUI, alone on the worker | cmux20-bench (`--label bench --target-worker cmux20-bench`, `--arg=mode=app`) | same script; the nightly CI job uses it |

`nx-job.sh` arguments: `app=S0,S1,S2,S3,S4|none`, `tui=S0,S1,S3,S4|none`, `acpmux=10,100|none`,
`seed=N`, `quick=1` (small sizes for a harness smoke run). `--allow-agents` is needed for S2
only: it starts the replay stand-in agent in the app's acpmux. Every app launch runs on a
scratch HOME with PATH `/usr/bin:/bin:/usr/sbin:/sbin` and `ACPMUX_LOGIN_ENV=0`, and every
launch except S2's sets `ACPMUX_AGENT_LAUNCH=deny`, so no real agent CLI can start.

Run a subset for your area, at your before and after SHAs, with the same seed and host:

```sh
# app lane: S0 only, before and after
nx-remote --detach --needs gui --no-route --app-from-fleet cmux --tag p100-app-a --ref <before> -- 'bash scripts/perf100/nx-job.sh app=S0 tui=none acpmux=none'
nx-remote --detach --needs gui --no-route --app-from-fleet cmux --tag p100-app-b --ref <after>  -- 'bash scripts/perf100/nx-job.sh app=S0 tui=none acpmux=none'
python3 scripts/perf100/perf100.py compare --before artifacts/nx-remote/<job-a>/perf100 --after artifacts/nx-remote/<job-b>/perf100
```

The runner of the measured SHA is the one that runs (the job's tree is that SHA). To measure
an older SHA that has no runner, cherry-pick `scripts/perf100/` onto it on a side branch.

## Scenarios (deterministic: seeded, scripted, no live model calls)

| | app (GUI) | headless |
|---|---|---|
| S0 idle | 10 terminals (3 run the idle agent TUI `fixtures/idle_tui.py`: alternate screen, blinking bar cursor, blocked on stdin), 5 Chromium tabs on local pages (`fixtures/pages.py`), the first terminal shown; 60 s idle window; then keystroke-to-glyph | cmux-tui: same 13 terminals; 60 s idle |
| S1 flood | `yes \| head -c 200M` in 1 terminal, then in 10 terminals at once (tabs of one pane: one visible); each starts on its own go FIFO and reports on a done FIFO | same, with one attached client per terminal counting the bytes it receives |
| S2 agents | 10 acpmux sessions on `fixtures/replay_agent.py`, each a workspace; each streams a seeded recorded fixture (`fixtures/agent-streams/`, speed 2); then token-to-page on the visible agent pane | acpmux: 10 and 100 sessions, `acpmux send` as the client; token-to-client latency |
| S3 scale | 200 workspaces x 5 terminals, capped by the PTYs a shared GUI host may take (default 300, leaving 150 free); per-terminal and per-workspace memory | cmux-tui: 200 x 5 = 1000 terminals (macOS caps at free PTYs; Linux does not) |
| S4 start | cold start to interactive, quit; build the S3 session, quit keeping sessions, launch on the same profile: to interactive and to all workspaces | cold start to `identify`; daemon restart that adopts the S3 terminals; shutdown |

Fixtures: `streams.py generate` makes the three stream fixtures from fixed seeds and
`MANIFEST.json` pins their sha256; every run verifies them and records the digests.
The fixtures are synthetic Markdown (prose, lists, tables, code) with the chunk sizes and
cadence of ACP streams from Claude Code and Codex (1-6 words per chunk, 60-90 words a second);
they hold no recorded user content.

## Metrics and their sources

Per process, summed by group (`app`, `tui` = daemon + terminal hosts, `acpmux`, `browser` =
CEF and WebKit helpers, `helpers`; `cmux` = their sum; `agents` = replay stand-ins, `workload`
= the programs in the terminals and `harness` = the runner's CLI calls are shown apart and are
not in `cmux`):

| Metric | macOS (no root) | Linux |
|---|---|---|
| CPU-seconds, CPU % | `proc_pid_rusage(RUSAGE_INFO_V6)` user + system | `/proc/pid/stat` |
| wakeups/s | `ri_interrupt_wkups` (all wakeups from idle; `ri_pkg_idle_wkups`, a subset, is 0 on Apple silicon and is reported apart) | voluntary context switches of every thread |
| RSS, footprint | `ri_resident_size`, `ri_phys_footprint` (Activity Monitor "Memory") | VmRSS, Pss |
| peak footprint | sum of each kind's peak over 0.5-2 s samples | same |
| threads, syscalls | `proc_pidinfo(PROC_PIDTASKINFO)` | `/proc/pid/status`, `/proc/pid/io` syscr+syscw |
| bytes written to disk | `ri_logical_writes` (file writes before the cache; the most precise unprivileged per-process source on macOS); `ri_diskio_byteswritten` as `disk_io_written` | `/proc/pid/io` `write_bytes` (exact) |
| on-disk size | allocated blocks under the scratch HOME / state root after the scenario | same |
| socket bytes | bytes the runner's own clients receive (attach streams, `acpmux send`); no unprivileged per-process Unix-socket counter exists on either OS | same |
| latency guards | keystroke-to-glyph: `debug.key` to the key on the terminal mirror's viewport text (`debug.surfaces text`, read every 2 ms: an upper bound by one read); token-to-page: marker written by the agent to the marker in the agent pane's chat state (`debug.agent_pane chat_state`, read every 5 ms; the paint after it is not in it); launch-to-interactive: `open` to a typed key on screen | keystroke-to-echo (`send` to attach output); token-to-client (agent write to `acpmux send` stdout) |

A process that ends between two samples keeps its last sample (up to one interval lost).
The sampler reads counters only; it adds no wakeups or CPU to the measured processes.

## Output

One JSON per scenario run (`perf100.run.v1`): host (name, class, model, cores, RAM, OS,
load before and after), build (tag, SHA, fixture digests), scenario, variant, seed, params,
every phase's per-group and per-kind counters and top processes, latencies, on-disk sizes,
notes and UNVERIFIED items, and a flat `metrics` map (`<phase>.<group>.<metric>`,
`<phase>.per_<unit>.<metric>`, `latency.<name>.p50_ms`, ...). `perf100.py report DIR` writes
the Markdown tables; `perf100.py compare --before A --after B` prints before, after and
before/after (the factor by which a number went down) for every metric.

## Budgets (the CI regression guard)

`scripts/perf100/budgets.json` holds every lane's budgets, one entry each:

```json
{"id": "s0-app-idle-cpu", "lane": "app", "scenario": "S0", "variant": "app", "host": "cmux20-bench",
 "metric": "idle.app.cpu_pct", "limit": 16.0, "margin_pct": 25, "direction": "max",
 "note": "app idle CPU at S0; baseline <sha> 2026-10-20"}
```

A run of that scenario, variant and host class fails the budget when the metric is above
`limit * (1 + margin_pct/100)` (`direction: min`: below `limit * (1 - margin_pct/100)`), when
it is missing, or when the run had an error. `host: "*"` matches every host (only for
host-independent counts). A lane that wins a number lowers its `limit` in the same landing.
`perf100.py budget --results DIR` prints every budget's verdict and exits 1 on a break.

CI: `.github/workflows/cmux-next-perf100.yml` (not a required check yet).
- `headless`: on pushes and same-repo PRs into feat-cmux-next that touch `cmux-tui/crates`,
  `cmux-tui/Cargo.lock` or the runner, and nightly: `scripts/measure/perf100.sh mode=headless
  gate=1` on an AWS Mac, class exclusive (host class `aws-m4pro`).
- `app`: nightly on cmux20-bench (host class `cmux20-bench`), `mode=app gate=1`.
cmux-lawrence-2 cannot be reached from GitHub Actions, so its runs (the baseline) go through
nx-remote; budgets for it (`host: "cmux-lawrence-2"`) are checked by `nx-job.sh` at the end of
each job.
