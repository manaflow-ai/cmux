# Chief usage analytics

Status: design, 2026-10-20 (Chief subagent "Chief usage analytics", group "Agents & routing"). Lands on `feat-cmux-next`, no PR.

User (2026-10-20): "for chief i want to have better analytics into token usage and cost and cache
stuff, across time".

## 1. What exists today

Every Chief host already writes a monitoring trace (`optchat-chief` `trace.rs`):
`<mux home>/optchat/traces/YYYY-MM-DD.jsonl`, one JSON line per event. The events that carry use:

| Event | Who | Tokens | Cost | Latency | Model / harness |
|---|---|---|---|---|---|
| `turn.end` | a Chief turn | `usage` (turn total), `first_usage` | `cost_usd` (per turn: a fresh Claude Code per turn) | `ms`, `start_ms` (process start), `ttft_ms` | `harness`; `model` is null on the default model |
| `request` + `turn` | each model request of a turn | `usage` | none | `headers_ms`, `ttft_ms` | `model` (always set) |
| `node` | one compactor node (one session) | `usage` | `cost_usd` (per node) | `ms`, `timing.session_start_ms`, `timing.ttft_ms[0]` | `harness`, `model` |
| `subagent.answer` | one subagent prompt | `usage` (that prompt) | `cost_usd`, **cumulative per subagent process** (Claude Code's `total_cost_usd`; it restarts at 0 when the process restarts) | none | none |
| `request` + `subagent` | each model request of a subagent | `usage` | none | `ttft_ms` | `model` |

`optchat-chief stats` folds these for one window (hit rate, p50s). There is no view over time, no
dollar total, no breakdown and no UI. On this Mac the default Chief's trace is 22 MB for 13 days
(about 30k `request` and `tool` lines), so a year of raw trace is about 600 MB: too big to scan for
each chart.

a226's numbers (sr2 bench, plans/cmux-next/BENCH-unii.md) are what the view must make visible:
Chief cache hit 39.4% → 98.5% after `X-Subrouter-Session`, turn p50 11.1 s → 6.1 s, 6-turn cost
$1.87 → $0.59. The hit-rate formula stays the trace's: `cache_read / (cache_read + cache_write +
input)`.

## 2. The usage ledger

A second, small, append-only file set next to the trace: `<mux home>/optchat/usage/YYYY-MM.jsonl`
(directory 0700, files 0600). One line per **billable unit**: a Chief turn, a compactor node, a
subagent prompt. About 250 bytes a line; the default Chief makes about 10k lines in two weeks
(mostly compactor nodes), so about 60 MB a year.

```json
{"v":1,"ts":1792393046275,"kind":"turn","key":"turn:optchat:1745:2026…","agent":null,
 "model":"claude-opus-5-5","harness":"claude","status":"ok",
 "input":11540,"output":1849,"cache_read":253275,"cache_write":905,
 "usd":0.141035,"usd_cum":null,"ms":56982,"start_ms":6306,"ttft_ms":6318,"src":"live"}
```

- `kind`: `turn` | `compactor` | `subagent`. `agent`: the subagent id (`a241`) for `subagent`.
- `model`: the event's model, else the last `request` model of the same turn or subagent.
- `usd`: the unit's own cost. For a subagent the trace only has the running total, so the writer
  keeps it as `usd_cum` and writes `usd = usd_cum - previous usd_cum`, or `usd_cum` when it went
  down (the process restarted). After a host restart the previous total is read back from the
  ledger's last line for that agent, so a restart does not count a subagent from zero. Known gap:
  a subagent process that restarted while the host was down and already passed its old total is
  undercounted by that old total.
- `session`: a subagent's acpmux session (from `subagent.start`), for its link.
- `src`: `live` (written by the host) or `trace` (backfilled).

**Writer.** `Trace::emit` hands each event to `usage::Ledger::observe` after writing the trace line.
It keeps only small maps (last request model per turn and subagent, subagent session and running
cost, each bounded at 256 entries) and appends a line on `turn.end`, `node` and `subagent.answer`. No timer, no thread: idle
CPU is zero. A Chief whose trace is off (`Trace::off`) writes no ledger either.

**Retention.** Bounded by age and size: on the first line of a new month, month files older than
`OPTCHAT_USAGE_KEEP_MONTHS` (default 13) are deleted, then the oldest months go until the directory
is under 256 MB. Whole files only; nothing is rewritten.

**Backfill.** The first read of a ledger with no `usage/backfill.json` converts the trace events
older than the ledger's first live line (`usage/live-since`) into `src: trace` lines (same fold,
same writer), skipping months retention would delete, then writes `backfill.json` with the last
converted time (`--force` continues from it). An `O_EXCL` lock file keeps two readers from backfilling at
once. `optchat-chief usage backfill [--force]` runs it on demand. So the first open shows history
back to the oldest kept trace (Oct 6 on this Mac).

## 3. The query

`optchat_chief::usage::query(homes, Query) -> Summary`, pure over the read lines (tests feed
lines). Read cost is bounded by the months in the window.

```text
optchat-chief usage [--since 7d] [--until now] [--bucket hour|day|week|month]
                    [--by chief|agent|model|harness|kind] [--top N] [--json]
                    [--mux-home DIR]... [backfill [--force]]
```

Default window 7 days, bucket picked from the window (≤ 2 d: hour; ≤ 60 d: day; ≤ 1 y: week;
else month), `--by chief` across every given home. A home's Chief label is its `profile.json` name,
else its `chief-id`, else "default". Buckets are in local time.

`--json` (the page and CLI read the same object):

```json
{"v":1,"since":ms,"until":ms,"bucket":"day","chiefs":[{"id":"default","label":"Chief","home":"…"}],
 "totals":{"units":812,"turns":120,"input":…,"output":…,"cache_read":…,"cache_write":…,"usd":41.2,
           "hit":0.93,"ms_p50":6100,"ms_p95":40000,"ttft_p50":5200,"ttft_p95":9000,
           "start_p50":1150,"start_p95":3100},
 "series":[{"t":ms,"units":…, "turns":…, "input":…, "output":…, "cache_read":…, "cache_write":…,
            "usd":…, "hit":…, "ms_p50":…, "ms_p95":…}],
 "by":[{"key":"claude-opus-5-5","label":"claude-opus-5-5", …totals}],
 "top":[{"ts":ms,"chief":"default","kind":"turn","agent":null,"key":"turn:…","model":"…",
         "usd":…,"input":…,"output":…,"cache_read":…,"cache_write":…,"ms":…,"link":"cmux://…"}]}
```

Latency percentiles are over `turn` lines only (what a person waits on); token and dollar totals are
over every kind. `top` links: a subagent line links its chat (`cmux://chief/<home id>/session/<session>`, the link
Home already uses for subagents); a turn shows its key (no deep link to a Chief message exists
yet); a compactor node shows its block (`5236+4`).

## 4. Entry points (one shared path)

All read through `optchat-chief usage --json`, which owns the ledger format and the fold:

- **CLI**: `cmux chief usage [--chief ID] [--since …] [--by chief|agent|model] [--json]`. The cmux
  CLI resolves the Chief home(s) as `cmux chief` does (`--chief-home`, `CMUX_CHIEF_HOME`, the
  default), finds `optchat-chief` next to its own binary (Contents/Resources/bin) or
  `CMUX_NEXT_MUX_HOST`, and runs it. Without `--chief` it passes the default home and each Chief under
  its `c/` directory.
- **App page**: "Chief Usage" (`cmux-page://cmux.chief-usage/`, React in
  `webviews/src/pages/chief-usage`), one op `cmux.chief_usage.summary {since, bucket, by, top}` that
  the app answers by running the bundled `optchat-chief usage --json` off the main actor (as
  `BundledChiefMemoryTool` does). It opens as a tab in the Home right column.
- **Actions**: `chief.openUsage` ("Chief: Usage") in Cmd+Shift+P, the Chief's ··· menu ("Usage…"),
  and so `cmux action run chief.openUsage` and the MCP `app_*` action tool.
- **The Chief itself**: the optchat MCP's `stats` tool keeps its window view; the Chief can run
  `cmux chief usage --json` in a subagent like any CLI.

No new daemon protocol op: the ledger is a local file of this Mac's Chief homes, and the brain need
not run to read it. A paired server's Chief is out of scope for v1 (its brain could answer
`chief.usage.get` through `chief_control.rs` later; the JSON above is that op's answer).

## 5. The page

Header: window picker (24 h, 7 d, 30 d, 90 d, 1 y), bucket follows. Then tiles: cost, tokens,
cache hit, turns, p50/p95 turn time. Then charts over time, then the breakdown table (by Chief,
agent, model, harness, kind), then the top 10 expensive units with links.

Four designs in a gallery (`chief-usage.gallery.tsx`), shown in the Home right pane; the
Recommended one ships:

1. **Ledger (Recommended)**: tiles row, one stacked-bar chart of tokens by kind (input, cache read,
   cache write, output) with a cost line on a second axis, a small cache-hit line and a p50/p95 band
   under it, then table and top list. Dense, everything on one scroll.
2. **Tabs**: one chart at a time (Cost | Tokens | Cache | Latency) behind a segmented control.
3. **Small multiples**: a 2×2 grid of sparkline cards, each with its own total.
4. **Receipt**: a list-first view: per day rows with cost, tokens and hit as inline bars; no axes.

Charts are inline SVG (no chart library: the page must stay small and open fast), with the
`dataviz` rules: neutral palette, one accent per series, tabular numbers, hover tooltips, light and
dark from the page base. All strings come from the page's `Localizable.xcstrings` (21 languages);
numbers and dates use `Intl` with the page's language.

Idle cost: the page reads once when shown and when the window changes; no polling, no timers. A
"Refresh" button reads again.

## 6. Tests (failing first)

- Rust (`optchat-chief`, fleet `cmux-tui-rust-check.sh optchat-chief usage`):
  - the ledger writer turns `turn.end` / `node` / `subagent.answer` (+ their `request` lines) into
    the right lines, model filled from requests;
  - cumulative subagent cost becomes per-prompt cost, a restart does not double count;
  - buckets, hit rate, p50/p95, `--by`, `top` on a fixed set of lines;
  - backfill from a trace directory once, idempotent, lock respected;
  - retention deletes old months and caps the size.
- CLI (`cmux-tui`): `cmux chief usage --json` runs the tool with the resolved homes (a fake
  `optchat-chief` that prints its argv).
- Web (`webviews`, fleet `run-webviews-tests.sh`): the page renders the fixture summary (tiles,
  series count, table rows, top links), the window picker asks for the right `since`, strings exist
  in every locale.
- Swift: the page provider maps an op to the tool's argv and refuses unknown ops.

## 7. Not in v1

- A paired server's Chief (needs `chief.usage.get` through the daemon).
- Per-account (sr2) attribution: the subrouter does not say which account served a request.
- Budgets and alerts ("tell me when a day passes $20"): the ledger has what they need.
