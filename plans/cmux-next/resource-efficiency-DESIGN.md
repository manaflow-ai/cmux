# cmux next: zero idle CPU and minimum RAM (2026-10-20)

User requirement (2026-10-20): "make sure when cmux-next is idle 0 cpu is being used. make sure we
are also at theoretical minimum in terms of cpu and RAM in general, even when there are tons of
agents running. we need to be 100 times more cpu and ram efficient than our competition".

This doc extends [idle-wakeups.md](idle-wakeups.md) (the wakeup primitives, the app's ledger and
the cmux-tui idle test) from "the app and the terminal daemon do not wake" to every process cmux
starts, and from CPU to RAM. It lists each cost, its theoretical minimum, what was measured, what
landed and what is left.

## 1. Rules

1. **Idle is free.** With nothing changing (no input, no terminal output, no agent token, no file
   the user's own work writes), every cmux process sleeps: 0 periodic wakeups, 0.0% CPU over 60 s,
   window visible or hidden. Work starts only on an event (idle-wakeups.md section 2).
2. **Work is proportional to the change, never to the total.** One transcript line, one terminal
   byte or one setting costs O(that change): not O(chats), O(workspaces) or O(agents).
3. **An agent costs its harness, plus nearly nothing.** The harness process (Claude Code, Codex)
   is the agent; what cmux adds per agent (hosts, MCP servers, sidecars) has a budget of a few MB
   and no CPU between turns.
4. **One copy of shared data per Mac,** not one per process: catalogs, indexes and caches live
   in one daemon and are read over its socket.

## 2. Bench

| What | How | Where |
| --- | --- | --- |
| App + cmux-tui at 1, 10, 100 idle terminal workspaces: CPU %, wakeups/s, RSS and footprint per process kind | `scripts/measure/perf-10x-idle.sh counts=1,10,100 measure=60` (bench_memory.py + cmux-tui bench-scale.py) | `cmux-ci run --class exclusive --measurement --label measure` |
| Idle chats (agents) per workspace | `scripts/cmux-next/bench_memory.py --mix terminal+chat --fake-agent cmux-tui/crates/acpmux/tests/fake_agent.py` | same; not yet in perf-10x-idle.sh (section 7) |
| acpmux daemon idle (2000 chats, the app's watch stream) | `acpmux/tests/daemon_idle.rs` | every cmux-tui test run (CI guard) |
| cmux-tui daemon and terminal hosts idle | `cmux-tui/tests/idle_wakeups.rs` | CI guard (since 2026-09-30) |
| Chat index cost per transcript write | `cmux-chat-index/tests/incremental_merge.rs` | CI guard |
| RAM of one agent's MCP server | `cmux-tui/tests/mcp_footprint.rs` (the `mcpCatalogHost` relay: 2 MB budget; tools/list equal to an in-process server) | CI guard (macOS) |
| A live Mac, read-only | `proc_pid_rusage` (CPU time, package-idle + interrupt wakeups, phys_footprint) per process kind over 15-20 s | the developer Mac, no builds |

## 3. Live Mac snapshot (2026-10-20 09:20 UTC, read-only)

Lawrence's Mac with cmux NIGHTLY and about 110 agent chats running, 14 cores. Not an idle
measurement: agents were streaming. Each row is the sum over the processes of that kind.

| Process kind (cmux NIGHTLY) | Count | CPU | Wakeups/s | Footprint |
| --- | --- | --- | --- | --- |
| cmux-tui headless (terminal daemon) | 2 | 42-70% | 7 | 987 MB |
| acpmux daemon | 2 | 58% | 90 | 1266 MB (one at 2.6 GB RSS) |
| cmux app | 1 | 8-16% | 126-206 | 0.9-1.0 GB |
| optchat-chief host | 1 | 11-15% | 0.1 | 103 MB |
| acpmux `__agent-host` (one per agent) | 115 | 3.1% | 90 | 1057 MB (9.2 MB each) |
| `cmux mcp serve --all-tools` (one per agent) | 110 | 0 | 0 | 2307 MB (21.6 MB each) |
| `acpmux subsession-mcp` (one per agent) | 108 | 0 | 0 | 509 MB (4.7 MB each) |
| `acpmux secret-mcp` (one per agent) | 101 | 0 | 0 | 469 MB (4.6 MB each) |
| Chromium helpers | 7 | 0.1% | 4 | 574 MB |

cmux's own per-agent overhead: **40 MB per agent** (agent host 9.2 + MCP 21.6 + subsession MCP 4.7
+ secret MCP 4.6), 4.4 GB at 110 agents, before the harness process itself.

Leftover daemons of quit dev builds (tagged `cmux DEV` apps no longer running, 2-5 h old): 6 acpmux
daemons and 3 headless cmux-tui servers, **14% CPU and 600 MB** together. Each idle acpmux used
3.0-3.5% CPU with 1.2 wakeups/s: section 4, offender 1.

Other apps on the same Mac at the same time (also not idle-controlled; for scale only):

| App | Processes | CPU | Wakeups/s | Footprint |
| --- | --- | --- | --- | --- |
| cmux classic (RC) | 1 | 0.25% | 13 | 295 MB |
| T3 Code | 6 | 1.6% | 14 | 1054 MB |
| Ghostty | 1 | 0.05% | 1.4 | 935 MB |
| VS Code | 13 | 0.7% | 72 | 3548 MB |
| Google Chrome | 25 | 0.16% | 12 | 1412 MB |

Conductor and Warp were not running. A fair comparison needs the same workload in each app on an
idle fleet Mac (section 7).

## 4. Offenders, by cost

| # | Offender | Cost measured | Theoretical minimum | Status |
| --- | --- | --- | --- | --- |
| 1 | acpmux chat index remerged and cloned **every** chat for each watcher burst (any agent on the Mac writing one transcript line), and acpmux listed and sorted all chats (one `format!` per comparison) to decide whether to save | ~3% CPU per acpmux daemon (25 ms per burst at 14k chats, 8 MB cache), on every acpmux on the Mac, even with no agents of its own | O(changed chats) per burst: a few µs | Fix written, Mac-mini runs pending (section 5) |
| 2 | `cmux mcp serve --all-tools` held the app's whole `action.list` (1051 actions, 737 KB JSON) as a serde_json tree, one copy per agent, plus the freed pages of the parse | 21.6 MB per agent, 2.3 GB at 110 agents | One catalog per Mac in a daemon; per agent a stdio relay of under 1 MB | Fix written (keeps 7 fields, returns freed pages), runs pending (section 5); one-catalog design open (section 6) |
| 3 | Per-agent sidecar processes: agent host, subsession MCP, secret MCP, each a copy of the 70 MB multicall binary | 18.5 MB per agent | 0 extra processes (MCP served by the acpmux daemon on its socket; one relay per harness when it needs stdio) | Open (section 6) |
| 4 | acpmux and headless cmux-tui of a quit app keep running forever (tagged dev builds; also an uninstalled app) | 100-200 MB and up to 3% CPU per leftover pair | 0: exit after an idle grace with no app, no live agent and no client | Open (section 6); the 3% part is gone with fix 1 |
| 5 | cmux-tui terminal daemon 42-70% CPU with ~110 agents; samples show `pread`/`pwrite` (SQLite) under load | 0.4-0.7 core | O(output bytes) | a268 owns (tab.update SQLite projection, history feed journal reads) |
| 6 | acpmux daemon 2.6 GB RSS with ~110 agents | ~24 MB per agent in the daemon | per agent: its transcript tail and state, ~1 MB | Open: not profiled yet |
| 7 | Idle sysctl / `KERN_PROCARGS2` scan per process in the app (CmuxTopSnapshotScopeCache, Workspace hook checks) | one core at idle in cmux RC | 0 at idle | a305 owns |
| 8 | acpmux title-haiku `rg` storm over `$TMPDIR` | ~500% CPU while it runs | 0 | a305 owns (1b5f752a072) |
| 9 | Hidden-tab power; tab hibernation; tab switch | see owners | | a154, a303, a168 own |

## 5. Fixes (red/green on scratch/idle0-chatindex; they land on `feat-cmux-next` after their Mac-mini runs pass)

Each has a failing test first (the red commit), then the fix.

- **Chat index, one chat per write.** `ChatIndex::paths_changed` merges only the session ids of the
  transcripts a burst names (their old and new entries); a store rescan still merges everything.
  `take_structural_change` replaces acpmux's per-burst set of every chat key; `chats()` sorts
  without allocating. Test: `one_transcript_write_merges_one_chat` (5000 chats; one write, one new
  chat, one delete each merge at most 2 entries; red before the fix with 5000).
- **acpmux idle guard.** `acpmux_daemon_idle_has_no_periodic_wakeups`: a real daemon with 2000
  chats and the app's watch stream, three 10 s windows, median at most 5 context switches and 50
  ms CPU per process (the daemon and its router).
- **MCP server RAM.** `ActionTool` keeps title, destructive, focuses, requires,
  unavailable_reason, targets and arguments; `refresh_actions` returns the freed pages of the
  dropped answer. Test: `an_idle_all_tools_server_stays_under_its_ram_budget` (10 MB, 1051-action
  catalog from a fake app).

Before/after numbers are in the report of each Mac-mini run (section 8).

## 6. What is left to reach "100x"

The idle part is close: the app, the terminal daemon and terminal hosts already measure 0-0.6
wakeups/s and 0.01% CPU idle (idle-wakeups.md section 7), and acpmux now has the same guard. The
multiplier left is in **per-agent RAM** and **busy CPU with many agents**:

1. **One MCP endpoint per Mac (offenders 2 and 3).** The acpmux daemon serves the cmux, subsession
   and secret tools on its socket, scoped by the caller's session; a harness that needs a stdio
   server gets a relay binary that only copies bytes (no tokio, no catalog, under 1 MB footprint).
   Per agent: 40 MB to about 1 MB plus the agent host. At 110 agents: 4.4 GB to about 0.1 GB.
2. **Agent host in the daemon.** The 9.2 MB `__agent-host` per agent exists to own the harness's
   PTY and survive daemon restarts; a single host process (or the pty-holder of pty-holder.md)
   holding all agents' handles keeps that property at one process.
3. **Leftover daemons exit (offender 4).** acpmux and a headless cmux-tui exit after a grace period
   (proposed 10 min) with no client, no live agent and no owning app; a248's update path keeps them
   alive across a relaunch because the new app connects within the grace.
4. **Busy CPU per agent token (offenders 5 and 6).** Profile the terminal daemon and acpmux on a
   fleet Mac with 100 streaming fake agents (bench_memory `--mix terminal+chat` with a streaming
   fake agent) and make each token cost O(bytes): no SQLite rewrite of a whole projection, no
   journal read under a lock, no full list rebuild.
5. **Fair competitor numbers.** The same workload (10 idle workspaces, 20 idle agents, 20
   streaming agents) in Conductor, T3 Code, Warp, Ghostty+tmux and VS Code agent views on an idle
   fleet Mac, footprint and wakeups by `proc_pid_rusage`.

## 7. Bench follow-ups

- `perf-10x-idle.sh` measures terminal workspaces only. Add `mix=terminal+chat` with the fake agent
  (idle agents at 0, 20, 100) and a streaming fake agent, then land it (the fleet runs only the
  reviewed script at the tip of `feat-cmux-next`).
- Fleet hosts fill up: cmuxs-Mac-mini had 25 GiB free and refused the 40 GiB build (step
  3b8cde962a5cdb0ff3df578d); run measurements on a host with room (`--target-worker`).

## 8. Runs

Filled in by the measuring agent as the Mac-mini runs finish.
