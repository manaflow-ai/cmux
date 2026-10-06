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
- `acpmux` (default): the Chief on local ACP only. Each turn is a fresh
  acpmux session of the Chief's harness, named `optchat-<home id>-<first
  id>`, and each summary is one too (see [Harnesses and cache
  layout](#harnesses-and-cache-layout)); no Messages API is called. The
  harness is one setting (`OPTCHAT_CHIEF_HARNESS`): claude-sr by default
  (acpmux's own Claude Code ACP adapter, `claude_stdio`, launched through
  the team subrouter's account pool), codex, or any acpmux harness.
  Claude Code's Task/Agent subagents are denied (their steps would be
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
optchat-chief import [--mux-home DIR] FILE                  JSON lines {"text", "kind"?, "date"?}, default note, date RFC 3339 (host stopped)
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
| `OPTCHAT_CHIEF_EFFORT` | `medium` (Taelin runs Opus 5.5 at medium); acpmux: only on a Claude or codex harness | the turn effort: native `output_config.effort`, acpmux `effort` of each turn session |
| `OPTCHAT_CHIEF_SERVER_FALLBACK` | off | native: `1` sends `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) |
| `OPTCHAT_CHIEF_HARNESS` | `MUX_HARNESS`, else `claude-sr` | acpmux: the harness of each turn session, and of the compactor unless `OPTCHAT_COMPACTOR_HARNESS` names another |
| `MUX_HARNESS` | `claude-sr` | acpmux: the children's default harness, and the turn harness when `OPTCHAT_CHIEF_HARNESS` is unset |
| `MUX_POLICY` | `approve-all` | acpmux: permission policy of each turn session |
| `ACPMUX_SOCKET`, `ACPMUX_HOME` | `~/.acpmux/acpmux.sock` | the acpmux daemon |
| `ACPMUX_BIN` | none | started as `$ACPMUX_BIN daemon run` when the socket does not answer |
| `CMUX_SOCKET_PATH` | none | the app's control socket, passed to the turn's tools |
| `CMUX_MCP_COMMAND` | none | cmux binary whose `mcp serve` is added as MCP server `cmux` |
| `OPTCHAT_ANTHROPIC_BASE_URL` | `http://cmux-lawrences-mac-mini:31415` | the Messages API of the native engine, and of the compactor's `api` route (team subrouter) |
| `OPTCHAT_ANTHROPIC_API_KEY` | none | `x-api-key`; else `ANTHROPIC_API_KEY` for any base URL but the subrouter; else `subrouter` |
| `OPTCHAT_COMPACTOR` | `acpmux` | how summaries are built; `api` only when set (see Compactor routes) |
| `OPTCHAT_COMPACTOR_HARNESS` | the Chief's harness | acpmux route: the harness of the compactor sessions |
| `OPTCHAT_COMPACTOR_MODEL` | `claude-sonnet-5-5` on a Claude harness, else the harness's default | acpmux route: their model (the refusal fallback `claude-sonnet-5` exists on a Claude harness only) |
| `OPTCHAT_COMPACTOR_EFFORT` | `medium` on a Claude or codex harness, else the harness's default | acpmux route: acpmux `effort` of the compactor sessions (section 4.2 runs the compactor at medium) |
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
$MUX_HOME/optchat/session/        every turn's cwd: CLAUDE.md (Claude harness, old layout only) or AGENTS.md
                                  (any other harness), .mcp.json, .claude/settings*.json
$MUX_HOME/optchat/bin/chief       launcher for `chief agents ...`
$MUX_HOME/optchat/claude/         the turn sessions' CLAUDE_CONFIG_DIR (settings.json: no auto-memory, no hooks,
                                  transcripts kept 2 days)
$MUX_HOME/optchat/compactor-claude/  the compactor sessions' own CLAUDE_CONFIG_DIR (0700; same settings as below;
                                  unused on claude-sr, which resets CLAUDE_CONFIG_DIR)
$MUX_HOME/optchat/compactor-codex/slot-<k>/  a codex compactor slot's own CODEX_HOME (0700): only config.toml
                                  (the user's routing and model keys, plus no AGENTS.md, skills, apps,
                                  plugins, memories, hooks or history); emptied but for it around every node
$TMPDIR/optchat-compact-<home id>/slot-<k>/  the compactor sessions' working directories (0700), one per slot
                                  on a Claude harness (`shared/` for any other): .claude/settings.json (every
                                  tool denied, all hooks off, no auto-memory, no bundled skills, transcripts
                                  kept 1 day)
<acpmux state>/presets/<preset>/system.md  acpmux's own copy of a preset's systemPrompt (0400 in a 0700
                                  directory; acpmux checks its sha256 at every session start): the turn
                                  preset holds the system text and the view up to 50k, each compactor slot
                                  preset its node's (emptied when the node ends)
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

## Harnesses and cache layout

The Chief runs purely on local ACP: turns and summaries are acpmux
sessions, and the harness is one setting, `OPTCHAT_CHIEF_HARNESS` (the
Chief record in the app can carry the same value later). The default,
claude-sr, is acpmux's own Claude Code adapter (`cmux-tui/crates/acpmux/src/claude_stdio`,
first-party since 2026-09-17; it drives `claude -p` over stream-json and
`sr claude proxy` gives it the subrouter's account pool). The compactor
follows the Chief's harness unless `OPTCHAT_COMPACTOR_HARNESS` says
otherwise. Changing the value needs no code change; each family gets the
layout its cache needs. The family is what acpmux says the harness is
(`_acpmux/harnesses`: a declared `family`, else the harness kind and
command, so `claude-stdio` or a `claude` command is Claude and a
`codex-acp` command is codex), read once at host start; a harness's name
decides nothing. The host stops with a host.log line when acpmux cannot
answer (except the native engine with the API compactor, which needs no
acpmux):

| harness | turn layout | node layout | cache mechanism | measured (2026-10-04, cmux-lawrence-2) |
| --- | --- | --- | --- | --- |
| Claude family (claude, claude-sr) | turn preset `systemPrompt` = system text + view up to 50k; prompt = rest of the view, ONE `cache_control` marker on the piece ending at the last mark, then the new messages; no CLAUDE.md | slot preset `systemPrompt` = compactor system text + context up to 50k; rest of the context with one marker; then the step | Claude Code's own breakpoints (system prompt, last messages) plus ours; the replaced system prompt drops Claude Code's date and cwd lines | turns: 2nd turn read 64,893 / wrote 11,085 (85% read); nodes: 2nd node read 37,671 / wrote 10,442 (78%), $0.121 then $0.035 |
| codex family | view pieces first, new messages last, no marker; instructions in the session directory's AGENTS.md; memory tools as `chief zoom` / `chief date` | system text, context pieces, step; all nodes in one shared cwd | OpenAI automatic prefix caching (1024-token blocks), routed by `prompt_cache_key`: `optchat-<home id>-turn` for turns, `optchat-<home id>-compact` for nodes (needs the cmux codex fork) | upstream key (thread id): 2nd turn read 12,032 of 56,632 (21%), 2nd node 12,032 of 48,653 (25%). Fork with the Chief's keys (2026-10-04, see Codex): 2nd turn read 56,064 of ~56,630 (99%) in 6 of 8 runs; 2nd node 44,800 of 45,662 (98%) in 3 of 5 |
| any other acpmux harness | as codex | as codex | whatever the harness does with a byte-stable prefix | not measured |

Every turn logs `turn <key> cache: first request read .. written ..
uncached ..; turn total|last request ...` to host.log (Claude Code reports
the turn's total and its first request; codex-acp reports the turn's last
request), and every node `compactor node <id> (<harness>, <model>): ..,
uncached .. cache write .. cache read .. output ..`. The live check is
`OPTCHAT_CHIEF_HARNESS=<h> cargo test --release --test live
two_turns_and_two_nodes_through_local_acp -- --ignored --nocapture` against
a private acpmux daemon built from `feat-cache-control-preset-args`
(measured at e2715f27657): two consecutive turns over a 120 KB view (marks
49,983 / 79,975 / 99,919) and two consecutive nodes over a 127 KB context,
the turns on the harness's default model, the Claude nodes on
`claude-sonnet-5-5`.

**Claude.** acpmux takes a preset's system prompt as text
(`systemPrompt`), writes it into its own preset directory, records its
sha256 and checks it at every session start, and passes
`--system-prompt-file` itself; preset `args` are an allowlist that can only
take capabilities away (`--tools ""`, `--strict-mcp-config`,
`--no-session-persistence`). A turn sets the turn preset's prompt just
before its session starts (turns run one at a time); each compactor slot
has its own preset (`optchat-compact-<home id>-slot-<k>`), so concurrent
nodes never race on one prompt. The prompt changes only when the view
before the 50k mark changes (a merge of old lines), so consecutive turns
send byte-identical system prompts. A 4-breakpoint refusal (`A maximum of 4
blocks with cache_control`) reruns the turn once without the marker, and
later turns skip it. An acpmux without `systemPrompt` keeps the old layout
(no marker, CLAUDE.md, host.log says so).

**Codex.** Its request is `instructions`, the tool list, the permission and
environment messages (cwd, shell, date), AGENTS.md, then our blocks, so
the prefix is byte-stable up to the first changed view line except once a
day (the date). Upstream codex sets `prompt_cache_key` to the thread id
(`codex-rs/core/src/client.rs`), and acpmux starts a fresh thread per
turn and per node, so every request had a new key: the measured 12,032
cached tokens were codex's own instructions and tools, and the view was
never read back. The cmux codex fork (manaflow-ai/codex
`feat/prompt-cache-key-override`) sends `CODEX_PROMPT_CACHE_KEY` (or
`prompt_cache_key` in config.toml) instead; the turn preset sets
`optchat-<home id>-turn` and every compactor slot preset
`optchat-<home id>-compact` through env only (the preset args allowlist
is unchanged). Upstream codex ignores the env, so the layout still works
there, without the reads. Measured on cmux-lawrence-2 (fork build
d73c9c33c6, acpmux e2715f27657, subrouter, `OPTCHAT_LIVE_CODEX_PATH`;
`OPTCHAT_LIVE_NO_CACHE_KEY=1` drops the keys): with keys the 2nd turn read
56,064 tokens in 6 of 8 runs (the misses read 0 and 12,032), and the 2nd
node read 44,800 in 3 of 5 (the misses read 9,984, codex's instructions
only). Without keys, the 2nd turn read 56,064 in 1 of 6 runs (otherwise 0
or 12,032), and the 2nd node never read more than 10,752 in 5 runs. The
remaining misses are most likely the subrouter placing the request on
another account (the cache is per account); that was not proven. The
subrouter keeps a codex installation id on one account: two
`CODEX_HOME`s with their own ids read 0 of a 31.5k-token prefix the other
wrote, and with one shared id they read 30,464. So every compactor slot
sends one stable Chief installation id.

**Codex compactor isolation.** Each compactor slot's preset points
`CODEX_HOME` at the slot's own directory, whose config.toml keeps only the
user's routing and model keys (`model`, `model_provider`,
`model_providers`, `openai_base_url`, `chatgpt_base_url`, `service_tier`,
`model_reasoning_effort`, `model_verbosity`) and turns off project
AGENTS.md, skills (none loaded, none listed), apps, plugins, memories,
hooks, subagents, code mode and history. The slot's auth.json is a
symlink to the user's: codex-acp refuses `session/new` without a sign-in
("Authentication required", checked live), a copy whose token refresh
rotated the refresh token would sign the user out, and codex rewrites
auth.json in place, so a refresh through the link updates the user's own
file. A sign-in kept in the keyring instead of auth.json is not linked. The node's rollout, thread database and logs are
deleted when it ends (and a crash's leftovers before the next node in the
slot). The start-up probe fails when the session lists any `$skill`
command.
acpmux gives codex no MCP servers, so the memory tools are the launcher's
`zoom` and `date` commands (`optchat-chief zoom ID N`, `optchat-chief date
ID`), named by absolute path in AGENTS.md.

**Session tags.** Every turn session and compactor session carries
`cmux.chief=<home id>` and `cmux.chief.role=turn|compactor`, set right
after `session/new` (a session that cannot be tagged is killed), so quit
counts and endAgents can exclude the Chief's own sessions. Children keep
`mux.parent` only.

## Compactor routes

The team subrouter serves Claude Code clients: a raw Messages API call for a
Claude model gets `429 rate_limit_error` every time (checked live on
2026-10-04), so a compactor that calls the API there builds no node that
needs a model, and every turn then waits on settle forever. The route is
acpmux unless `OPTCHAT_COMPACTOR=api`:

- `acpmux` (default):
  each node is built in its own acpmux session of `OPTCHAT_COMPACTOR_HARNESS`
  (claude-sr), as `mux/host/src/compactor.ts` does. The session runs with the
  `deny-all` policy and the compactor's own acpmux presets
  (`optchat-compact-<home id>-slot-<k>`, one per slot), which it requires: when acpmux refuses the
  preset, no compactor session starts (nodes fail and are retried, and the
  probe says why), so a node never runs with the user's `~/.claude` hooks,
  MCP servers or auto-memory. The preset sets `CLAUDE_CONFIG_DIR` to
  `optchat/compactor-claude` (not the turn agent's) and turns off
  auto-memory, CLAUDE.md files, bundled skills and Claude Code's own refusal
  fallback. The cwd is a slot directory under the system temporary
  directory, outside any directory with instruction files, whose
  `.claude/settings.json` denies every built-in tool (the interactive ones
  included; a denied tool leaves the model's tool list), disables all hooks
  and auto-memory. The first prompt follows the cached layout (see
  [Compactor cache](#compactor-cache)) when acpmux took the presets' `systemPrompt`,
  else the old layout: the compactor's system text, the context pieces and
  the step; each size-loop retry is the next prompt in the same session;
  the reply text is the line, with a lead-in line ("Here is the line:") dropped. When the node
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

**Cost.** In the old layout a node pays for its whole view at the
cache-write price: about 48k tokens and $0.12 at full size, and about 4 s,
of which about 1.5 s is the harness start. Nothing carries the view from
one node to the next (only Claude Code's own 1.2k-token prefix is read
back). Summaries run at roughly 1.2 nodes per message, so a full memory
costs roughly $0.15 per message in compactor calls, $150 a day at 1,000
messages; level-0 nodes run one at a time (rule 3), so a burst of tool
steps can keep the next turn waiting by about 4 s per step. The cached
layout cuts a node whose view is unchanged up to the 100k mark to about
$0.035 (measured below).

## Compactor cache

acpmux with preset `args`, `systemPrompt` and `cache_control` forwarding
(landed on `feat-cmux-next` at 3a6d7b3ec59) lets each node read most of
its view from the cache. Each slot preset (Claude harnesses only) carries
the args `--tools "" --strict-mcp-config --no-session-persistence` and a
`systemPrompt` the node sets before its session starts (acpmux writes the
file into its own preset directory, never the slot directory the agent can
write, and checks its sha256 at the start). A node in the cached layout:

1. The slot preset's system prompt: the compactor's system text, a blank
   line, and the context up to its first cache mark (50k characters). It replaces
   Claude Code's default system prompt, whose cwd and date lines made every
   node (8 slot directories) miss the cache, so the cache now crosses slots.
2. The first prompt: the context from 50k on, one block per piece, with ONE
   `cache_control` marker (`{"type": "ephemeral"}`) on the piece that ends
   at the last mark (100k, else 80k; no marker when only 50k exists, since
   Claude Code's own breakpoint covers the system prompt), then the step.
   Size-loop retries stay in the session, unchanged.

Measured live on 2026-10-04 on cmux-lawrence-2 (claude-sr through the team
subrouter, Claude Code 2.1.287, `claude-sonnet-5-5`, a private acpmux daemon
built from #17283, the blocks built by `cached_prompt`): two consecutive
nodes of a full-size view (127 KB, marks at 49,857, 79,817 and 99,977),
identical up to the 100k mark, the second in another slot directory:

| node | seconds | uncached | cache write | cache read | output | cost |
| --- | --- | --- | --- | --- | --- | --- |
| first (cold) | 3.9 | 2 | 48,079 | 0 | 160 | $0.122 |
| next, same view up to 100k | 4.2 | 2 | 10,771 | 37,671 | 46 | $0.035 |

Both sessions reported no tool and no MCP server, and no transcript was
written. The cache lasts 5 minutes, so it pays only when nodes come close
together (they do in a burst, which is when cost adds up).

Trade-offs and risks:

- **The 80k mark is lost.** Claude Code places 3 of the API's 4 cache
  breakpoints itself, also with a replaced system prompt,
  checked live: three markers of ours got `400 A maximum of 4 blocks with
  cache_control may be provided. Found 6.` One marker is all a node gets, so
  it sits at 100k; a node whose view changed between 80k and 100k reads only
  the system prompt (up to 50k) back, about $0.075 at full size instead of
  $0.035 (cache research, 2026-10-04).
- **A fourth Claude Code breakpoint.** If a later Claude Code places all 4,
  every marked prompt fails with that 400. The compactor then ends the
  session, retries the node once in a fresh session without the marker, and
  logs `compactor node <id>: Claude Code refused the cache_control marker
  (...); retrying without it, and later nodes go without it`; later nodes of
  that host skip the marker (only the system prompt is cached) until it
  restarts.
- **Feature detection.** The host installs the presets with their args and
  a seed `systemPrompt`; an acpmux that does not know a key refuses it
  (`unknown preset key "systemPrompt"`), host.log says `acpmux refused the
  systemPrompt of preset ...; installed without it`, and turns and nodes
  keep the old layout. A non-Claude harness gets neither and the old
  layout.

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

- **acpmux engine: cache breakpoints in the view (section 8).** On a Claude
  harness the view's first piece is the system prompt (Claude Code's
  breakpoint) and one marker sits at the last mark: two of the spec's three
  breakpoints (50k and 100k; 80k is lost to Claude Code's own three). On
  codex there are no breakpoints, only automatic prefix caching, routed by
  the Chief's stable `prompt_cache_key` on the cmux codex fork (upstream's
  per-thread key defeats it across turns; see Harnesses and cache layout).
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
- **Compactor through acpmux (section 4.2, 8).** In the cached layout the
  compactor's system text and the context's first piece are the session's
  system prompt (Claude Code's default prompt is replaced), and the context
  carries one breakpoint (100k) where the spec has three (50k, 80k, 100k):
  Claude Code keeps three of the four for itself (see Compactor cache). In
  the old layout (an acpmux without preset args) Claude Code's own system
  prompt (with its date and environment lines) comes first, the compactor's
  system text is the first block of the user prompt, the context pieces
  carry no breakpoints, and each node pays for its whole view at the cache
  write price. Measured live, see Cost and Compactor cache above. Each node
  also pays a harness start.
  Effort is `medium` on both routes, as section 4.2 says: acpmux passes it
  to Claude Code as `--effort medium` and to codex as `reasoning_effort`;
  another harness family keeps its default (`OPTCHAT_COMPACTOR_EFFORT`
  overrides; not yet measured live). Size-loop retries
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
- **Free nodes and JOBS (section 4.1).** The spec's pump returns as soon as
  JOBS calls run, before it looks at any node. Ours still builds free nodes
  (a short message verbatim, two children that fit together) when JOBS
  model calls run: JOBS caps compactor calls, and a free node makes none.
  The tree and the view are the same; only free nodes are not delayed.
- **Compactor reply (section 4.3).** The spec only trims the reply. On the
  acpmux route a lead-in line before the summary ("Here is the line:", a
  line that ends with a colon and has no other `: `) is dropped too
  (`strip_preamble`): Claude Code and the model sometimes write one, and it
  would become part of a permanent line.
- **System prompt (section 7.2).** Between VIEW_DOC and the user's own
  AGENTS.md there is a short cmux section (how to drive cmux, the subagent
  commands, the memory tools by name or path). It names no user and holds
  nothing per turn. The spec has the user's instructions file there; the
  section is what any cmux user would otherwise have to write into it.
- **Tool results inside an acpmux turn (section 7, CAP).** Every logged
  `echo` is capped at CAP. Inside an acpmux turn the harness resends its
  own tool result to the model, at its own size limits (Claude Code cuts
  long outputs itself), which the host cannot change; the native engine caps
  before it resends, as the spec says.
- **Who is logged (section 2: "every message").** Only human messages that
  wake the Chief are logged (`cmux_chief::rules::wakes`): in a group
  conversation a message without a mention is not, and a message from a
  paired device is not (fail closed until the remote-origin gate exists).
  Non-text parts are not logged on this branch.
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
the start-up notice, the cached layout's system prompt file and single
marker, the retry without the marker, the old layout without preset args); `tests/audit3.rs` covers interrupts on the acpmux
engine and home-scoped turn names, `tests/native.rs` interrupts on the
native engine;
`tests/harness.rs` covers the harness switch, the Claude turn layout (preset system prompt, one marker, no CLAUDE.md, the 4-breakpoint rerun, the old layout), the codex turn layout and AGENTS.md, both usage shapes (also when the answer follows `turn_end`), `chief zoom`/`date`, and the `cmux.chief` tags;
`tests/acpmux_wire.rs` (preset args, `systemPrompt` and their feature detection, session tags included) and `tests/daemon_wire.rs` run the real clients against
fake servers on Unix sockets; `tests/lock.rs` runs the binary against a held
lock; `tests/mcp.rs` runs `optchat-chief mcp` against a live test memory.
