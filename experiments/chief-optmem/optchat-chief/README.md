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
  output resent verbatim, tool results capped at CAP, and messages sent
  during a turn delivered between tool calls (as MASTER says).
- `acpmux` (default): a fresh acpmux session per turn (`MUX_HARNESS`, default
  claude-sr). Claude Code's own breakpoints never land in the view, so each
  turn rewrites the view in the cache, and claude-sr takes no message
  mid-run: a human message stops the running turn (`session/cancel`) and
  the next fresh turn answers with the view of everything the stopped turn
  did. Claude Code's Task/Agent subagents are denied (their steps would be
  logged as the Chief's); `chief agents` starts agents instead.

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
| `OPTCHAT_CHIEF_ISOLATE` | `1` | `0` runs turns with the user's own Claude Code configuration |
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
$MUX_HOME/optchat/claude/         the turn and compactor sessions' CLAUDE_CONFIG_DIR (settings.json: no auto-memory, no hooks)
$MUX_HOME/optchat/compactor/      the compactor sessions' cwd (0700): only .claude/settings.json, which denies every tool
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
  turn and MASTER's "instructions at the end of this prompt" holds. Unverified
  end to end: that `claude-sr` signs in with an empty config directory.
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
  `deny-all` policy, no tools (denied in its cwd's project settings), cwd
  `$MUX_HOME/optchat/compactor`, and the turn sessions' isolation preset
  (`CLAUDE_CONFIG_DIR`, no auto-memory). The first prompt is the compactor's
  system text, the context pieces and the step; each size-loop retry is the
  next prompt in the same session; the reply text is the line. The session
  is killed with purge when the node is built or fails. At most JOBS (8)
  compactor sessions live at once. Nothing pretends to be Claude Code and no
  API key is involved: the harness signs in as it always does.
- `api`: the Messages API at `OPTCHAT_ANTHROPIC_BASE_URL` with
  `OPTCHAT_ANTHROPIC_API_KEY` (or `ANTHROPIC_API_KEY` off the subrouter),
  for an endpoint that takes API calls.

At start the host builds one probe node through the chosen route. When that
fails (acpmux down, the harness not signed in, a 429), host.log gets one
`The memory compactor cannot build summaries ...` line and the Chief
conversation gets the same text once, instead of a silent wait later.
Checked live on 2026-10-04 on the build host against a private acpmux daemon
with claude-sr and the isolation preset: the probe took 2.4 s and a
120-line message's summary 3.1 s
(`cargo test --release --test live the_acpmux_compactor -- --ignored`).

The native engine still needs an endpoint that takes API calls; through the
subrouter it gets the same 429 (`--test live two_native_turns` repeats it).

## Deviations from the spec

- **acpmux engine only: cache breakpoints in the view (section 8).** acpmux's
  Claude Code path forwards text blocks without `cache_control`, so a turn
  rewrites the view in the cache. The native engine places them. Each turn
  logs `turn <key> cache: first request read .. written .. uncached ..` to
  host.log either way; the first request's numbers show what crossed turns.
- **acpmux engine only: messages during a turn (section 7).** A human
  message stops the running turn and starts a fresh one, instead of reaching
  it between tool calls. Children's reports wait for the next turn. The
  brain-host contract has no user cancel, so neither engine can cancel a
  turn or the compactor wait on request; a turn past its limit is stopped.
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
  points but carry no breakpoints: a node reads only what Claude Code's own
  caching gives it. Each node pays a harness start (about 2 s). The
  `medium` effort goes to the harness as acpmux's `effort` option; that
  option was not part of the live check. Size-loop retries stay in the same
  session, so the earlier reply (thinking included) stays in the harness's
  context, as section 8 wants, though the host never sees the blocks.
- **Huge messages (section 4.2, rule 3).** The spec sends a message whole to
  its compactor call; a paste or tool input larger than the model's context
  fails that node on every try, and rule 3 then blocks every later level-0
  node and every turn. A message longer than `STEP_MESSAGE` (200,000
  characters) shows only its first and last 100,000 characters in that one
  call (the log keeps it whole, and `zoom(id, 1)` returns it whole), and its
  line starts with `(cut: N of M characters unread) `, which the host adds
  (the model is told to leave room for it, so the line can pass 512 bytes by
  that prefix when the model uses all its room). The WebAssembly build has
  the cut and the instruction but not the added prefix.
- **Compactor refusals (section 4.1).** A node the compactor model declines
  is built by `claude-sonnet-5` (fewer safeguard categories) instead of
  being retried forever. Other failures retry every 10 s forever, as the spec
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
port (one session per node, size loop in it, purge, JOBS cap, route choice,
the start-up notice);
`tests/acpmux_wire.rs` and `tests/daemon_wire.rs` run the real clients against
fake servers on Unix sockets; `tests/lock.rs` runs the binary against a held
lock; `tests/mcp.rs` runs `optchat-chief mcp` against a live test memory.
