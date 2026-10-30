# Tool evals: results

How to run and add cases: [README.md](README.md).

## Round 1 (2026-10-27): code mode, Sonnet 5.5 and Opus 5.5

35 cases (27 in `cases/`, 8 headless agent-evals tasks), `--surface code`, 2 samples
each, effort medium. Baseline: the cmux of 7046be8c4ab1 (docs search fix and no-app
`current` only). New: the cmux of 065a20eb0df plus the tool sheet of the next commit
(run as `overlays/v3.json` over that build; the commit after it has the same text in
`code_mode.rs`).

| Model | Text | Cases pass | Samples pass | Cost | Input tokens (all steps) | `cmux.docs` calls | Tool errors |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Sonnet 5.5 | before | 28/35 | 58/70 | $7.26 | 5.84 M | 122 | 20 |
| Sonnet 5.5 | after | 33/35 | 67/70 | $2.34 | 2.86 M | 18 | 11 |
| Opus 5.5 | before | 30/35 | 63/70 | $16.96 | 6.50 M | 137 | 18 |
| Opus 5.5 | after | 34/35 | 68/70 | $5.61 | 3.22 M | 36 | 11 |

No case that passed before fails after, on either model. Input tokens fell 51% (Sonnet)
and 50% (Opus); median steps per task fell from 6 to 4 (Sonnet) and 5 to 4 (Opus).
The Opus "before" run lost 10 samples to the model gateway refusing connections; they
were run again on the same build (`r5-opus-base-rerun*`) and those samples replace them.

Cases fixed: `ae-reuse-right` (tab in the existing right column instead of a new split),
`ae-watch-command`, `ae-organize-end-to-end`, `move-workspace-checked`, `notify-when-done`,
`rename-tab`, `no-app-current`, `read-right-terminal`, `ae-new-workspace-background`.

Still failing: `sign-in-link-in-cmux` (both models run macOS `open URL`: the headless tier
has no cmux browser, so this needs the app tier to judge), and one `rename-tab` sample on
Sonnet.

## Round 2 (2026-10-30): real harnesses, 12 models

All 34 headless cases, 2 samples each. Claude models run through the Claude Agent SDK
(the installed Claude Code) and the rest through OpenRouter in the generic harness. Each
sample's cmux daemon and MCP server run on the rbx builder (`--remote-daemon`), and the
agents run under the live guard. Baseline: the #26625 build (b3). New: 858cd2f (h9).

| Model | #26625 | 858cd2f | Tool errors |
| --- | --- | --- | --- |
| Opus 5.5 | 33 | **34** (68/68) | 11 → 12 |
| Haiku 5.5 | 29 | **34** (68/68) | 43 → 8 |
| Sonnet 5.5 | 32 | 33 (67/68)¹ | 7 → 7 |
| Grok 4.7 | 28 | **34** | 19 → 14 |
| Gemini 4 Argon | 34 | 33 | 16 → 14 |
| MiniMax M3.1 Flash | 27 | 33 | 61 → 8 |
| Kimi K3.1 Pro | 28 | 33 | 23 → 17 |
| Qwen 3.8 Max | 31 | 33 | 28 → 17 |
| DeepSeek v4.1-flash | 29 | 32 | 26 → 12 |
| Mistral Large 4 | 27 | 32 | 24 → 13 |
| GLM 5.3 Prime | 26 | 31 | 102 → 20 |
| GLM 5.3 FlashX | 20 | 29 | 59 → 29 |

¹ Sonnet's one miss, `move-workspace-checked`, came from the grader. The grader read the
session's workspace index; the sidebar shows the personal placement order, which
`workspace_place {index}` sets. With the grader fixed (9bcfa81), all 12 models pass that
case and the two other workspace cases in 3 of 3 samples.

The fixes in this round each came from errors in the panels: ids at the top of a change's
answer; a tab where a terminal is needed; `.catch` on calls; function-shaped scripts; a
record where its id goes; and these sheet lines: "next to X" means a new tab in X's pane,
`pane_neighbor_get` / `terminal_process_get`, and a terminal tab that stays open.

Not run in this round: GPT 6 Astra. The subrouter paused gpt-6-astra admission
(`admission_paused`) for the whole round.

## What changed, and the failure each change answered

| Change | Failure it fixed (case, source) |
| --- | --- |
| `cmux.docs` matches half the query words, stop words dropped, daemon tool before its `app_*` twin | Sentences found 0 tools, then one-word queries found 267 (`codemode-nl-query-zero-matches`, mined) |
| `current` without an app resolves from the daemon, as the CLI does; a terminal with no place goes beside the chat | Every MCP `current` failed with `caller.unresolved` in a TUI or Cloud session (`no-app-current`) |
| Decimal fields (`timeout_ms`) take JSON numbers | 23 of 60 tool errors in one run were `timeout_ms must be a decimal string` |
| Instructions keep only the rules (the old text plus the asking rule was at Claude Code's 2048-character cut); the common-tool sheet, argument names and result shapes move to the `cmux_exec` description | Agents spent 2-6 docs searches before acting; scripts read `r.terminal_id` instead of `r.value.terminal_id` (17 errors); `tab_create_terminal` with no pane already goes beside the chat, but no text said so (`reuse-right`) |
| The sheet names the arguments of rename, grouping, status and notification | A sheet without them regressed `ae-group-workspaces` (an app-only action), `sidebar-status` (guessed `status`) |
| Docs answers are compact (no protocol tag, idempotency text or per-selector paragraph; shared arguments as `alsoTakes`) | Six typical docs answers were 82 KB; now about half |
| An unknown tool in a script says "did you mean ..." | Guessed names `context`, `layout`, `system_identify`, `terminal_send` (mined: 21 requests) |

## Not run yet

- `--surface all` (what acpmux gives Claude Code and Codex) and `--surface cli` after the
  change. The change touches code-mode text and shared behavior (`current`, decimals).
- Codex models: the harness replays Claude Code only. The mined data shows Codex never
  called cmux MCP in 60 eval runs (it reads the skill and uses the CLI), so a Codex
  template is the next step.
- The app tier (browser, Markdown): needs a cmux-next app on a GUI host.
