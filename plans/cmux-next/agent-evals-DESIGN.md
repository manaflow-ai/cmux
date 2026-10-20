# cmux next: agent evals (how well agents drive cmux)

Design, 2026-10-19. Asked by Lawrence (Chief subagent "Agent cmux-use evals"): "evals of how well agents
are able to use cmux: CLI, code mode, etc. ... ask Claude Code, Codex, OpenCode
and poly to use stuff, use a browser, open markdown files, operate stuff on
websites. They should open it to the right very smartly and, at the end, create
the right groups when it makes sense, making tab groups."

Related: automation-bench.md (browser/computer-use primitives; this suite is
the layer above it: does an agent pick the right cmux calls), code-mode.md
(the MCP surface under test), focus.md (agents never move the user's focus).

## Goal

One scoreboard per agent and surface that answers: when a user asks an agent
in a cmux terminal to open, run, read or organize something, does the agent

1. put it in the right place (the right-hand column, as a tab; never the
   agent dock, never a new split when a right column exists),
2. leave the user where they are (focused workspace, screen, pane, tab),
3. leave nothing behind (no stray workspaces, no closed user tabs),
4. finish the job (the command ran, the answer is correct), and
5. tidy up when it makes sense (tab groups and workspace groups with
   descriptive names, and no grouping when nothing asked for it).

## Agents and surfaces under test

| Agent | How the runner starts it | Surfaces |
| --- | --- | --- |
| Claude Code | `claude -p --output-format json --dangerously-skip-permissions --strict-mcp-config --setting-sources project,local` | `cli`, `mcp` (code mode) |
| Codex | `codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -o last.txt` | `cli`, `mcp` (code mode) |
| OpenCode | `opencode run` | `cli` |
| Amp | `amp -x --dangerously-allow-all` | `cli` |
| Cursor Agent | `cursor-agent -p --force` | `cli` |
| Gemini CLI | `gemini -p --yolo` | `cli` |
| Chief | Home chat in a cmux app | `app` tier only (see below) |

- `cli`: the agent only has a shell. `cmux` is on `PATH` (a logging shim in
  front of the real binary). Nothing in the prompt says how to use it; the
  agent must discover `cmux --help` or know it.
- `mcp`: the agent also gets `cmux mcp serve` (code mode: `cmux_docs` and
  `cmux_exec`) as its only MCP server, pointed at the eval session.
- "poly": no binary or harness by that name exists on this Mac
  (`which poly`, `~/.local/bin`, acpmux harness list). It is recorded as
  unknown; the adapter table takes it in one entry when someone names it.
- An agent without a working login is reported `no_login` and skipped. The
  runner never starts a login flow. Claude Code and Codex use the existing
  subrouter route; no new cost or account.

## Isolation (never the user's live workspaces)

Every task run gets its own cmux session:

- `cmux daemon start --session agent-eval-<run>-<task> --ephemeral --headless`,
  started with a scrubbed environment: every `CMUX_*`, `ACPMUX_*` and `MUX_*`
  variable removed, `CMUX_NEXT_CONFIG_FILE` set to a run-local settings file
  (`{"mcp": {"enabled": true}}`), and `CMUX_SOCKET_PATH` set to a path that does
  not exist, so an app command fails with `socket.no_app` instead of reaching
  the user's running app.
- The agent is started inside the session's origin terminal (as a user would),
  so `current` selectors, `CMUX_TUI_TERMINAL_ID` and the launch credential
  are the eval session's.
- Preflight (fails the run as `harness_error`): with the agent's environment,
  `cmux --json workspace list` must return the eval session's workspaces, and
  `cmux identify` must fail. Agent processes get a run-local MCP config and
  no user MCP servers (Claude `--strict-mcp-config`, Codex
  `-c mcp_servers={}` override per server, others have none configured).
- The session is stopped with `--end-terminals` after grading. Sessions are
  ephemeral, so nothing is written to the user's session state.

## Tiers

1. **headless** (runs on any Mac, now): the daemon alone. Terminals, panes,
   columns, docks, tab groups, workspace groups, screens are all daemon state,
   so placement, focus and grouping are graded exactly. Browser and Markdown
   tabs need a renderer, so those tasks are not in this tier.
2. **app** (needs a cmux-next app that owns the eval session): a tagged
   cmux-next DEV app on a fleet GUI Mac (`reload.sh --tag agent-evals`, its
   own bundle id and socket), started against the eval session. The runner
   takes `--app-socket` and then also runs the browser, Markdown and website
   tasks, plus Chief. Not run on Lawrence's laptop (heavy build, focus). The
   tasks, fixtures and graders are in the suite now and unit-tested.

## Tasks (first set)

Start state is built by the runner with plain CLI calls before the agent
starts; the origin pane (the agent's own terminal) is focused.

| id | tier | Ask (short) | Graded |
| --- | --- | --- | --- |
| terminal-right | headless | open a terminal on the right, run `echo EVAL_RIGHT_OK` | one new terminal, right of origin, not docked, at most one new column, output seen, focus kept |
| reuse-right | headless | another terminal next to my logs on the right | new tab in the existing right pane, no new column or split, output, focus kept |
| subagents-right | headless | start 3 helper agents (`cmux-eval-agent --role build/test/lint`) on the right, named by role, grouped | 3 tabs in one right pane, names, each stub ran in its own terminal, one tab group holding exactly them |
| group-workspaces | headless | group related workspaces, close or rename nothing | api pair together, web pair together, different groups, names descriptive, nothing closed or renamed |
| group-tabs | headless | group the right-hand tabs sensibly | server pair together, test pair together, different groups, nothing closed |
| read-only-answer | headless | what error code did the build on the right print; change nothing | answer has `E4271`, layout unchanged |
| new-workspace-background | headless | new workspace "eval-proj" with two terminals side by side, run in the right one, do not switch me | exactly one new workspace with that name, two side-by-side columns, output in the right one, focus kept |
| organize-end-to-end | headless | run FE and BE terminals on the right, then tidy: tab group them, put this workspace in a "shop" group | 2 tabs right, tab group of both, workspace group named for shop holding origin |
| browser-right | app | open the local fixture page | browser tab in right column, not docked, no extra split, URL loaded |
| markdown-right | app | open `notes/PLAN.md` | Markdown/file tab right, not docked |
| website-form | app | sign up on the fixture site as Ada, plan Pro | fixture server received exactly that POST |
| website-read | app | what is the order total on the fixture page | answer has the total |
| research-group | app | open these 3 pages and group them | 3 browser tabs right, one tab group, name not empty |

## Grading (deterministic, no LLM judge)

The runner takes a state snapshot before and after: `workspace list`,
`workspace placement list`, `workspace group list`, `screen list`,
`screen <id> layout export` per screen, `pane list`, `tab list`,
`tab group list`, `terminal list` and the screen text of new terminals.
Graders are pure functions over (`before`, `after`, `answer`, `calls`):

- Placement: columns come from the viewport layout; a pane is "right of the
  origin" when its column index is greater; a docked column (`dock` set) never
  counts as the right column.
- Focus kept: the focused workspace, the focused screen and the focused pane
  are the same before and after (Lawrence: tools never move focus unless asked).
- Stray workspaces: workspace ids after minus before, beyond what the task
  allows.
- Grouping: a pair is "together" when both tabs (workspaces) carry the same
  group id; names are checked with a keyword list, case-insensitive.
- Answer: substring checks on the agent's final message.
- Calls: the `cmux` shim logs argv per call (JSON lines); the MCP config wraps
  `cmux mcp serve` with a tee of the JSON-RPC requests. Used for the
  `stayed_in_session` check (no `--socket`, `--session`, `--app-socket` to
  another target) and for metrics (call count, `--help` reads, errors).

Each check is `required` or `bonus`. A task passes when all required checks
pass. The task score is the passed-weight fraction. A failing task is tagged
with the category of its first failed required check:
`wrong_place`, `extra_split`, `docked`, `focus_stolen`, `stray_workspace`,
`closed_user_tab`, `not_done`, `no_grouping`, `wrong_grouping`,
`wrong_answer`, `left_session`, `timeout`, `agent_error`, `no_login`,
`harness_error`.

## Outputs

- `artifacts/agent-evals/<run>/rows.jsonl`: one row per (agent, surface,
  task): checks, pass, score, category, wall time, cmux call count.
- `artifacts/agent-evals/<run>/<agent>-<surface>/<task>/`: before/after
  snapshots, the agent's output, the call log.
- `tests/agent-evals/RESULTS.md`: one table per run (agent x surface: pass
  rate, mean score, median calls, top failure categories) and per-task
  pass matrix. Regenerated by `report.mjs`.

## Runner rules

- Each prompt starts with one line of context, "(You are running inside a
  terminal in cmux.)", and nothing more about how to use cmux.
- The agent runs under `sandbox-exec` with a profile that denies every unix
  socket whose path contains `cmux`, except the eval session's own socket (and
  the `--app-socket` in the app tier). Smoke runs showed that this is needed:
  OpenCode tried the user's live app socket, and Codex connected to a parallel
  eval session.
- Login shells (Codex runs `zsh -lc`) rebuild PATH. A run-local `ZDOTDIR` puts
  the `cmux` call-log shim first again.
- OpenCode runs one at a time, because its SQLite database locks under
  parallel runs.

- Retries 0 for scoring. Timeout 300 s per task (headless).
- Parallel by session; each task run is independent.
- Unit tests (`bun test tests/agent-evals`) cover graders, snapshot
  normalization and the report on fixture snapshots; they need no daemon.
- Running agents is not a build or test of the app, so the headless tier can
  run on this Mac. The app tier runs on a fleet GUI Mac.

## Steps

Status 2026-10-20: e1 to e3 done. The first baseline is in
[tests/agent-evals/RESULTS.md](../../tests/agent-evals/RESULTS.md). The app-tier
fixtures (local site, PLAN.md, the server-side form grader) are in the suite.
Running them needs e4.

| Step | Content | Verification |
| --- | --- | --- |

| e1 | this design, task table, graders, snapshot model, report; unit tests red then green | `bun test tests/agent-evals` |
| e2 | runner: isolated session, shim, preflight, agent adapters, headless tasks | live smoke against a scripted "oracle" agent that does each task right (must score 100%) and a "noop" agent (must fail) |
| e3 | first baseline per logged-in agent, RESULTS.md | headless tier on this Mac |
| e4 | app tier: tagged DEV app owning the eval session on a fleet GUI Mac; browser, Markdown, website, Chief | fleet |
| e5 | grow the set (rooms, screens, notifications, status, history) and track per nightly | nightly job |
