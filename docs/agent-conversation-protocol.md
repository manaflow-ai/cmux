# Agent conversation protocol

A normalized layer over coding-agent session output. One canonical event vocabulary, produced by reading each agent's own session transcripts off the filesystem, consumed by GUIs on every surface. This lets cmux open a structured chat view for any session, including ones already running in a terminal pane that cmux did not spawn.

The interface is adapted from t3code's canonical runtime events (items with a started/updated/completed lifecycle, streaming discriminated by kind, requests as first-class events). The implementation is deliberately different: t3code spawns agents through their SDKs and can only see sessions it created. We read the transcripts the agents already write (`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`, `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), so any session is observable.

## Where each piece lives

- **Contract:** `webviews/src/agent-chat/protocol.ts` (source of truth), mirrored by `daemon/remote/agentconv/protocol.go`. Golden fixtures in `daemon/remote/agentconv/testdata/` keep the two honest.
- **Producer:** Go package `daemon/remote/agentconv` inside cmuxd-remote: session discovery, per-provider parsers, file tailing, exposed as `agent.*` RPC verbs next to the existing `pty.*`/`session.*` verbs. One implementation runs everywhere transcripts live: headless Linux cmux servers, and macOS where the app spawns the same binary as a local stdio child.
- **Consumers:** the `/agent-chat` TanStack surface in `webviews/` (macOS via WKWebView bridge), iOS later over the mobile transport, terminals untouched.

## Event model

Everything in a conversation is an item: `user_message`, `assistant_message`, `reasoning`, `plan`, `command_execution`, `file_change`, `mcp_tool_call`, `dynamic_tool_call`, `web_search`, `context_compaction`, `error`, `unknown`. Items have a lifecycle (`in_progress` → `completed`/`failed`/`declined`). Tool results fold into their tool item by `tool_use_id`; the GUI never pairs calls with results itself.

Events per subscription, `seq` strictly increasing: `snapshot` (full item list at open), `item.started`, `item.updated`, `item.completed`, `session.meta`, `error`. Items that arrive complete in the transcript (whole assistant messages) are emitted as a single `item.completed`. Reconnect means re-open and take a fresh snapshot.

Reserved names for later phases, do not repurpose: `content.delta` (token streaming), `request.opened`/`request.resolved` (permission prompts), `turn.started`/`turn.completed`. Turn grouping in P1 is derived client-side from `user_message` boundaries.

## RPC verbs (cmuxd-remote)

Same newline-delimited JSON envelope as the existing verbs.

- `agent.sessions.list` `{provider?, cwd?, limit?}` → `{sessions: SessionRef[]}`
- `agent.session.open` `{provider, session_id?, cwd?, transcript_path?}` → `{subscription_id, session}`, then async frames `{event: "agent.session.event", subscription_id, payload: Event}` starting with a `snapshot`
- `agent.session.close` `{subscription_id}`

## Provider mapping notes

Claude Code (`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`): `user`/`assistant` lines carry `message.content` as a string or block array. `text` → message items, `thinking` → reasoning, `tool_use` → tool item (classified by tool name: Bash → command_execution; Edit/Write/MultiEdit/NotebookEdit → file_change; WebSearch/WebFetch → web_search; `mcp__*` → mcp_tool_call; otherwise dynamic_tool_call). `tool_result` blocks live in `user` lines and fold into their item by `tool_use_id`. Sidechain lines (`isSidechain`), meta lines, and unknown top-level types (`summary`, `queue-operation`, `attachment`, `mode`, ...) are skipped. Malformed lines are skipped, never fatal.

Codex (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): `response_item` of type `message`/`reasoning`/`function_call`/`function_call_output` (paired by `call_id`; `shell` → command_execution, `apply_patch` → file_change). `event_msg` duplicates response_item text and is dropped, as is `token_count`. Envelope wrappers (`<permissions>`, `<environment_context>`, `# AGENTS.md` preamble) are stripped from message text. Discovery globs the sessions tree in P1; the sqlite index (`~/.codex/state_5.sqlite`) is a later optimization.

## Write path (P2, design constraint now)

Sending a message to a session must respect who owns the live process. If the session has a live TUI in a terminal pane, inject the text into that pane's existing PTY; never run a second `claude --resume` of the same session concurrently. Only sessions with no live process get a daemon-spawned background `claude --resume <session-id>` PTY (real CLI, no `-p`), with the GUI continuing to render from the transcript tail. Pane-to-session mapping stays in the macOS app (`SharedLiveAgentIndex`/`RestorableAgentSessionIndex`).

## Phases

- **P1 (this):** contract + Go parsers (Claude, Codex) + tailing + `agent.*` verbs + macOS local stdio spawn + read-only `/agent-chat` surface opened from a terminal pane.
- **P2:** composer (pane PTY inject + background `--resume` for detached sessions).
- **P3:** permission requests, Codex write path, image fetch (`agent.image.get`), iOS consumer, remote hosts over the existing `cmux ssh` daemon channel.
