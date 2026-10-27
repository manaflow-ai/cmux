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

## Chief fast evals (the inner loop)

Asked by Lawrence, 2026-10-26: "chief needs to be significantly better, we
need to decrease the iteration loop time for chief." The tasks above score
agents driving cmux through a real app session; they take minutes per task
and an app tier. This section is the Chief's own inner loop: every Chief
prompt or behavior change gets a score in under 2 minutes, on Linux, before
it ships.

### What runs

- `Native/OptChat/optchat-chief/evals/run.sh` (README beside it has the
  case format). One process, no app, no acpmux, no daemon.
- Model cases, `evals/cases/<group>-<name>.json`: scripted history seeded
  into a real OptChat memory (the production compactor builds the
  summaries), then turns. Each turn sends what a production Chief turn on
  a Claude harness sends: `prompt::system_text` over the person profile,
  the frozen view and delta of `OptChat::turn_input` in
  `prompt::input_layout` (its three cache marks), and the `optchat` MCP
  tools of `mcp::tools_granted` (so a new tool is in the eval at once).
  Claude Code's own system prompt and built-in tools are not sent; `bash`
  stands in for them. Side effects are stubs: `cmux`, `gh`, `chief`, `git`
  and the rest are shims on PATH that log argv and answer from the case;
  MCP tools answer as the brain does (spawn gives an id and a workspace,
  stop/sleep end the turn and drop text after the last send, the reply
  ledger refuses a stop over an unanswered message and runs the `[no
  reply]` retry turn). `zoom`, `date` and `transcript` read the real
  memory.
- Deterministic cases, `tests/eval_<group>.rs`: host behavior that needs no
  model call (a stuck-agent alert, the reply ledger), on the in-process
  fakes of `tests/common`.
- Grading: deterministic checks (regex on the posted text, `no_raw_ids`
  for the link rule, tool calls made or not, word count, no question,
  silence, files written) and a model judge (Sonnet, PASS/FAIL with a
  reason) for what no regex can say.
- CI: `.github/workflows/chief-evals.yml`, GitHub-hosted `ubuntu-24.04`
  (not Blacksmith), on every push to feat-cmux-next touching
  `Native/OptChat/**` or the cmux-chief / cmux-conversation crates.
  Deterministic cases gate. Model cases reach the team subrouter through
  the tailnet (`tag:ci` may reach port 31415), gate at an 80% pass rate
  (`vars.CHIEF_EVAL_MIN_PASS`), and are skipped with a warning when
  `chief_eval preflight` finds the route down. The table goes to the job
  summary, rows to the `chief-evals` artifact. Each run diffs per group and
  case against the last run's artifact (`--baseline`, evals/README.md
  "Baseline diff"); workflow dispatch runs it on demand, with
  `baseline_run` to pick the baseline.

### Groups and owners

| group | owner | what it guards |
| --- | --- | --- |
| links | a672, a674 | every workspace, PR, commit range, run and tab is a Markdown link; no raw ids |
| multiplayer | a672, a673 | group chats with two people and two Chiefs: NO_REPLY when not for this Chief, Chief-to-Chief loop guard |
| acp | a672, a674 | an instruction for a running agent goes to it (tell), not a new spawn |
| automations | a672, a675 | a recurring ask becomes a real scheduled job |
| upsell | a675 | a cloud-only ask sends the Stripe test-mode checkout link, no upsell when not needed |
| tenacity | a672, a676 | follow-through over turns: not-landed reports sent back, blockers to the person, answers back to the agent; stuck-agent alert handled with no model call |
| assistant | a672, a676 | Instinct/Muse quality: remembers, acts instead of asking, short, a bare thanks gets a tapback only |
| memory | a672 | summary lag: the Chief answers about its own recent reply while 321 lines are unsummarized |
| replies | a672 | reply ledger: a tapback answers, stop/sleep refused over an unanswered message |
| tone | a25575 | plain answers: no filler intro or offer of help, no apology string to a frustrated person, results not narrated steps |
| delegation | a25575 | build and test work goes to a subagent, one per independent ask; the Chief does not run it itself |

### Tracked numbers (summary.json)

Turn latency p50/p90 (wake to end of turn, retry turn included), first
request latency, requests, input/output tokens and cache hit per turn,
`[no reply]` retry turns, and summary lag (`unsummarized_max`: placeholder
lines in the view a turn read).

### Baseline and first fixes (2026-10-26)

claude-opus-5-5 at medium effort, judge claude-sonnet-5, sr2 gateway, run on
the cmux-lawrence mini (the subrouter answered 502 that day).

| run | cases x repeats | pass | wall | turn p50 / p90 | tokens/turn | cache hit | retry turns |
| --- | --- | --- | --- | --- | --- | --- | --- |
| baseline (before fixes) | 27 x 3 | 68/81 (84%) | 216 s | 36.6 / 69.7 s | 34.1k | 0.80 | n/a |
| reply ledger as before (`--ledger pre`) | 32 x 3 | 79/96 (82%) | 172 s | 36.2 / 63.2 s | 35.2k | 0.91 | 6 |
| after the 3 fixes | 32 x 3 | 83/96 (86%) | 201 s | 36.4 / 69.5 s | 35.8k | 0.83 | 0 |
| CI setting, 1 run | 32 x 1 | 27/32 | 87 s | 16.3 / 27.2 s | 31.0k | 0.85 | 0 |

The worst three failures and their fixes:

1. Replies too long (assistant short-status and needs-you-first, 0/3 and 1/3):
   a676 tightened the Replies rules in `prompt.rs` CHIEF_TURNS; the
   assistant group went 13/24 to 22/24.
2. A bare "thanks" got words (ack-silent 0/3): the Chief reacted, then the
   reply ledger still held the message, and the `[no reply]` retry turn 5 s
   later posted "You're welcome." Now a tapback answers the message it is
   on (`brain/replies.rs`), and `stop`/`sleep` over a seen, unanswered
   person message is refused inside the turn (`brain/wakes.rs`,
   `reply_ledger.rs unanswered_in_turn`), so the reply comes in the same
   turn instead of a second turn. Tests: `tests/eval_replies.rs` (3 of 4
   failed before). ack-silent 0/3 to 2/3, retry turns 6 to 0.
3. Summary lag (memory-lagging-view 0/3 in the first runs): with 321
   unsummarized lines the Chief zoomed with string ids (`"id": "321"`).
   Production parses them (`tools::Call::parse`); the eval runner did not,
   so this was a harness bug, fixed by parsing as production does. With it
   3/3: the Chief zooms the placeholder lines and answers. The Cloud Chief's
   failure on 730 unsummarized lines is then not the turn's zoom path; its
   lag itself (compactor throughput on the VM) stays open.

Open: one judge run returned no verdict (now retried once); automations
cases from a675 fail 2/3 (word count, judge); the model route in CI depends
on the tailnet: the only GitHub OIDC trust credential for `tag:ci`
(T4fhFAtTch11CNTRL) accepts the subject
`repo:manaflow-ai/cmux:environment:ios-e2e` only, so this job gets a 403 and
skips its model cases with a warning. It needs a federated credential for
`repo:manaflow-ai/cmux:ref:refs/heads/feat-cmux-next` (tag `tag:ci`, scope
`auth_keys`) set as `vars.TS_CHIEF_EVALS_OIDC_CLIENT_ID`/`_AUDIENCE`. The
subrouter itself answered 502 during this work (the sr2 gateway worked).
Until then the model cases run on a mini: `evals/run.sh` on cmux-lawrence.
