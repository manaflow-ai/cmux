# Process lifecycle: raw harness vs acpmux (gcp-agent-lane-10.us-west1-c.c.manaflow-437420.internal, 2026-11-25T00:41Z)

Pinned to CPUs [0, 1, 2, 3]; host load 13.7 at start, 21.5 at end (16 cores, other benches running: p50 is the number to read, p95 is noisy). acpmux acpmux 1.0.0 (fe6e415cd 2026-11-25), claude 2.1.331 (Claude Code), codex codex-cli 0.172.0. Stand-in model answers at once (no network). Processes and RSS include the acpmux daemon and agent hosts, amortized per chat; the bench's own client is not counted. RSS double-counts shared pages; PSS does not.

| metric | claude-raw | codex-raw | acpmux+claude | acpmux+codex |
|---|---|---|---|---|
| **N=1** |  |  |  |  |
| spawn to ready ms (p50/p95, 5 runs) | 183.8 / 278.0 | 73.2 / 148.8 | 455.3 / 943.3 | 833.6 / 878.9 |
| spawn to first token ms (p50/p95, 5 runs) | 241.5 / 340.4 | 100.3 / 191.1 | 1001.3 / 1282.4 | 940.5 / 958.8 |
| processes total (per chat) | 1 (1.0) | 1 (1.0) | 4 (4.0) | 9 (9.0) |
| of which acpmux pool spare (procs / RSS MB) | n/a | n/a | 0 / 0.0 | 4 / 218.1 |
| RSS MB total (per chat) | 186.5 (186.5) | 141.7 (141.7) | 353.5 (353.5) | 569.1 (569.1) |
| PSS MB total (per chat) | 116.0 (116.0) | 51.1 (51.1) | 194.4 (194.4) | 231.0 (231.0) |
| idle CPU % of one core over 30 s | 0.5 | 0.43 | 1.03 | 1.03 |
| teardown, normal close | 26.4 ms, 0 left at 10 s | 191.4 ms, 0 left at 10 s | 67.7 ms, 0 left at 10 s | 132.4 ms, 0 left at 10 s; +7 pool-spare procs kept |
| teardown, SIGKILL client | 11.1 ms, 0 left at 10 s | 152.5 ms, 0 left at 10 s | >10 s, 3 left at 10 s (claudex1, cmuxx1, exex1) | >10 s, 4 left at 10 s (cmuxx1, codexx1, exex1, nodex1); +4 pool-spare procs kept |
| teardown, SIGKILL acpmux daemon | n/a (no daemon) | n/a (no daemon) | >10 s, 2 left at 10 s (claudex1, exex1) | >10 s, 4 left at 10 s (cmuxx1, codexx1, exex1, nodex1) |
| **N=5** |  |  |  |  |
| spawn to ready ms (p50/p95 over 5 chats) | 282.0 / 448.6 | 142.6 / 175.3 | 1059.8 / 1556.7 | 1299.9 / 1557.3 |
| spawn to first token ms (p50/p95 over 5 chats) | 452.2 / 546.2 | 199.1 / 224.2 | 1411.3 / 2357.8 | 1465.3 / 1756.5 |
| processes total (per chat) | 5 (1.0) | 5 (1.0) | 16 (3.2) | 25 (5.0) |
| of which acpmux pool spare (procs / RSS MB) | n/a | n/a | 0 / 0.0 | 4 / 218.6 |
| RSS MB total (per chat) | 942.7 (188.5) | 706.6 (141.3) | 1369.0 (273.8) | 1573.4 (314.7) |
| PSS MB total (per chat) | 580.1 (116.0) | 185.9 (37.2) | 747.0 (149.4) | 490.3 (98.1) |
| idle CPU % of one core over 30 s | 1.93 | 2.93 | 2.77 | 7.73 |
| teardown, normal close | 39.0 ms, 0 left at 10 s | 43.8 ms, 0 left at 10 s | 83.4 ms, 0 left at 10 s | 106.2 ms, 0 left at 10 s; +4 pool-spare procs kept |
| teardown, SIGKILL client | 42.2 ms, 0 left at 10 s | 87.2 ms, 0 left at 10 s | >10 s, 15 left at 10 s (claudex5, cmuxx5, exex5) | >10 s, 20 left at 10 s (cmuxx5, codexx5, exex5, nodex5); +4 pool-spare procs kept |
| teardown, SIGKILL acpmux daemon | n/a (no daemon) | n/a (no daemon) | >10 s, 10 left at 10 s (claudex5, exex5) | >10 s, 20 left at 10 s (cmuxx5, codexx5, exex5, nodex5) |
| **N=20** |  |  |  |  |
| spawn to ready ms (p50/p95 over 20 chats) | 1364.7 / 1596.4 | 612.6 / 758.0 | 2631.5 / 2773.8 | 3807.5 / 5308.7 |
| spawn to first token ms (p50/p95 over 20 chats) | 2034.9 / 2330.5 | 802.5 / 1077.7 | 3756.0 / 3963.4 | 4749.6 / 6402.4 |
| processes total (per chat) | 20 (1.0) | 23 (1.15) | 61 (3.05) | 93 (4.65) |
| of which acpmux pool spare (procs / RSS MB) | n/a | n/a | 0 / 0.0 | 4 / 217.8 |
| RSS MB total (per chat) | 3554.5 (177.7) | 2847.3 (142.4) | 4992.7 (249.6) | 5637.0 (281.9) |
| PSS MB total (per chat) | 2040.6 (102.0) | 613.6 (30.7) | 2526.3 (126.3) | 1341.5 (67.1) |
| idle CPU % of one core over 30 s | 7.4 | 15.23 | 8.03 | 13.96 |
| teardown, normal close | 73.9 ms, 0 left at 10 s | 80.1 ms, 0 left at 10 s | 222.4 ms, 0 left at 10 s | 362.1 ms, 0 left at 10 s; +4 pool-spare procs kept |
| teardown, SIGKILL client | 191.4 ms, 0 left at 10 s | 97.8 ms, 0 left at 10 s | >10 s, 60 left at 10 s (claudex20, cmuxx20, exex20) | >10 s, 80 left at 10 s (cmuxx20, codexx20, exex20, nodex20); +8 pool-spare procs kept |
| teardown, SIGKILL acpmux daemon | n/a (no daemon) | n/a (no daemon) | >10 s, 40 left at 10 s (claudex20, exex20) | >10 s, 92 left at 10 s (cmuxx20, codexx20, exex26, nodex26) |
| **after idle hibernation (N=5, ACPMUX_IDLE_CHILD_SECS=20)** | n/a (no hibernation: the harness lives as long as its client) | n/a (no hibernation: the harness lives as long as its client) | 20 procs / 2138.2 MB -> 6 procs / 160.5 MB after 23240.41 ms (left: acpmuxx1, cmuxx5) | 29 procs / 1608.0 MB -> 5 procs / 320.0 MB after 21216.13 ms (left: acpmuxx1, cmuxx1, codexx1, exex1, nodex1) |
| acpmux daemon cold start ms (p50, not in spawn) | n/a | n/a | 20.6 | 20.5 |

Reading it: "SIGKILL client" on an acpmux side is the daemon keeping the chat by design (a named session outlives its client); its harness goes at idle hibernation (the last row), not in 10 s. "SIGKILL acpmux daemon" leaves agent hosts on purpose (agent_host ORPHAN_IDLE, 10 min, so a restarted daemon adopts them). "pool spare" is acpmux's warm next chat (hub/pool/spare.rs), counted in the totals.

## acpmux gaps (worse than raw, or than needed)

1. Spawn is 2-5x raw. N=1 ready p50: claude 184 -> 455 ms, codex 73 -> 834 ms; first token: 242 -> 1001 ms, 100 -> 941 ms. At N=20, acpmux+codex ready p50 is 3.8 s (raw 0.6 s). The cost is acpmux's per-session start: an `__agent-host` per chat plus the harness, and for codex a `node` wrapper in front of the codex binary (raw spawns the musl binary directly). Source: cmux-tui/crates/acpmux/src/agent_host/mod.rs (host per session), and the codex launch argv in cmux-tui/crates/acpmux/src/agent_tools.rs (`codex -m ... -c ...` through /usr/local/bin/codex, the node shim).
2. Footprint per chat is 3-5 processes vs 1 raw. N=20 PSS per chat: claude 102 -> 126 MB, codex 31 -> 67 MB (RSS 142 -> 282 MB). Each chat holds an `__agent-host` (about 12 MB RSS) and its own `cmux mcp serve`. Sources: agent_host/mod.rs; mcp_gateway.rs (claude: the daemon spawns a `cmux mcp serve` per chat); for codex the `cmux mcp serve` runs as a stdio child of codex.
3. The codex pool spare is always on. Even at N=1, acpmux+codex keeps a second, hidden codex chain (4 procs, about 218 MB RSS) for the next chat. It stays after hibernation and after normal close, and lives `pool.spareIdleMinutes` (default 60). After hibernation, acpmux+codex still holds 320 MB (raw: 0, the client is gone). Source: cmux-tui/crates/acpmux/src/hub/pool/spare.rs, hub/pool/policy.rs. No claude spare showed up in these runs.
4. Claude's `cmux mcp serve` outlives hibernation. After all 5 claude chats hibernated, the 5 per-chat `cmux mcp serve` processes stayed (6 procs / 160 MB with the daemon). The gateway stops them only after `IDLE_STOP` = 10 min, five times the 2 min harness hibernation. Source: cmux-tui/crates/acpmux/src/mcp_gateway.rs (`IDLE_STOP`).
5. Idle CPU is higher with codex: N=5 7.7% of one core vs 2.9% raw. At N=20 the two sides are close (14.0 vs 15.2%: noise at host load 14-21). Source: unclear. Candidates are the extra node + host per chat (agent_host/mod.rs) and the spare.
6. Teardown after the parent dies is slow by design, but unbounded inside 10 s. SIGKILL of the daemon leaves every agent host, harness and (codex) MCP server running: 40 procs at N=20 claude, 92 at N=20 codex. They end only after `ORPHAN_IDLE` = 10 min with no daemon. For the person, this is 10 min of 2-5 GB RSS after a daemon crash that never restarts. Source: cmux-tui/crates/acpmux/src/agent_host/mod.rs (`ORPHAN_IDLE`), hub/idle.rs (orphan wait = max(idle, ORPHAN_IDLE)). SIGKILL of the client is intended (sessions persist), so it isn't counted as a gap; the harness ends at hibernation.
7. Normal close is 2-5x slower than raw at N=20 (claude 74 -> 222 ms, codex 80 -> 362 ms). Small in absolute terms. Source: session/close path through the host (agent_host/mod.rs).
8. Side processes: in acpmux+codex runs, acpmux started `codex exec` side calls. On this VM they resolve through the leo-workspace codex-exec-guard python wrapper (python3 x3 at N=20, counted in the totals). Codex itself (raw too) runs `git ls-remote https://github.com/openai/plugins.git` at start, which the stand-in model can't stop.
