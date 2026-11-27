# BENCH: Unii baseline vs the Chief harness

Run on 2026-10-20 by a226. Script: `Native/OptChat/optchat-chief/measure/unii_bench.py`, launched as four parallel runs with four parallel runs (unii/chief x sticky/plain).

Setup:
- **Model and effort:** `claude-opus-5-5`, effort medium.
- **Route:** the team sr2 gateway (`sr2-gateway.tail137216.ts.net:4016`).
- **Input:** a 100 KB synthetic view and 6 one-line user turns.
- **Unii baseline:** UniiChat's request shape (its `prompt.txt` and 9 tools, 4-line view blocks, its marks, adaptive thinking), sent straight to the API.
- **Chief harness:** a fresh `claude -p` per turn, with the Chief's live preset system prompt (11.6 KB), the turn isolation args, and our three 1-hour marks.
- **sticky / plain:** "sticky" sends `X-Subrouter-Session`, which is what acpmux now does for Chief turns. "plain" sends no session header, which is what the Chief did before this fix.
- **Where it ran:** on this Mac. It makes network calls only and builds nothing; the four runs ran in parallel.

| Run | Turns | Warm hit | Cold warm turns | TTFT p50 s | Turn p50 s | Start p50 s | Prompt tok turn 1 | Uncached in/turn | Cost 6 turns $ |
|---|---|---|---|---|---|---|---|---|---|
| unii-sticky | 6 | 99.1% | 0/5 | 4.32 | 4.51 | 0.00 | 39,592 | 4 | 0.366 |
| chief-sticky | 6 | 98.5% | 0/5 | 5.33 | 6.14 | 3.19 | 45,049 | 462 | 0.594 |
| unii-plain | 6 | 59.6% | 2/5 | 4.69 | 4.70 | 0.00 | 39,592 | 4 | 0.824 |
| chief-plain | 6 | 39.4% | 3/5 | 8.16 | 11.07 | 5.74 | 45,049 | 462 | 1.868 |

How to read the table:
- **Warm hit** = cache read / (input + read + write), over turns 2 to 6.
- **Cold warm turns** = turns 2 to 6 that wrote more than 20k tokens.
- **Start** = time until Claude Code's first `system` event. It is 0 for Unii, which is a server that is already running. In production, acpmux prewarms the process: the real Chief turns of Oct 18-19 had `start_ms` p50 1.15 s and p90 3.1 s. Here, four runs in parallel on one Mac made it 3.2 s.

## Production traces (Oct 18-19, default Chief, 419 turns)

``Native/OptChat/optchat-chief/measure/chief_trace_stats.py`` over `~/.cmux/chief/default/optchat/traces`:

**Chief turns**
- **Time to first token:** p50 3.66 s, p90 11.1 s.
- **Turn time:** p50 18.6 s, p90 63.6 s.
- **Process start:** p50 1.15 s.
- **Cost:** p50 $0.26 per turn, $135 in total.

**First request of each turn**
- **Prompt:** p50 62k tokens.
- **Cache hit:** 54.9%.
- **Cold turns:** 181 of 419 wrote more than 20k tokens: 152 of 293 on `claude-sr2` and 29 of 127 on `claude`.
- **Not caused by expiry:** the gap before a cold turn (p50 30 s) is the same as before a warm one (p50 28 s), so these turns did not hit the TTL. They landed on another account.

**All requests (turns plus tool steps):** 92.7% hit.

**Compactor:** 4,220 nodes, 82.0% hit, p50 5.7 s per node, $6.34 in total.

**Gateway probe (16 identical cached Haiku calls):**
- Without a session header, 4 of 16 missed (calls 1, 7, 11 and 15).
- With `X-Subrouter-Session`, 0 of 15 warm calls missed.

## Result

**Against our own "before":**
- **Cache misses:** fixed. With the header, no warm turn missed (0 of 5). Without it, 3 of 5 missed.
- **Warm hit:** 39.4% → 98.5%.
- **Cost:** $1.87 → $0.59 for 6 turns, 3.1x lower.
- **Time to first token:** p50 8.2 s → 5.3 s.
- **Per cold turn avoided:** an Opus cold turn costs about $0.45, against $0.029 for a warm one, so each avoided cold turn is about 16x cheaper.

**Against the Unii baseline (both sticky):**
- **Cache hit:** at parity. 98.5% against 99.1%; the ceiling is 100%.
- **Cost:** the Chief is 1.6x more expensive per 6 turns, from 14% more prompt, 462 uncached tokens per turn, and 2x cache-write prices for the 1-hour TTL.
- **Time to first token:** p50 is 1.0 s slower, which is the process start.
- **10x better than Unii is not possible on these metrics:**
  - hit is at its ceiling;
  - tokens are mostly the view, which both send;
  - latency is bound by the model and the route.

  The floor is parity: one direct request with no process start (rows 2, 3, 4 and 7 of the design doc).

## Phase 2: a kept turn session (2026-10-20, a226)

Run on the Mac mini `cmux-macmini` (Apple M4, macOS 26.3.1, Claude Code 2.1.300), not on this Mac. Two runs, one harness at a time (no parallel runs), Opus 5.5, effort medium, sr2, sticky, 6 turns, 100 KB view. `chief-keep` is the new default (`--harness chief-keep`): one Claude Code process for all turns, Claude Code's own 1h marks, and each turn sends only its new message.

Warm turns 2 to 6 of both runs (10 turns per harness):

| Metric | Unii | Chief before (fresh session) | Chief after (kept session) |
|---|---|---|---|
| Warm hit | 99.2% | 98.8% | 99.7% |
| TTFT p50 / p90 s | 4.33 / 8.54 | 2.39 / 3.93 | 1.97 / 2.39 |
| Turn p50 / p90 s | 4.34 / 8.54 | 3.50 / 4.81 | 2.40 / 2.94 |
| Process start per turn s | 0 | 0.26 here (1.15 p50 in production, with acpmux) | 0 |
| Uncached input tokens per turn | 4 | 339 | 4 |
| Cost per warm turn $ | 0.0238 | 0.0281 | 0.0253 |
| Prompt tokens, turn 1 | 39.6k | 45.05k | 45.05k |

Notes:
- In run 2 the kept session's turn 1 read the prefix that the fresh-session run had just written (same prompt bytes), so turn 1 cost is not compared here.
- Unii's latency on this route varied much (two turns at 8.5-8.9 s). The model and the route are most of every number here.
- **Not closed: the 5.5k extra prompt tokens.** With a 1 KB view and Haiku: Unii 3,276; Chief with an empty system prompt and ToolSearch only 996; + the Chief system prompt (11.6 KB) about +4.07k; + Bash +1.7k; + Read/Edit/Write +1.3k; + WebFetch/WebSearch +0.7k. So about 4.1k is the Chief's own instructions (person profile and user instructions) and about 1.4k is tools. Both are read from the cache on warm turns (0.1x price), and the Chief uses all of these tools, so we did not remove them.
