# Unii baseline vs the Chief harness

Names (Chief default, 2026-10-20; the user may change them):

- **Unii baseline**: UniiChat (github.com/VictorTaelin/UniiChat, read at 0500bf6), as it calls a model.
- **The Chief harness**: our default Chief turn path. optchat-chief builds the input; acpmux runs a fresh Claude Code (`claude-stdio`) session for each turn; the route is `claude` or `claude-sr2`.

The bench is [BENCH-unii.md](BENCH-unii.md). The script is `Native/OptChat/optchat-chief/measure/unii_bench.py`.

## How the Unii baseline calls a model

- **One process, one request per step.** A Bun server sends the request straight to the Messages API (`Anthropic.ts`). It has no CLI process, no ACP and no MCP. A turn costs one HTTP request plus the model.
- **Prompt.** `prompt.txt` (4.4 KB) is the system prompt, with one cache mark. It offers 9 small tools: zoom, date, spawn, tell, computer, shell, read, write, edit.
- **View.** The `<chat>` view comes in 4-line blocks. Only the last whole block is marked (`Memory.view`). Then come the "Devices" and "Agents at work" lines, which are unmarked, so a change there never breaks the cached prefix. The new message comes last and is marked. A top-level `cache_control` is set too.
- **The view changes only at its end.** It merges in batches past a byte budget, so between batches every turn reads the same prefix.
- **Single flight (`AskAI.wait`).** If a request's prefix is still being written by a leader request, it waits until the leader's response begins and then reads the entry. Parallel calls never write the same prefix twice.
- **Settle.** A turn waits for the summaries of earlier messages (`Memory.settle`), so the view it renders is final.
- **Compactor.** Haiku 5.5, effort high, with the same system prompt as a turn and no tools. It runs as one direct API call per node.
- **Cache TTL.** It uses the vendor's default 5-minute TTL.

## How the Chief harness calls a model

- optchat-chief builds the system text and the input layout (`chief/prompt.rs input_layout`):
  - a frozen view;
  - a delta;
  - three cache marks: the view's end, the previous request's end, and this request's end;
  - a 1-hour TTL.
- acpmux starts a new Claude Code session for every turn, from a prewarmed pool.
  - Claude Code's own cache marks are off (`DISABLE_PROMPT_CACHING=1`).
  - Only `TURN_TOOLS` is offered, plus the optchat MCP. The cmux tools wait behind ToolSearch.
- The compactor runs one Claude Code session per node. It uses Haiku 5.5 at medium effort.

## What the Unii baseline does better, and what we do now

| # | Topic | Unii baseline | Chief harness before | Now |
|---|---|---|---|---|
| 1 | Same upstream cache across turns | One process: same key, same account (direct API) | A new Claude session per turn. sr2 picks an account per session, so 52% of claude-sr2 turns (23% on claude) wrote 38k-83k tokens again | **Fixed.** acpmux sends `X-Subrouter-Session` for turn and compactor presets (`subrouter_session.rs`). In the bench, warm hit went from 39.4% to 98.5% |
| 2 | Per-turn process start | 0 (a server that is already running) | Claude Code process plus session per turn. Measured `start_ms` p50 1.15 s, p90 3.1 s (Oct 18-19) | Open. A persistent turn session or the native engine would fix it (below) |
| 3 | Fixed prompt overhead | 4.4 KB system prompt and 9 tools: about 39.6k tokens for a 100 KB view | Claude Code system prompt plus tools plus our 11.6 KB system prompt: about 45.0k for the same view (+14%) | Open. Use `engine=native` (direct API) for the Chief |
| 4 | Uncached tail per turn | 4 tokens | 462 tokens after our last mark (Claude Code puts its own text after the user content) | Open |
| 5 | Single flight on a shared prefix | Yes | No. Parallel compactor slots can write the same prefix twice | Open (small) |
| 6 | Settle before render | Yes | Cloud Chief yes; the Rust Chief keeps the frozen view (optchat.md 5a) | Same as before |
| 7 | Resident memory | One Bun server | Each live Claude Code process is 140-310 MB. The default Chief today: 8 processes, 926 MB, plus a 197 MB host | Open. Pool size, or the native engine |

## Metrics

Each metric is taken per turn, on the same model, route, view (100 KB synthetic) and 6-turn script.

- **Time to first token (s)**: from request or process start to the first text or thinking delta.
- **Turn time (s)**: to the end of the stream or process.
- **Process start (s)**: the Chief only, to Claude Code's first `system` event.
- **Tokens**: input, cache read, cache write, output.
- **Cache hit**: read / (input + read + write). Warm hit counts turns 2 to N.
- **Cost (USD)**: list prices. A cache write costs 1.25x with the 5-minute TTL (Unii) and 2x with the 1-hour TTL (Chief).
- **Memory (MB)**: the RSS of the harness processes for one Chief.
- **Home streaming render latency**: not measured here. a197 owns it.

## Where 10x is possible and where it is not

- **Possible: cache misses against our own baseline.** The cold-turn rate was 43% of Chief turns. After the fix it was 0 of 5 warm turns in the bench. Each cold turn on Opus cost about $0.45 more, which is about 16x the cost of a warm turn.
- **Not possible against the Unii baseline:**
  - **Cache hit.** Both harnesses are at about 98.5-99%, and the ceiling is 100%.
  - **Tokens.** The tokens are mostly the view, which both send.
  - **Time to first token and turn time.** These are bound by the model and the route. Unii's p50 time to first token is 4.3 s on Opus, and almost all of it is the model.
- **The floor.** The best the Chief harness can do is to match Unii: one direct request, no process start, and about 40k prompt tokens for a 100 KB view. 10x lower than that would need a 10x smaller view, which loses memory.

## Next steps (not landed here)

1. Run the Chief on `engine=native` by default (the direct Messages API loop, `chief/native`). This removes rows 2, 3, 4 and 7. It needs a credential route through sr2 that does not depend on a Claude Code login.
2. Alternatively, keep one Claude Code session per Chief and reuse it for turns. This needs a stable prefix inside Claude Code's own transcript.
3. Add single flight for compactor slots that share a prefix.
