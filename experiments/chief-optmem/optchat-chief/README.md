# optchat-chief

An OptChat Chief for cmux-next Home. It keeps the brain-host contract of
`mux/host` (so the app needs no changes) and replaces the long-lived `mux`
acpmux session with the turn loop of Victor Taelin's OptChat spec: every human
message is logged into one endless OptChat memory, and every turn is a fresh
model call that reads the memory's view (about 128 KB of one-line summaries of
the whole chat) plus the new messages. The compactor that builds the summaries
runs inside the host: on the team subrouter each summary is one short-lived,
deny-all acpmux session of the normal harness (claude-sr), see
[Compactor routes](#compactor-routes).

Two engines run a turn (`OPTCHAT_CHIEF_ENGINE`):

- `native`: the host's own Messages API loop with `bash`, the text
  editor, `zoom` and `date`. It is the engine that keeps sections 7 and 8
  whole: three cache breakpoints in the view plus the request end, model
  output resent verbatim and tool results capped at CAP.
- `acpmux` (default): a fresh acpmux session per turn (`MUX_HARNESS`, default
  claude-sr), named `optchat-<home id>-<first id>`. Claude Code's own
  breakpoints never land in the view, so each turn rewrites the view in the
  cache. Claude Code's Task/Agent subagents are denied (their steps would be
  logged as the Chief's); `chief agents` starts agents instead. So are
  AskUserQuestion, EnterPlanMode and ExitPlanMode: acpmux keeps those for a
  human under every policy, and nobody answers them in a turn.

A human message sent while a turn works interrupts it at once, on both
engines, even mid-thinking and even when it only says "thanks" (decision
2026-10-04); a tool call already running finishes first. The native engine
drops the streaming step at its next streamed event (its thinking and its
unfinished text are not logged or resent), logs the message as `user` and
calls the model again with it, after the running tool's result when there is
one. The acpmux engine waits until no tool call of the turn is running
(Claude Code's interrupt would abort it), then sends `session/cancel`, again
every second until the turn ends (a cancel that reaches acpmux before the
prompt is lost); the next fresh turn answers with the view of everything the
stopped turn did. That turn waits for settle like any turn: section 6 (no
call sees an unsummarized line) makes it wait until the stopped turn's steps
and the new message have their level-0 lines, usually a few node builds.
Text the stopped turn had streamed before the interrupt is logged as `talk`
on the acpmux engine (acpmux does not say whether a reply was finished) and
dropped on the native engine. MASTER says this instead of "reach you between
tool calls".

## Run it with a tagged cmux-next build

1. Build the macOS binary on a fleet Mac (cargo never runs on the laptop):

   ```bash
   nx-remote --host cmux-mini-6 --xcode 26.6 --worktree "$PWD" --cwd experiments/chief-optmem/optchat-chief \
     --fetch experiments/chief-optmem/optchat-chief/target/release/optchat-chief \
     -- bash -c "umask 022; OPTCHAT_BUILD_COMMIT=$(git rev-parse --short HEAD) cargo build --release"
   ```

   Copy the fetched file to `experiments/chief-optmem/optchat-chief/dist/optchat-chief` (gitignored).
   Build with `OPTCHAT_BUILD_COMMIT=$(git rev-parse --short HEAD)` in the
   command's environment: the host's first log line names the build, so a
   dogfood run shows which code it runs. Rebuild before every dogfood run.

2. Start the tagged app with `CMUX_NEXT_MUX_HOST` naming that file, in the
   app's own environment (launch its executable from a shell with the
   variable set, or `launchctl setenv CMUX_NEXT_MUX_HOST /abs/path/optchat-chief`
   before `open`). The app starts the host when Home first opens, as
   `optchat-chief host --daemon-socket <daemon socket> --mux-home ~/.cmux/mux/tags/<tag>`,
   with `MUX_AGENT_TOKEN_FILE`, `CMUX_SOCKET_PATH`, `ACPMUX_*`, `MUX_HARNESS`
   and `CMUX_MCP_COMMAND` set. Its stderr goes to `$MUX_HOME/host.log`.

3. Open Home and write in the Chief conversation. The reply shows as the
   `mux` participant (the conversation is the same one mux/host creates).

Only one brain host runs per `MUX_HOME`: this host takes the same kernel lock
as `mux/host` and the P1 Rust Chief (`$MUX_HOME/state/host.lock`), so a second
launch exits 0. Stop a running `mux/host` for that home first.

## Commands

```
optchat-chief host --daemon-socket PATH [--mux-home DIR]   the brain host (one per MUX_HOME)
optchat-chief mcp [--socket PATH | --mux-home DIR]           stdio MCP server: zoom, date
optchat-chief agents spawn --name N --cwd DIR [--harness H] [--policy P] "task"
optchat-chief agents list | prompt NAME "text" | allow NAME [OPTION_ID] | deny NAME
optchat-chief browse [--mux-home DIR] [--out FILE]          the whole memory as one HTML page
optchat-chief import [--mux-home DIR] FILE                  JSON lines {"text", "kind"?}, default note (host stopped)
```

Inside a turn the Chief runs `chief agents ...` (a launcher in
`$MUX_HOME/optchat/bin`, first on the turn's PATH). A child's final reply of
each turn comes back as one message `[<name>] <report>`, which starts a new
turn when the Chief is idle.

## Environment

| variable | default | meaning |
| --- | --- | --- |
| `CMUX_DAEMON_SOCKET` | (`--daemon-socket`) | the session daemon (local-conversations-v1) |
| `MUX_HOME` | `~/.cmux/mux` (`--mux-home`) | where everything lives |
| `MUX_AGENT_TOKEN_FILE` | required (exit 2 without) | the app's agent_mux token |
| `OPTCHAT_CHIEF_ENGINE` | `acpmux` | `acpmux` or `native` (Messages API loop in the host) |
| `OPTCHAT_CHIEF_MODEL` | `claude-opus-5-5` (native), harness default (acpmux) | the turn model |
| `OPTCHAT_CHIEF_EFFORT` | `high` | native: `output_config.effort` |
| `OPTCHAT_CHIEF_SERVER_FALLBACK` | off | native: `1` sends `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) |
| `MUX_HARNESS` | `claude-sr` | acpmux: harness of each turn session (and children's default) |
| `MUX_POLICY` | `approve-all` | acpmux: permission policy of each turn session |
| `ACPMUX_SOCKET`, `ACPMUX_HOME` | `~/.acpmux/acpmux.sock` | the acpmux daemon |
| `ACPMUX_BIN` | none | started as `$ACPMUX_BIN daemon run` when the socket does not answer |
| `CMUX_SOCKET_PATH` | none | the app's control socket, passed to the turn's tools |
| `CMUX_MCP_COMMAND` | none | cmux binary whose `mcp serve` is added as MCP server `cmux` |
| `OPTCHAT_ANTHROPIC_BASE_URL` | `http://cmux-lawrences-mac-mini:31415` | the Messages API of the native engine, and of the compactor's `api` route (team subrouter) |
| `OPTCHAT_ANTHROPIC_API_KEY` | none | `x-api-key`; else `ANTHROPIC_API_KEY` for any base URL but the subrouter; else `subrouter` |
| `OPTCHAT_COMPACTOR` | `acpmux` on the subrouter or without a key, else `api` | how summaries are built (see Compactor routes) |
| `OPTCHAT_COMPACTOR_HARNESS` | `claude-sr` | acpmux route: the harness of the compactor sessions |
| `OPTCHAT_COMPACTOR_MODEL` | `claude-sonnet-5-5` | acpmux route: their model (the refusal fallback stays `claude-sonnet-5`) |
| `OPTCHAT_CHIEF_ISOLATE` | `1` | `0` runs turns with the user's own Claude Code configuration; it never changes the compactor's isolation |
| `OPTCHAT_CHIEF_TURN_LIMIT_MIN` | `180` | a turn longer than this is stopped and says so (`0`: no limit) |

## Files

```
$MUX_HOME/state/host.lock         kernel lock shared with mux/host ("<pid>\n<start ms>\nflock\n")
$MUX_HOME/optchat/chat/           the OptChat memory: main/YYYY-MM-DD.jsonl, tree/YYYY-MM-DD.jsonl, lock;
                                  a git repository, committed after every turn (section 10)
$MUX_HOME/optchat/AGENTS.md       the user's own instructions, the end of the system prompt (read at host start)
$MUX_HOME/optchat/memory.html     `optchat-chief browse` output
$MUX_HOME/optchat/host.json       outbox, logged seq, pending turn, children
$MUX_HOME/optchat/tools.sock      the live memory for `optchat-chief mcp`
$MUX_HOME/optchat/session/        every turn's cwd: CLAUDE.md, .mcp.json, .claude/settings*.json
$MUX_HOME/optchat/bin/chief       launcher for `chief agents ...`
$MUX_HOME/optchat/claude/         the turn sessions' CLAUDE_CONFIG_DIR (settings.json: no auto-memory, no hooks,
                                  transcripts kept 2 days)
$MUX_HOME/optchat/compactor-claude/  the compactor sessions' own CLAUDE_CONFIG_DIR (0700; same settings as below;
                                  unused on claude-sr, which resets CLAUDE_CONFIG_DIR)
$TMPDIR/optchat-compact-<home id>/slot-<k>/  the compactor sessions' working directories (0700), one per slot: only
                                  .claude/settings.json (every tool denied, all hooks off, no auto-memory,
                                  no bundled skills, transcripts kept 1 day)
```

`$MUX_HOME/optchat/` is mode 0700 and the log, tree and host.json are 0600:
the memory keeps everything the user pasted.

The system prompt (and the acpmux session's `CLAUDE.md`) is the spec's MASTER
and VIEW_DOC (agent renamed "Chief"), a short cmux section, then
`$MUX_HOME/optchat/AGENTS.md` when it exists. The files
this host writes (CLAUDE.md, the MCP tool list, the settings) are
byte-identical across turns. The request the model gets is not fully ours:

- Turn sessions start through an acpmux preset (`optchat-chief-<home id>`,
  saved in acpmux's config) whose env sets `CLAUDE_CONFIG_DIR` to
  `optchat/claude` and turns auto-memory off, so the user's
  `~/.claude/CLAUDE.md`, settings, hooks and project memory never reach a
  turn and MASTER's "instructions at the end of this prompt" holds, except
  on claude-sr, which resets `CLAUDE_CONFIG_DIR` (see Compactor routes). When
  acpmux refuses the preset, turns still start (with the harness's own
  configuration) and host.log says so; compactor sessions never do.
  Claude Code keeps each turn's transcript (the whole view) for 2 days
  (`cleanupPeriodDays`, minimum 1, set in both the isolated configuration
  and the session directory's project settings); on claude-sr the
  transcripts are under `~/.claude/projects/`, and whether a project-level
  `cleanupPeriodDays` governs that sweep is not checked.
- Claude Code's own system prompt still comes first, with its date and
  environment lines, so the cached prefix changes at least once a day.
  Machine-wide managed settings still apply.

## Compactor routes

The team subrouter serves Claude Code clients: a raw Messages API call for a
Claude model gets `429 rate_limit_error` every time (checked live on
2026-10-04), so a compactor that calls the API there builds no node that
needs a model, and every turn then waits on settle forever. The host picks
the route at start (`OPTCHAT_COMPACTOR` overrides):

- `acpmux` (default on the subrouter, or when no real key is configured):
  each node is built in its own acpmux session of `OPTCHAT_COMPACTOR_HARNESS`
  (claude-sr), as `mux/host/src/compactor.ts` does. The session runs with the
  `deny-all` policy and the compactor's own acpmux preset
  (`optchat-compact-<home id>`), which it requires: when acpmux refuses the
  preset, no compactor session starts (nodes fail and are retried, and the
  probe says why), so a node never runs with the user's `~/.claude` hooks,
  MCP servers or auto-memory. The preset sets `CLAUDE_CONFIG_DIR` to
  `optchat/compactor-claude` (not the turn agent's) and turns off
  auto-memory, CLAUDE.md files, bundled skills and Claude Code's own refusal
  fallback. The cwd is a slot directory under the system temporary
  directory, outside any directory with instruction files, whose
  `.claude/settings.json` denies every built-in tool (the interactive ones
  included; a denied tool leaves the model's tool list), disables all hooks
  and auto-memory. The first prompt
  is the compactor's system text, the context pieces and the step; each
  size-loop retry is the next prompt in the same session; the reply text is
  the line, with a lead-in line ("Here is the line:") dropped. When the node
  is built or fails, the session is killed with purge and Claude Code's
  transcript of it is deleted, and host.log gets one line with the node's
  seconds, prompts and token use (`compactor node <id> (<model>): 9.8 s, 1
  prompt(s), uncached .. cache write .. cache read .. output .., $..`). At
  most JOBS (8) compactor sessions live at once, main and fallback model
  together. Nothing pretends to be Claude Code and no API key is involved:
  the harness signs in as it always does.
- `api`: the Messages API at `OPTCHAT_ANTHROPIC_BASE_URL` with
  `OPTCHAT_ANTHROPIC_API_KEY` (or `ANTHROPIC_API_KEY` off the subrouter),
  for an endpoint that takes API calls.

At start the host builds one probe node through the chosen route, with the
main model and then the refusal fallback model, and on the acpmux route
checks that the session's Claude Code offers no tool and no MCP server (its
`system/init`, which acpmux records). When any of that fails (acpmux down,
the harness not signed in, a 429, an unserved fallback model, a tool left
on), host.log gets one `The memory compactor cannot build summaries ...`
line and the Chief conversation gets the same text once, instead of a
silent wait later.
Checked live on 2026-10-04 on cmux-lawrence-2 against a private acpmux
daemon (claude-sr, Claude Code 2.1.287, `claude-sonnet-5-5`), with
`cargo test --release --test live the_acpmux_compactor -- --ignored`:

| call | seconds | uncached | cache write | cache read | output | cost |
| --- | --- | --- | --- | --- | --- | --- |
| probe (empty view) | 1.6 | 2 | 2,442 | 0 | 28 | $0.006 |
| one node, full-size view (127 KB) | 3.7 | 2 | 48,080 | 1,175 | 124 | $0.122 |
| a 120-line message (empty view) | 2.4 | 2 | 5,766 | 1,175 | 86 | $0.016 |

The probe's isolation check passed (no tool, no MCP server), and no
compactor transcript was left in either Claude home. Before the deny list
moved into each slot's project settings, the same probe offered 26 tools
and cost 37,436 cache-write tokens.

**Cost.** A node pays for its whole view at the cache-write price: about
48k tokens and $0.12 at full size, and about 4 s, of which about 1.5 s is
the harness start. Nothing carries the view from one node to the next
(only Claude Code's own 1.2k-token prefix is read back). Summaries run at
roughly 1.2 nodes per message, so a full memory costs roughly $0.15 per
message in compactor calls, $150 a day at 1,000 messages; level-0 nodes run
one at a time (rule 3), so a burst of tool steps can keep the next turn
waiting by about 4 s per step. The spec's layout (section 8) would read
most of each view from the cache; that needs the `api` route with a key on
an endpoint that takes API calls, or acpmux forwarding `cache_control`.

**claude-sr resets `CLAUDE_CONFIG_DIR`.** `sr claude proxy` points Claude
Code at the user's `~/.claude` whatever the session's env says (checked
live: transcripts land in `~/.claude/projects/`, and deny rules in the
preset's configuration are not applied). So on claude-sr the isolation
presets change little: what isolates a session is its cwd's project
settings (applied, checked live) and the env flags that sr passes through
(not checked one by one). Compactor sessions therefore get their deny list,
`disableAllHooks` and no auto-memory as project settings in each slot
directory, `end` deletes the transcript from `~/.claude/projects/` too, and
the probe's tool and MCP check is the guard. Turn sessions get the same
three switches and the transcript retention in their project settings, but
the user's `~/.claude/CLAUDE.md` and MCP servers can still reach a turn on
claude-sr. The isolated configurations work as described for a harness
that keeps `CLAUDE_CONFIG_DIR`.

The native engine still needs an endpoint that takes API calls; through the
subrouter it gets the same 429 (`--test live two_native_turns` repeats it).

## Deviations from the spec

- **acpmux engine only: cache breakpoints in the view (section 8).** acpmux's
  Claude Code path forwards text blocks without `cache_control`, so a turn
  rewrites the view in the cache. The native engine places them. Each turn
  logs `turn <key> cache: first request read .. written .. uncached ..` to
  host.log either way; the first request's numbers show what crossed turns.
- **Messages during a turn (section 7, MASTER).** The spec delivers them at
  the next tool boundary; here a human message interrupts at once (see the
  top of this file), and MASTER's line says so. On the acpmux engine the
  interrupted turn ends and a fresh one starts. Children's reports do not
  interrupt: the native engine delivers them between tool calls, the acpmux
  engine at the next turn. The brain-host contract has no user cancel, so
  neither engine can cancel a turn or the compactor wait on request; a turn
  past its limit is stopped.
- **Native engine: the bash tool.** Each command is its own `bash -c` (so a
  timeout kills all it started); the working directory carries over between
  commands, shell variables and exports do not. Tools are approve-all, like
  the acpmux engine's default policy; the text editor is not confined to a
  root. No MCP servers: the `cmux` CLI and `chief agents` run from bash.
- **Native engine: refusals.** A refused turn says so. Server-side
  `fallbacks: "default"` is off by default (`OPTCHAT_CHIEF_SERVER_FALLBACK`):
  the team subrouter may not forward its beta header.
- **Compactor through acpmux (section 4.2, 8).** Claude Code's own system
  prompt (with its date and environment lines) comes first, and the
  compactor's system text is the first block of the user prompt instead of
  the API `system` field. acpmux forwards text blocks without
  `cache_control`, so the context pieces keep the spec's order and cut
  points but carry no breakpoints. Claude Code puts its own breakpoint at
  the end of the prompt, so a node writes its whole prompt (system text,
  view, step) to the cache and the next node, whose step differs, reads
  none of that view back: each node pays for its whole view at the cache
  write price, where the spec's layout would read most of it at the cache
  read price. Measured live, see Cost above. Each node also pays a harness start.
  No effort is sent (the harness default) until acpmux's `effort` option is
  checked live; the `api` route still sends `medium`. Size-loop retries
  stay in the same session, so the earlier reply (thinking included) stays
  in the harness's context, as section 8 wants, though the host never sees
  the blocks.
- **Huge messages (section 4.2, rule 3).** The spec sends a message whole to
  its compactor call; a paste or tool input larger than the model's context
  fails that node on every try, and rule 3 then blocks every later level-0
  node and every turn. A message longer than `STEP_MESSAGE` (200,000
  characters) shows only its first and last 100,000 characters in that one
  call (the log keeps it whole, and `zoom(id, 1)` returns it whole), and its
  line starts with `(cut: N of M characters unread) `, which the host adds.
  The model is told its reduced room (512 bytes less the prefix), and the
  size loop measures its reply against that room, so the finished line fits
  in 512 bytes like any other; only after five tries does the shortest
  reply win, as for every node. The limit counts characters, so a cut CJK
  message can still be large in tokens (about 200k characters stays inside
  the context of the compactor models in practice, but is not checked). The
  WebAssembly build exports the cut: `compactRequest` returns `cut` and
  `room`, `sizeCheck(tries, room)` measures against the room, and
  `finishLine(cut, line)` adds the prefix.
- **Compactor refusals (section 4.1).** A node the compactor model declines
  is built by `claude-sonnet-5` (fewer safeguard categories) instead of
  being retried forever. On the acpmux route a refusal arrives as acpmux
  sends it: a JSON-RPC error (code -32603) whose message is Claude Code's
  refusal text, which always links `anthropic.com/legal/aup`; a usage limit
  or an overload is not a refusal and is retried. Other failures retry every 10 s forever, as the spec
  says; after a minute of waiting the conversation hears which line fails.
- **Subagents (section 9).** Children get no view and no subagent system
  prompt; each reports alone, one `[name] reply` per ended turn; `prompt` is a
  queued new turn, not a delivery between tool calls; only the Chief
  conversation is read. With the native engine, children's reports are
  delivered between the Chief's tool calls like human messages.
- **What the user sees (section 7, "show it").** Home gets each turn's last
  reply only; earlier replies and tool steps are in the memory (and in
  `browse`), not posted.
- **Reply keys.** `turn:optchat:<first id>:<its stamp>`: the stamp keeps keys
  unique after a memory reset or a restored backup.

## Tests

Run them on a Blacksmith Testbox (`skills/blacksmith-testbox/SKILL.md` in a
cmux checkout), in each of optchat-core, optchat-host and optchat-chief:

```bash
umask 022; cargo test --release; cargo clippy --release --all-targets -- -D warnings; cargo fmt --check
```

`tests/brain.rs` runs the brain against in-process fakes of both owners;
`tests/compactor.rs` runs the acpmux compactor route against the fake acpmux
port (one session per node, size loop in it, purge and transcript deletion,
one JOBS gate across main and fallback, refusals as acpmux sends them, the
probe's fallback and isolation checks, per-node token lines, route choice,
the start-up notice); `tests/audit3.rs` covers interrupts on the acpmux
engine and home-scoped turn names, `tests/native.rs` interrupts on the
native engine;
`tests/acpmux_wire.rs` and `tests/daemon_wire.rs` run the real clients against
fake servers on Unix sockets; `tests/lock.rs` runs the binary against a held
lock; `tests/mcp.rs` runs `optchat-chief mcp` against a live test memory.
