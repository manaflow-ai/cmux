# acpmux vs Claude Code vs Codex: theoretical optimum

host: Linux 7.0.0-1017-gcp, CPUs 12-15, load at start (13.63916015625, 8.1416015625, 7.81982421875), versions {'claude': '2.1.331 (Claude Code)', 'codex': 'codex-cli 0.172.0', 'acpmux': 'acpmux 1.0.0 (fe6e415cd 2026-11-25)'}; p50 over 30 runs; noise: shared VM, min is the cleaner floor.

## Floors

| metric | floor | formula / source | claude | codex | acpmux |
|---|---|---|---|---|---|
| spawn ms (`--version`) | 0.18 | posix_spawn+wait of a static no-op | 4.893 | 43.515 | 3.927 |
| runtime start ms | node 21.188 / bun 2.49 / py 11.486 | `-e 0` | - | - | - |
| idle RSS MB per chat | 1.1 (static Rust) / 41.8 (node) | idle process | 157.8 | 113.7 | 298.8 (daemon+1 chat; daemon alone 77.6) |
| processes per chat | 1 | black-box harness = 1 proc | 1 | 1 | 3.0 marginal |
| IPC op ms | unix 0.167 / pipe 0.048 | echo child, JSON line | - | - | status 5.118 |
| idle CPU % | 0 | no timers | 0.7 | 1.6 | 0.1 daemon0 / 0.7 with 1 chat |

## Architectural floor (K=3 MCP servers)

```
Per N chats, K MCP servers. u_h = measured idle RSS of the harness tree, u_m = idle RSS of one MCP server,
u_d = idle daemon RSS, u_s = acpmux's measured per-session extra RSS over a raw claude (host + helpers).
  black-box, no multiplexer, MCP per chat:           procs = N*(1+K)   ; RSS = N*(u_h + K*u_m_node)
  floor: shared MCP (K not K*N) + 1 daemon:          procs = N + K + 1 ; RSS = N*u_h + K*u_m_rust + u_d
  acpmux today (measured marginal procs/chat p, extra u_s): procs = 1 + N*p + K ; RSS = u_d + N*(u_h+u_s) + K*u_m_node
u_m floor = idle static Rust; typical = idle node. A harness is a black box: 1 process per chat is the minimum.
```

| N | harness | black-box procs | black-box RSS MB | floor procs | floor RSS MB | acpmux procs | acpmux RSS MB |
|---|---|---|---|---|---|---|---|
| 1 | claude | 4 | 283.2 | 5 | 238.7 | 7.0 | 421.4 |
| 1 | codex | 4 | 239.1 | 5 | 194.6 | 7.0 | None |
| 5 | claude | 20 | 1416.0 | 9 | 869.9 | 19.0 | 1295.0 |
| 5 | codex | 20 | 1195.5 | 9 | 649.4 | 19.0 | None |
| 20 | claude | 80 | 5664.0 | 24 | 3236.9 | 64.0 | 4571.0 |
| 20 | codex | 80 | 4782.0 | 24 | 2354.9 | 64.0 | None |

## Headroom for acpmux (source files)

- Marginal processes per chat above the 1 a black-box harness needs: agent host + harness + tools helper (3 measured). Fold the host into the daemon or the harness wrapper: cmux-tui/crates/acpmux/src/agent_host/host.rs, agent_tools.rs, tools_mcp.rs.
- Marginal RSS per chat above a raw claude (u_s in the arch table): host + tools-mcp tokio runtimes; single-thread runtime, lazy start: agent_tools.rs, tools_mcp.rs.
- Daemon idle RSS and ~40 threads at 0 sessions (floor: a few MB, ~4 threads): server/mod.rs, hub/ (runtime worker count, eager caches).
- `_acpmux/status` p50 vs the pipe/unix floor: it locks child mutexes and may wait on a host-pressure sample: hub/views.rs (audit finding 16).
- Idle wakeups scale with chats (watch polling 400 ms, wait 1 s, reader try_wait 500 ms): hub/watch.rs, server/wait.rs, agent.rs (audit finding 5).
- session/new spawns before replying (~38 ms in the audit): hub/ session start path, finding 6. MCP servers per chat instead of shared K: agent_tools.rs (finding 10).

## Raw numbers

```json
{
 "spawn": {
  "/bin/true": {
   "p50_ms": 0.328,
   "min_ms": 0.27,
   "p90_ms": 0.405
  },
  "static C noop": {
   "p50_ms": 0.18,
   "min_ms": 0.122,
   "p90_ms": 0.219
  },
  "static Rust noop": {
   "p50_ms": 0.233,
   "min_ms": 0.188,
   "p90_ms": 0.301
  },
  "node -e 0": {
   "p50_ms": 21.188,
   "min_ms": 15.991,
   "p90_ms": 24.066
  },
  "bun -e 0": {
   "p50_ms": 2.49,
   "min_ms": 1.83,
   "p90_ms": 3.613
  },
  "python3 -c pass": {
   "p50_ms": 11.486,
   "min_ms": 10.058,
   "p90_ms": 15.525
  },
  "claude --version": {
   "p50_ms": 4.893,
   "min_ms": 4.436,
   "p90_ms": 5.286
  },
  "codex --version": {
   "p50_ms": 43.515,
   "min_ms": 40.113,
   "p90_ms": 48.509
  },
  "codex --version (real binary, no guard shim)": {
   "p50_ms": 24.398,
   "min_ms": 21.051,
   "p90_ms": 29.696
  },
  "acpmux --version": {
   "p50_ms": 3.927,
   "min_ms": 3.708,
   "p90_ms": 4.175
  }
 },
 "rss": {
  "idle node": {
   "procs": 1,
   "rss_mb": 41.8,
   "threads": 7,
   "idle_cpu_pct": 0.0
  },
  "idle static Rust": {
   "procs": 1,
   "rss_mb": 1.1,
   "threads": 1,
   "idle_cpu_pct": 0.0
  },
  "claude idle (stream-json, initialized)": {
   "procs": 1,
   "rss_mb": 157.8,
   "threads": 12,
   "idle_cpu_pct": 0.7
  },
  "codex idle (app-server, thread started)": {
   "procs": 1,
   "rss_mb": 113.7,
   "threads": 23,
   "idle_cpu_pct": 1.6
  },
  "acpmux daemon, 0 sessions": {
   "procs": 1,
   "rss_mb": 77.6,
   "threads": 42,
   "idle_cpu_pct": 0.1
  },
  "acpmux daemon + 1 claude session(s) idle": {
   "procs": 4,
   "rss_mb": 298.8,
   "threads": 49,
   "idle_cpu_pct": 0.7
  },
  "acpmux daemon + 5 claude session(s) idle": {
   "procs": 16,
   "rss_mb": 1172.3,
   "threads": 115,
   "idle_cpu_pct": 3.6
  },
  "_acpmux/status ms": {
   "p50": 5.118,
   "p90": 7.904
  }
 },
 "ipc": {
  "unix JSON-line round trip": {
   "p50_ms": 0.167,
   "p90_ms": 0.2054
  },
  "pipe JSON-line round trip": {
   "p50_ms": 0.048,
   "p90_ms": 0.0615
  }
 }
}
```
