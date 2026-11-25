# MCP servers: raw harness vs acpmux

K=3 stdio echo servers (echo_mcp.py) per chat on every side; stand-in model; taskset [8, 9, 10, 11]; load before: [16.1015625, 14.73583984375, 11.22412109375].

| metric | claude-raw | codex-raw | acpmux+claude | acpmux+codex |
|---|---|---|---|---|
| echo MCP procs, N=1/5/20 (N=1/5/20) | 3 / 15 / 60 | 3 / 15 / 60 | 3 / 15 / 60 | 6 / 18 / 63 |
| echo procs per chat (K=3) (N=1/5/20) | 3.0 / 3.0 / 3.0 | 3.0 / 3.0 / 3.0 | 3.0 / 3.0 / 3.0 | 6.0 / 3.6 / 3.15 |
| echo RSS MB (N=1/5/20) | 33.5 / 166.9 / 667.2 | 33.3 / 166.6 / 666.9 | 33.3 / 166.9 / 667.5 | 66.7 / 200.1 / 700.1 |
| echo idle CPU % (N=1/5/20) | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 |
| echo procs outside chats (acpmux model probes) (N=1/5/20) | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| session/new mcpServers started by acpmux (of 3/chat) (N=1/5/20) | - / - / - | - / - / - | 0 / 0 / 0 | 0 / 0 / 0 |
| acpmux-added servers offered (N=1/5/20) | 0 / 0 / 0 | 0 / 0 / 0 | 1 / 1 / 1 | 1 / 1 / 1 |
| acpmux-added MCP procs (N=1/5/20) | 0 / 0 / 0 | 0 / 0 / 0 | 1 / 5 / 20 | 2 / 6 / 21 |
| acpmux-added MCP RSS MB (N=1/5/20) | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 11.9 / 59.6 / 236.1 | 23.7 / 71.0 / 248.4 |
| harness procs (non-MCP) (N=1/5/20) | 1 / 5 / 20 | 1 / 5 / 21 | 2 / 10 / 40 | 6 / 18 / 76 |
| harness RSS MB (N=1/5/20) | 234.8 / 1054.6 / 3926.3 | 156.2 / 747.7 / 3033.4 | 280.7 / 1286.6 / 4867.8 | 445.9 / 1378.9 / 4908.7 |
| daemon RSS MB (N=1/5/20) | - / - / - | - / - / - | 97.2 / 102.7 / 114.1 | 98.6 / 103.5 / 145.2 |
| idle CPU % harness+daemon (N=1/5/20) | 1.1 / 5.2 / 21.3 | 0.3 / 2.0 / 12.5 | 1.3 / 5.0 / 18.2 | 1.4 / 5.1 / 19.5 |
| MCP startup ms p50 (start -> 3 servers listed) (N=1/5/20) | 219.9 / 438.6 / 2201.7 | 151.7 / 169.6 / 742.0 | 729.8 / 2140.3 / 5220.3 | 773.7 / 1678.8 / 5033.8 |
| first MCP call ms p50 (N=1/5/20) | 69.3 / 78.9 / 334.9 | 11.6 / 24.4 / 65.7 | 79.3 / 111.0 / 674.9 | 18.7 / 48.1 / 206.1 |
| warm MCP call ms p50 (chat 0) (N=1/5/20) | 55.5 / 63.4 / 59.9 | 10.9 / 10.7 / 10.9 | 64.8 / 57.5 / 51.0 | 19.2 / 46.0 / 32.2 |
| chats failed (N=1/5/20) | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| end: echo left / reap ms | 0 left / 50 ms (of 3) | 0 left / 50 ms (of 3) | 0 left / 0 ms (of 3) | 0 left / 0 ms (of 3) |
| end, linger servers | 0 left / 50 ms (of 3) | 0 left / 50 ms (of 3) | 0 left / 0 ms (of 3) | 0 left / 0 ms (of 3) |
| SIGKILL harness: echo left / reap ms | 0 left / 100 ms (of 3) | 0 left / 50 ms (of 3) | 0 left / 50 ms (of 3) | 0 left / 50 ms (of 3) |
| SIGKILL, linger servers | 3 left / never reaped (15 s) (of 3) | 3 left / never reaped (15 s) (of 3) | 0 left / 50 ms (of 3) | 3 left / never reaped (15 s) (of 3) |
| idle hibernation: echo left / gone after ms | n/a (raw harness has no idle hibernation) | n/a (raw harness has no idle hibernation) | 0 left / 21368 ms (of 3) | 0 left / 22165 ms (of 3) |
| idle, linger servers | n/a (raw harness has no idle hibernation) | n/a (raw harness has no idle hibernation) | 0 left / 21118 ms (of 3) | 0 left / 22165 ms (of 3) |
| MCP call after hibernation wake | n/a | n/a | answered=True call 36.4 ms, turn 465 ms, restarted=True | answered=True call 18.4 ms, turn 752 ms, restarted=True |
| crash echo0 -> restarted? | True | False | True | False |
| crash echo0 -> next echo0 call | 45.0 ms: `hi Cecho0x8338a8 [echo0 pid 2821204]` | 10.5 ms: `tool call error: tool call failed for `echo0/echo`  Caused by:     Transport closed` | 55.9 ms: `hi Cecho0x833f76 [echo0 pid 2875828]` | 15.4 ms: `tool call error: tool call failed for `echo0/echo`  Caused by:     Transport closed` |
| crash echo0 -> echo1 call | 60.5 ms: `hi Cecho1x9717a9 [echo1 pid 2808861]` | 11.5 ms: `hi Cecho1x16af0f [echo1 pid 2934502]` | 40.7 ms: `hi Cecho1xb2a324 [echo1 pid 2870911]` | 15.4 ms: `hi Cecho1x6aa911 [echo1 pid 2893472]` |
