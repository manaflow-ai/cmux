# acpmux vs Claude Code vs Codex: results (2026-11-25, gcp-agent-lane-10, Linux x86-64, 16 cores)

acpmux 1.0.0 (fe6e415cd), claude 2.1.331, codex 0.172.0. Stand-in model (answers at once, no network), so every
number is client-side. Each bench ran pinned to its own 4 cores while the others ran; host load was 6-21, so read
p50 and treat <15 ms or <15% differences as noise. Full tables: `results/*.md`. Rerun: see README.md.

## Headline table

| dimension | metric | claude-raw | codex-raw | acpmux+claude | acpmux+codex | floor |
|---|---|---|---|---|---|---|
| lifecycle | spawn to ready ms, N=1 (p50) | 184 | 73 | 455 | 834 | 0.2 (static exec) |
| lifecycle | spawn to first token ms, N=1 | 242 | 100 | 1001 | 941 | |
| lifecycle | spawn to ready ms, N=20 | 1365 | 613 | 2632 | 3808 | |
| lifecycle | processes per chat, N=20 | 1.0 | 1.15 | 3.05 | 4.65 | 1 |
| lifecycle | RSS / PSS MB per chat, N=20 | 178 / 102 | 142 / 31 | 250 / 126 | 282 / 67 | harness only |
| lifecycle | idle CPU % one core, N=5 | 1.9 | 2.9 | 2.8 | 7.7 | 0 |
| lifecycle | normal close ms, N=20 | 74 | 80 | 222 | 362 | |
| lifecycle | procs left 10 s after client SIGKILL, N=20 | 0 | 0 | 60 (by design) | 80 | 0 |
| lifecycle | after idle hibernation, N=5 | n/a | n/a | 6 procs / 161 MB | 5 procs / 320 MB | 1 daemon |
| tools | shell call ms, warm (p50 / p95) | 63.5 / 78 | 77.5 / 130 | 62.8 / 75 | 22.6 / 36 (no sandbox) | |
| tools | processes per `/bin/true` call | 1.8 | 7.0 (bwrap sandbox) | 1.95 | 6.95 (login shell) | 1 |
| tools | file edit ms (p50) | 70 | 69 | 67 | 14.5 | |
| tools | 10 parallel `sleep 0.3` ms | 395 | 644 | 374 | 396 | 300 |
| tools | tree RSS growth, call 20 to 100, MB | 29 | 10 | 54 | 8 | 0 |
| MCP | K=3 echo servers, procs at N=20 | 60 | 60 | 60 | 63 | 3 (shared) |
| MCP | acpmux-added MCP procs / MB, N=20 | 0 | 0 | 20 / 236 | 21 / 248 | 1 |
| MCP | start until 3 tools listed ms, N=1 / N=20 | 220 / 2202 | 152 / 742 | 730 / 5220 | 774 / 5034 | |
| MCP | warm MCP call ms | 55 | 11 | 51-65 | 19-46 | |
| MCP | client `session/new` mcpServers started | n/a | n/a | 0 of 3 | 0 of 3 | 3 |
| MCP | crashed server, next call | recovers | "Transport closed" | recovers | "Transport closed" | recovers |
| MCP | EOF-ignoring servers left after harness SIGKILL | 3 | 3 | 0 | 3 | 0 |
| optimum | `--version` spawn ms | 4.9 | 43.5 (VM guard shim) | 3.9 (acpmux) | | 0.18 |
| optimum | idle daemon RSS MB, 0 chats | n/a | n/a | 78-140 | | a few |
| optimum | IPC op ms (`_acpmux/status`) | | | 5.1 (audit: 0.09 on macOS) | | 0.05 pipe / 0.17 socket |

Scaling (claude, K=3 MCP): black-box harnesses N*(1+K) procs; floor N+K+1; acpmux today 1+3N+K.
At N=20: 80 / 24 / 64 processes, 5.7 / 3.2 / 4.6 GB. acpmux beats raw at scale and sits 1.3 GB above the floor.

## acpmux gaps (worst first), owners

Owner: acpmux code is Leo-lane territory (git: nearly all recent commits in these files); each gap below is a
fix lane offered from this session; the area holder on cmux#55177 picks it up or this lane does.

| # | gap | number | source | owner |
|---|---|---|---|---|
| 1 | Codex runs with no sandbox through acpmux (approve-all starts at full access) | 0 bwrap vs 3/call raw | `hub/start_mode.rs`, `hub/policy_mode.rs` | acpmux policy lane: decide if intended, document or fix |
| 2 | Client `session/new` `mcpServers` dropped, never forwarded | 0 of 3 started | `protocol/params.rs:297`, `hub/spawn.rs:158-181`, `agent_tools.rs:750` | acpmux MCP lane (offered) |
| 3 | Spawn 2-5x raw (host + harness per chat; Codex via node wrapper) | 184->455, 73->834 ms | `agent_host/mod.rs`, `agent_tools.rs` | acpmux spawn lane (offered) |
| 4 | Codex pool spare always on, doubles MCP servers, 218 MB, survives hibernation | +4 procs, +218 MB at N=1 | `hub/pool/spare.rs`, `hub/pool/policy.rs` | acpmux pool lane (offered) |
| 5 | One `cmux mcp serve` per chat, not shared via the gateway; outlives hibernation 10 min | 20 procs / 236 MB at N=20 | `agent_tools.rs` `via_gateway`, `mcp_gateway.rs` `IDLE_STOP` | acpmux MCP lane (offered) |
| 6 | Codex shell is a login shell: 7 procs per call | 6.95 vs 1.95 | Codex argv under `agent/`, `tests/codex_bridge_config.rs` | acpmux Codex bridge lane |
| 7 | Daemon dies: hosts, harnesses, MCPs live 10 min orphaned | 40-92 procs, 2-5 GB at N=20 | `agent_host/mod.rs` `ORPHAN_IDLE`, `hub/idle.rs` | acpmux spawn lane |
| 8 | Idle daemon 78-140 MB, ~40 threads with 0 chats; idle CPU grows with chats | 7.7% vs 2.9% at N=5 Codex | `server/mod.rs`, `hub/watch.rs`, `server/wait.rs` | acpmux perf lane |
| 9 | Codex crashed MCP not restarted; EOF-ignoring MCPs leak after Codex SIGKILL | "Transport closed", 3 left | `hub/spawn.rs` | acpmux Codex bridge lane |
| 10 | Claude repeat `Read` dedupe reaches the model as a tool error | 10 of 20 `is_error` | `claude_stdio/dedupe.rs` | acpmux claude_stdio lane |
| 11 | Model probes start every MCP server at daemon start | +9 transient procs | `hub/model_probe.rs:313-331` | acpmux MCP lane |

Bench note: Codex lists no tools for an unknown model id (`gpt-6.1-sol`, the default in
`scripts/cmux-next/acpmux-overhead-bench.py`); mcp.py defaults to `gpt-5.1` (`MCP_BENCH_CODEX_MODEL`). This likely
explains mcp-fanout's old "Codex lists no tools" note.

Not measured: macOS (Leo's platform; `scripts/measure/acpmux-overhead.sh` on a quiet Mac worker is the follow-up), real
model latency (stand-in only).
