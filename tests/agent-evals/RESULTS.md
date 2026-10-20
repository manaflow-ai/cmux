# Agent evals: results

How well agents drive cmux. Design and task list:
[agent-evals-DESIGN.md](../../plans/cmux-next/agent-evals-DESIGN.md). Run:

```sh
bun test tests/agent-evals                                   # graders, no daemon
bun tests/agent-evals/run.mjs --agents oracle:cli,noop:cli   # harness check: oracle 9/9, noop 0/9
bun tests/agent-evals/run.mjs --run NAME --agents claude:cli,claude:mcp,codex:cli,codex:mcp,opencode:cli,opencode:mcp,cursor-agent:cli --parallel 5
```

Per-run artifacts (snapshots, agent output, call logs): `artifacts/agent-evals/<run>/` (not committed).

## Run baseline-2026-10-20 (2026-10-20)

| Agent | Surface | Passed | Mean score | Median cmux calls | Median time (s) | Top failures |
| --- | --- | --- | --- | --- | --- | --- |
| claude | cli | 6/9 | 0.97 | 13 | 26 | focus_stolen 3 |
| codex | cli | 5/9 | 0.90 | 14 | 165 | focus_stolen 2, not_done 1, wrong_place 1 |
| cursor-agent | cli | 5/9 | 0.90 | 15 | 71 | agent_error 4 |
| claude | mcp | 3/9 | 0.89 | 7 | 26 | focus_stolen 5, wrong_place 1 |
| codex | mcp | 3/9 | 0.89 | 12 | 229 | focus_stolen 3, not_done 2, wrong_place 1 |
| opencode | mcp | 4/9 | 0.89 | 11 | 103 | focus_stolen 3, not_done 1, wrong_place 1 |
| opencode | cli | 2/9 | 0.76 | 10 | 87 | focus_stolen 2, not_done 2, left_session 1 |
| amp | cli | skipped (no_login) | | | | |
| gemini | cli | skipped (no_login) | | | | |

| Task | claude/cli | codex/cli | cursor-agent/cli | claude/mcp | codex/mcp | opencode/mcp | opencode/cli |
| --- | --- | --- | --- | --- | --- | --- | --- |
| group-workspaces | pass | pass | pass | pass | pass | pass | pass |
| watch-command | focus_stolen (0.89) | not_done (0.78) | pass | focus_stolen (0.89) | focus_stolen (0.89) | not_done (0.78) | not_done (0.67) |
| subagents-right | focus_stolen (0.91) | focus_stolen (0.91) | agent_error (0.91) | focus_stolen (0.91) | focus_stolen (0.91) | focus_stolen (0.91) | focus_stolen (0.91) |
| group-tabs | pass | pass | pass | pass | pass | pass | no_grouping (0.33) |
| read-only-answer | pass | pass | agent_error (0.80) | pass | pass | pass | wrong_answer (0.80) |
| reuse-right | pass | wrong_place (0.63) | agent_error (0.50) | wrong_place (0.63) | wrong_place (0.63) | wrong_place (0.63) | not_done (0.50) |
| terminal-right | pass | pass | agent_error (0.89) | focus_stolen (0.89) | not_done (0.89) | pass | pass |
| new-workspace-background | pass | pass | pass | focus_stolen (0.80) | not_done (0.80) | focus_stolen (0.80) | focus_stolen (0.80) |
| organize-end-to-end | focus_stolen (0.92) | focus_stolen (0.92) | pass | focus_stolen (0.92) | focus_stolen (0.92) | focus_stolen (0.92) | left_session (0.83) |

Setup: headless tier only (8 tasks need no app; the 5 browser, Markdown and
website tasks need an app and are not run yet). Each run used its own
ephemeral session, with a scrubbed environment and a sandbox that blocks every
cmux socket except the session's own. Retries 0. Versions: Claude Code 2.1.303
(default model, subrouter), Codex 0.163.0 (user config: gpt-6.1-sol, xhigh,
subrouter), OpenCode 1.19.3 with `zai/glm-5.2` (subrouter; its default Kimi key
has expired), Cursor Agent 2026.10.19. Claude cost reported: $3.54 for 18 runs.

Not scored:
- Amp: needs a new ChatGPT login at ampcode.com. Gemini CLI: no `GEMINI_API_KEY`.
  The runner never starts a login.
- Cursor Agent: 4 of 9 runs lost the connection to Cursor's server
  ("WritableIterable is closed"), so they are `agent_error`, not cmux failures.
- Chief: needs the app tier. "poly": no harness of that name exists on this Mac.

## Top failure modes

1. **`pane split` moves focus to the new pane (cmux bug).** It happens through
   the CLI and MCP. `tab create` keeps focus. `focus_kept` failed in 26 of 59
   scored runs. Most agents told the user "your terminal is unchanged". If split
   kept focus, the pass rate would be 46 of 59 instead of 28 of 59: claude/cli
   9/9, claude/mcp 8/9, codex/cli 7/9, codex/mcp 6/9, opencode/mcp 7/9,
   opencode/cli 4/9.
2. **Agents split again instead of adding a tab to the existing right
   column.** 5 of 6 scored agent/surface pairs failed `reuse-right`. Only
   claude/cli used the existing pane.
3. **Extra empty shell tab.** `pane split` always starts a shell. An agent that
   then runs its command with `pane run` gets a second tab and leaves the empty
   one (codex/cli and opencode/mcp `watch-command`, codex/mcp `terminal-right`).
4. **Old cmux habits.** Agents call commands that only the app answers
   (`identify`, `list-panels`, `new-split`, `list-pane-surfaces`). Codex
   learned them from `~/.agents/skills/cmux-workspace/SKILL.md`, which teaches
   the classic CLI. When those commands fail, agents look for other sockets:
   OpenCode tried the live app sockets (`~/.local/state/cmux/cmux.sock`,
   `/tmp/cmux-nightly.sock`), the sandbox blocked it, and the run is scored
   `left_session`. In a smoke run, before the sandbox existed, Codex opened a
   parallel eval session's socket. Once, OpenCode stopped to ask the user for an
   app socket.
5. **Grouping is the strong part.** All 7 agent/surface pairs grouped related
   workspaces. 6 of 7 passed `group-tabs` (the exception is opencode/cli).
   Group names are descriptive ("API", "Web", "Server", "Tests").

## Caveats

- In the headless tier, the commands that only the app answers fail. Real use
  has the app, so failure mode 4 counts somewhat more here than in real use.
- MCP did worse than CLI for Claude (3/9 against 6/9). The CLI shows the
  `pane split` focus change in `pane list`, and Claude CLI noticed it and
  refocused. Through MCP it did not notice.
- One run per cell. Expect noise of about one task per row.
