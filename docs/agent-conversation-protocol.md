# Agent conversation protocol

A normalized layer over coding-agent session output. One canonical event vocabulary, produced by reading each agent's own session transcripts off the filesystem, consumed by GUIs on every surface. This lets cmux open a structured chat view for any session, including ones already running in a terminal pane that cmux did not spawn.

The interface is adapted from t3code's canonical runtime events (items with a started/updated/completed lifecycle, streaming discriminated by kind, requests as first-class events). The implementation is deliberately different: t3code spawns agents through their SDKs and can only see sessions it created. We read the transcripts the agents already write (`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`, `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), so any session is observable.

## Where each piece lives

- **Contract:** `webviews/src/agent-chat/protocol.ts` (source of truth), mirrored by `daemon/remote/agentconv/protocol.go`. Golden fixtures in `daemon/remote/agentconv/testdata/` keep the two honest.
- **Producer:** Go package `daemon/remote/agentconv` inside cmuxd-remote: session discovery, per-provider parsers, file tailing, exposed as `agent.*` RPC verbs next to the existing `pty.*`/`session.*` verbs. One implementation runs everywhere transcripts live: headless Linux cmux servers, and macOS where the app spawns the same binary as a local stdio child.
- **Consumers:** the `/agent-chat` TanStack surface in `webviews/` (macOS via WKWebView bridge), iOS later over the mobile transport, terminals untouched.

## Event model

Everything in a conversation is an item: `user_message`, `assistant_message`, `reasoning`, `plan`, `command_execution`, `file_change`, `mcp_tool_call`, `dynamic_tool_call`, `web_search`, `context_compaction`, `error`, `unknown`. Items have a lifecycle (`in_progress` → `completed`/`failed`/`declined`). Tool results fold into their tool item by `tool_use_id`; the GUI never pairs calls with results itself.

Events per subscription, `seq` strictly increasing: `snapshot` (full item list at open), `item.started`, `item.updated`, `item.completed`, `session.meta`, `error`, plus the hook-sourced events below. Items that arrive complete in the transcript (whole assistant messages) are emitted as a single `item.completed`. Reconnect means re-open and take a fresh snapshot.

Hook-sourced events (see "Hook ingest"; transcripts cannot observe these):

- `turn.started` `{turn_id, prompt?}` / `turn.completed` `{turn_id}` bracket agent activity between a user prompt and the agent stopping. GUIs draw turn boundaries from these when present; the fallback stays client-derived from `user_message` items.
- `request.opened` `{request_id, request_type, detail?}` / `request.resolved` `{request_id, decision?}` mark the agent waiting on the user. `request_type` is `tool_approval` | `user_input` | `unknown`; `decision` is set when the outcome is known (e.g. `approved`/`denied`) and absent when the request was implicitly cleared because the agent made progress (any later prompt/tool/stop frame).

Content optionality: an item first emitted from a hook frame is sparse (tool name, short title, no input/output). The full content arrives as `item.updated` when the transcript line for the same `tool_use_id` lands.

Reserved name for a later phase, do not repurpose: `content.delta` (token streaming).

## RPC verbs (cmuxd-remote)

Same newline-delimited JSON envelope as the existing verbs.

- `agent.sessions.list` `{provider?, cwd?, limit?}` → `{sessions: SessionRef[]}`
- `agent.session.open` `{provider, session_id?, cwd?, transcript_path?}` → `{subscription_id, session}`, then async frames `{event: "agent.session.event", subscription_id, payload: Event}` starting with a `snapshot`
- `agent.session.close` `{subscription_id}`

## Hook ingest (live push source)

Transcripts are replay/backfill ground truth, but they lag and cannot observe turns or permission prompts. Agent hooks are the second producer into the same per-subscription canonical stream.

### Ingest socket

While at least one `agent.session.open` subscription is open, cmuxd-remote listens on a per-user unix socket:

```
/tmp/cmuxd-agentconv-<uid>/ingest.sock     (parent dir 0700, socket 0600)
```

`CMUX_AGENT_HOOK_SOCKET` overrides the path (tagged dev builds must set it so they do not collide with the user's stable daemon; tests use it too). The socket exists only while subscriptions do; the daemon removes it after the last close. If another live daemon already owns the path, the newcomer logs and does not steal it.

The socket accepts newline-delimited JSON hook frames:

```json
{"provider": "claude", "session_id": "<uuid>", "hook": "PreToolUse",
 "tool_name": "Bash", "tool_use_id": "toolu_x", "prompt": "...", "detail": "...",
 "decision": "...", "ts": "2026-06-10T17:00:00Z"}
```

`hook` is one of `UserPromptSubmit` | `PreToolUse` | `PostToolUse` | `Stop` | `Notification` | `PermissionRequest` (unknown kinds are ignored). `detail` is a short human label: the notification message, or a one-line tool title. Frames route to all open subscriptions matching `(provider, session_id)`; frames for sessions with no subscription are dropped (logged once per session).

### Mapping and dedup

| Hook frame | Canonical event |
| --- | --- |
| `UserPromptSubmit` | `turn.started` (synthesized `turn_id`, prompt text) |
| `Stop` | `turn.completed` (no-op when no turn is active) |
| `PreToolUse` | `item.started` (tool item, `in_progress`, classified by `tool_name` exactly like the transcript parser) |
| `PostToolUse` | `item.completed` |
| `Notification` / `PermissionRequest` | `request.opened`, plus `request.resolved` when the frame carries a `decision` |

Dedup against transcript-derived events is by `tool_use_id`:

- hook then transcript: the hook emits a sparse `item.started` immediately; the transcript line for the same `tool_use_id` merges into that item and emits `item.updated` with the full content, never a duplicate `item.started`. A transcript `tool_result` landing after a hook `PostToolUse` is likewise emitted as `item.updated`.
- transcript then hook: the late hook frame for an item the transcript already emitted is suppressed; a hook `PostToolUse` still completes a transcript item that is `in_progress` (hook wins on latency, transcript wins on content).
- hook only: items whose transcript line never lands keep their sparse hook content. Tool frames without a `tool_use_id` are dropped (they could never be deduplicated).
- requests resolve explicitly via a `decision`-carrying frame, or implicitly when any later progress frame (prompt, tool use, stop) proves the agent is no longer blocked; implicit resolutions carry no `decision`.

Pending request and turn state is ephemeral: it resets when a truncated/rewritten transcript forces a fresh snapshot, and GUIs reset it on every snapshot.

### Emit verb

```
cmuxd-remote agent-hook-emit --socket <path> [--provider <id>] [frame-json]
```

Reads the frame from the positional argument or stdin. Accepts either a ready hook frame (has `hook`) or a provider-native payload: Claude Code's hook stdin shape (has `hook_event_name`) is translated automatically — `session_id`, `hook_event_name`→`hook`, `tool_name`, `tool_use_id`, `prompt`, `message`→`detail`, and a one-line tool title derived from `tool_input` when there is no message. The verb ALWAYS exits 0 (bad input, connect failure, no listener): hooks must never slow down or break the agent. Diagnostics go to stderr only.

### Claude Code hook config cmux injects at launch

Claude Code loads extra settings per launch via `claude --settings <file-or-json>`; hooks configured there receive the native payload on stdin (which includes `session_id` and `tool_use_id`). cmux must NOT write to the user's `~/.claude/settings.json`.

The launch side lives in two pieces:

1. **The app (Swift, `Sources/AgentChat/AgentHookLaunchEnvironment.swift`)** exports two managed environment variables into every terminal surface: `CMUX_AGENT_HOOK_EMIT_BIN` (the staged `cmuxd-remote` binary from the checksum-verified remote-daemons cache, via `AgentDaemonBinaryLocator`) and `CMUX_AGENT_HOOK_SOCKET` (this instance's ingest socket path). When no daemon binary is cached, neither variable is set and injection is skipped entirely; agent launches never depend on this feature. Because a cached daemon predating the verb falls through to its CLI dispatch when invoked as `agent-hook-emit` (it would stall and fail every Claude hook), injection additionally requires provenance that provably carries the verb: the explicit `CMUX_REMOTE_DAEMON_BINARY` dev override on any build, or, on stable release builds only, a cached binary at the app's exact release version (same-SHA artifacts) or newer; debug, nightly, and staging builds share marketing versions with stable artifacts from other SHAs and inject only with the override. The relay is resolved once per app session, not per terminal surface. The same socket path is pinned into the environment of the `cmuxd-remote serve --stdio` child the chat surface spawns, so the listener and the emitters always agree.
2. **The Claude launch wrapper (`Resources/bin/cmux-claude-wrapper`)**, which already owns cmux's per-launch `--settings` payload, merges one extra hook entry per event into that payload when both variables are present and the emit binary is executable:

```json
{ "type": "command", "command": "\"$CMUX_AGENT_HOOK_EMIT_BIN\" agent-hook-emit --socket \"$CMUX_AGENT_HOOK_SOCKET\"", "timeout": 5 }
```

for `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification`, and `PermissionRequest`. The env references are expanded by the shell Claude runs hook commands with (the wrapper's existing `CMUX_CLAUDE_HOOK_CMUX_BIN` convention), which keeps DerivedData paths with spaces safe without quoting games. The high-frequency tool hooks (`PreToolUse`, `PostToolUse`) carry `"async": true` so they never add latency to tool calls; the merge layer tolerates a `PostToolUse` frame overtaking its `PreToolUse`. The same one-liner serves every event because the verb reads `hook_event_name` from stdin.

The merge happens inside the single `--settings` value the wrapper already injects because Claude's `--settings` is last-wins, not cumulative (verified on 2.1.175: `claude --settings '{invalid' --settings '{}' -p hi` succeeds, while the reversed order fails on the invalid value), so passing a second `--settings` would clobber cmux's existing hook payload. For the same reason a user-supplied `--settings` on the command line wins over cmux's entirely; the wrapper passes it through untouched (user settings are never clobbered; cmux's injection is lost for that launch).

Idempotency: the wrapper composes the settings inline on every exec, so resume/fork relaunches re-inject the same configuration with no files to clean up or merge.

#### Ingest socket path scheme (tagged builds)

`AgentHookLaunchEnvironment.ingestSocketPath` derives the per-instance path from the bundle identifier variant (the same classification the control socket uses): stable release builds use the documented default `/tmp/cmuxd-agentconv-<uid>/ingest.sock`; every other variant is scoped to `/tmp/cmuxd-agentconv-<uid>-<variant>[-<slug>]/ingest.sock` (e.g. `-debug-my-tag`, `-nightly`, `-staging-rc1`) so a tagged dev build's hooks and daemon never cross-talk with the user's stable app. An explicit `CMUX_AGENT_HOOK_SOCKET` in the app's own environment overrides the derivation (tests, operators).

### Codex notify config cmux injects at launch

Codex has no hook system, but `notify` in `~/.codex/config.toml` names a program argv that Codex invokes with an `agent-turn-complete` JSON payload appended as the final argument. `Resources/bin/cmux-codex-wrapper` (installed as a shell function by the cmux shell integration, like the Claude wrapper) injects it per launch, never writing the user's config:

```
codex -c notify=["<emit>","agent-hook-emit","--socket","<sock>","--provider","codex"] ...
```

The emit verb recognizes the Codex payload shape and translates it to a `Stop` frame (`thread-id` is the session id). Injection is skipped when the user already has a notifier: their own `-c`/`--config` `notify` override on the command line, or an uncommented `notify` key in config.toml (cmux's persistent Codex integration never sets one, so a present key is always user-chosen). It is also skipped outside cmux terminals, when `CMUX_CODEX_HOOKS_DISABLED=1`, and when the env vars or emit binary are missing. The opencode plugin is a follow-up; it will emit ready-made frames with its own `provider`.

The daemon-side capability string for this feature is `agent.conversation.hooks` (in `hello`).

## Provider mapping notes

Claude Code (`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`): `user`/`assistant` lines carry `message.content` as a string or block array. `text` → message items, `thinking` → reasoning, `tool_use` → tool item (classified by tool name: Bash → command_execution; Edit/Write/MultiEdit/NotebookEdit → file_change; WebSearch/WebFetch → web_search; `mcp__*` → mcp_tool_call; otherwise dynamic_tool_call). `tool_result` blocks live in `user` lines and fold into their item by `tool_use_id`. Sidechain lines (`isSidechain`), meta lines, and unknown top-level types (`summary`, `queue-operation`, `attachment`, `mode`, ...) are skipped. Malformed lines are skipped, never fatal.

Codex (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): `response_item` of type `message`/`reasoning`/`function_call`/`function_call_output` (paired by `call_id`; `shell` → command_execution, `apply_patch` → file_change). `event_msg` duplicates response_item text and is dropped, as is `token_count`. Envelope wrappers (`<permissions>`, `<environment_context>`, `# AGENTS.md` preamble) are stripped from message text. Discovery globs the sessions tree in P1; the sqlite index (`~/.codex/state_5.sqlite`) is a later optimization.

## Write path (P2, design constraint now)

Sending a message to a session must respect who owns the live process. If the session has a live TUI in a terminal pane, inject the text into that pane's existing PTY; never run a second `claude --resume` of the same session concurrently. Only sessions with no live process get a daemon-spawned background `claude --resume <session-id>` PTY (real CLI, no `-p`), with the GUI continuing to render from the transcript tail. Pane-to-session mapping stays in the macOS app (`SharedLiveAgentIndex`/`RestorableAgentSessionIndex`).

## Phases

- **P1 (this):** contract + Go parsers (Claude, Codex) + tailing + `agent.*` verbs + macOS local stdio spawn + read-only `/agent-chat` surface opened from a terminal pane. Iteration 2 added the live hook ingest source (turns, requests, low-latency tool items) for Claude; rendering of requests is display-only (banner, no answer buttons).
- **P2:** composer (pane PTY inject + background `--resume` for detached sessions), launcher injection of the Claude hook config, Codex `notify`/opencode plugin hook sources.
- **P3:** answering permission requests, Codex write path, image fetch (`agent.image.get`), iOS consumer, remote hosts over the existing `cmux ssh` daemon channel.
