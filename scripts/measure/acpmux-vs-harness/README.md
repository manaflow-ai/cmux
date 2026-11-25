# acpmux vs Claude Code vs Codex

Leo, 2026-11-24 23:11Z: "we need to have benches for those, as well as cross-comparing to claude code and codex".

Four benches, one per dimension, each comparing four sides against the same stand-in model
(scripts/cmux-next/acpmux-overhead-bench.py: answers at once, no credential, no network), so every
difference is the client side:

| side | how it runs |
|---|---|
| claude-raw | `claude -p --input-format stream-json` (the wire acpmux drives) |
| codex-raw | `codex app-server` JSON-RPC |
| acpmux+claude | isolated acpmux daemon (own ACPMUX_HOME), session/new + session/prompt |
| acpmux+codex | same, harness codex |

- `lifecycle.py`: spawn to ready / first token, processes and RSS per chat at N=1,5,20, idle CPU, teardown and orphans, hibernation
- `tools.py`: built-in tool calls (shell, read, edit): latency, processes per call, leaks
- `mcp.py`: stdio MCP servers: per-chat copies vs shared, startup, call latency, reaping, crash recovery
- `optimum.py`: the floor per metric on the same machine, and the formula for N chats with K MCP servers

Results: RESULTS.md (pending).
