# optchat-chief

An OptChat Chief for cmux-next Home. It keeps the brain-host contract of
`mux/host` (so the app needs no changes) and replaces the long-lived `mux`
acpmux session with the turn loop of Victor Taelin's OptChat spec: every human
message is logged into one endless OptChat memory, and every turn is a fresh
acpmux session that reads the memory's view (about 128 KB of one-line
summaries of the whole chat) plus the new messages. The compactor that builds
the summaries runs inside the host on the team subrouter.

## Run it with a tagged cmux-next build

1. Build the binary on the build host (cargo never runs on the laptop):

   ```bash
   nx-remote --worktree "$PWD" --cwd experiments/chief-optmem/optchat-chief \
     --fetch experiments/chief-optmem/optchat-chief/target/release/optchat-chief \
     -- bash -c 'umask 022; cargo build --release'
   ```

   Copy the fetched file to `experiments/chief-optmem/optchat-chief/dist/optchat-chief` (gitignored).

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
| `MUX_HARNESS` | `claude-sr` | harness of each turn session |
| `MUX_POLICY` | `approve-all` | permission policy of each turn session |
| `OPTCHAT_CHIEF_MODEL` | harness default | model of each turn session |
| `ACPMUX_SOCKET`, `ACPMUX_HOME` | `~/.acpmux/acpmux.sock` | the acpmux daemon |
| `ACPMUX_BIN` | none | started as `$ACPMUX_BIN daemon run` when the socket does not answer |
| `CMUX_SOCKET_PATH` | none | the app's control socket, passed to the turn's tools |
| `CMUX_MCP_COMMAND` | none | cmux binary whose `mcp serve` is added as MCP server `cmux` |
| `OPTCHAT_ANTHROPIC_BASE_URL` | `http://cmux-lawrences-mac-mini:31415` | the compactor's Messages API (team subrouter) |
| `OPTCHAT_CHIEF_ISOLATE` | `1` | `0` runs turns with the user's own Claude Code configuration |
| `OPTCHAT_CHIEF_TURN_LIMIT_MIN` | `180` | a turn longer than this is stopped and says so (`0`: no limit) |

## Files

```
$MUX_HOME/state/host.lock         kernel lock shared with mux/host ("<pid>\n<start ms>\nflock\n")
$MUX_HOME/optchat/chat/           the OptChat memory: main/YYYY-MM-DD.jsonl, tree/YYYY-MM-DD.jsonl, lock
$MUX_HOME/optchat/host.json       outbox, logged seq, pending turn, children
$MUX_HOME/optchat/tools.sock      the live memory for `optchat-chief mcp`
$MUX_HOME/optchat/session/        every turn's cwd: CLAUDE.md, .mcp.json, .claude/settings*.json
$MUX_HOME/optchat/bin/chief       launcher for `chief agents ...`
$MUX_HOME/optchat/claude/         the turn sessions' CLAUDE_CONFIG_DIR (settings.json: no auto-memory, no hooks)
```

`$MUX_HOME/optchat/` is mode 0700 and the log, tree and host.json are 0600:
the memory keeps everything the user pasted.

`CLAUDE.md` is the spec's MASTER and VIEW_DOC (agent renamed "Chief") and a
short cmux section in the place of the user's instructions file. The files
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

## Deviations from the spec

- **Cache breakpoints in the view (section 8).** The view is sent as up to
  four text blocks cut at the marks, but acpmux's Claude Code path forwards
  text blocks without `cache_control` and Claude Code places its own
  breakpoints, never inside the view. So a turn does not read the unchanged
  start of the view that the previous turn sent; it writes it again. Each
  turn logs `turn <key> cache: first request read .. written .. uncached ..`
  to host.log; the first request's numbers show what crossed turns. A fix
  needs block-level `cache_control` in acpmux or the host's own Messages API
  agent loop (section 9 allows one).
- **Messages during a turn (section 7).** claude-sr reports no steering, so a
  message sent while a turn runs waits for the next turn, although MASTER
  (verbatim) says it arrives between tool calls. The user cannot cancel a
  turn or the wait for the compactor; a turn past its limit is stopped.
- **Compactor refusals (section 4.1).** A node the compactor model declines
  is built by `claude-sonnet-5` (fewer safeguard categories) instead of
  being retried forever. Other failures retry every 10 s forever, as the spec
  says; after a minute of waiting the conversation hears which line fails.
- **Subagents (section 9).** Children get no view and no subagent system
  prompt; each reports alone, one `[name] reply` per ended turn; `prompt` is a
  queued new turn, not a delivery between tool calls; only the Chief
  conversation is read.
- **Reply keys.** `turn:optchat:<first id>:<its stamp>`: the stamp keeps keys
  unique after a memory reset or a restored backup.

## Tests

```bash
nx-remote --worktree "$PWD" --cwd experiments/chief-optmem/optchat-chief \
  -- bash -c 'umask 022; cargo test --release; cargo clippy --release --all-targets -- -D warnings'
```

`tests/brain.rs` runs the brain against in-process fakes of both owners;
`tests/acpmux_wire.rs` and `tests/daemon_wire.rs` run the real clients against
fake servers on Unix sockets; `tests/lock.rs` runs the binary against a held
lock; `tests/mcp.rs` runs `optchat-chief mcp` against a live test memory.
