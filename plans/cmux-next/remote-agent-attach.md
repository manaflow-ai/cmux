# Remote agent attach (G2)

An agent chat tab is a store tab with an `agent_session` record (`agent-session-tabs-v1`). When
its session runs in another machine's acpmux (for example a subagent of the headless Chief brain
on a paired server), the app used to show only "This chat runs on <name>". With
`agent-session-attach-v1` the app streams that session and types into it through the session
daemon that owns the tab. No acpmux port is opened, and the app never talks to the other
machine's acpmux.

## Path

```
page (React acpmux client)
  -> AgentPaneTransport (method allowlist, gestures, bounded queues; unchanged)
  -> AcpmuxPaneSocket over a RemoteAcpmuxWire (instead of the local WebSocket)
  -> AgentSessionAttachClient: its own connection to the tab's session daemon
     (server reach: SSH carrier -> remote-sidecar -> daemon Unix socket, ClientTransport::Unix)
  -> daemon agent-session-* verbs (cmux-tui-core server/agent_session_attach.rs)
  -> one acpmux unix-socket link per attached tab (server/agent_session_link.rs)
```

`RemoteAcpmuxWire` answers the page's acpmux JSON-RPC with typed daemon calls: `initialize`
(origin `remote`, no extensions), `_acpmux/status`, `_acpmux/watch` (only this session),
`_acpmux/attach`, `_acpmux/events`, `_acpmux/detach`, `session/prompt` (text blocks only),
`session/cancel`, `_acpmux/permission_respond`. Every other method, and every frame that names
another session, gets `remote.unsupported`. Daemon pushes become `_acpmux/event` and
`_acpmux/permission_pending` notifications, so the page's own connect, replay and reconnect code
runs unchanged.

Daemon verbs (cmux-tui/spec/commands.md "Agent session attach"): `agent-session-attach`,
`agent-session-events`, `agent-session-prompt`, `agent-session-cancel`,
`agent-session-permission`, `agent-session-detach`; events `agent-session-record`,
`agent-session-permission`, `agent-session-changed` (status and queue of that session only),
`agent-session-closed`. Each names a store tab by `surface`.

## Backpressure and reconnect

The daemon reads its acpmux link at all times and puts each record on the connection's bounded
outbound stream without waiting. A client that does not keep up overflows that stream; the
attachment ends with `agent-session-closed {reason:"overflow"}`. acpmux's own lag (`_acpmux/lagged`,
from its bounded broadcast) ends it with `lagged`. Queued records of an ended attachment can be
dropped, but the client always holds a gap-free prefix of the log, so it reconnects and replays
with `after_seq` = its newest seq (the page's existing `fetchMissedEvents`). The wire closes on
`agent-session-closed` or a dropped daemon connection; the page asks for a fresh handshake and a
fresh wire (the ended attachment's daemon connection closes). Notifications that reach the
daemon before acpmux's attach reply (a running turn) wait in a bounded buffer of 256 and go out
after the reply; the reader never blocks. Bounds: 8 attachments per connection, 64 per daemon, 8
worker calls and 16 acpmux calls in flight per attachment (a prompt holds none: its end-of-turn
reply is not waited for), pages of 500 records and 8 MiB, prompts of 64 KiB, acpmux lines of
32 MiB, early notifications 256 and 16 MiB.
On the SSH/server carrier every `agent-session-*` line uses the bulk lane in both directions
(cmux-remote `mux_lanes.rs`), so a record never overtakes the attach reply.

## Remote CLI relay analysis (AGENTS.md)

The verbs are served only to trusted local (Unix) connections; the server reach arrives as one
through the SSH carrier's sidecar on the same uid. They are not on the remote relay allowlist
(`remote_relay/gate.rs`, the conversations-only `cmux link` entry, default deny); WebSocket
clients are refused. Policy tests: `agent_session_attach_tests.rs`.

- Local command or content execution: the verbs run nothing on the daemon host by themselves.
  No param is command-bearing: every params struct denies unknown fields, so `command`,
  `initial_command`, `cwd`, `mcpServers`, `agent`, a session id or any other field is
  `agent_session.bad_request`. A prompt is content: one ACP text block, sent to the session the
  tab already shows. The agent may act on that text with the rights it already has on its own
  machine; that is the user's own chat on the user's own machine, the same as typing into it
  there. Starting sessions, changing modes or policies, forks, kills, exports, peers and folder
  reads are not reachable: the daemon has no verb for them and the wire refuses them.
- Access to unowned objects: every verb names a tab of this daemon's store; the tab must be an
  `agent_session` tab with a bound session, and the session comes from the store record, never
  from the client. The attach must find that session in this machine's acpmux, by its exact id
  or full name (acpmux also resolves unique prefixes; the daemon refuses those). Records,
  permission requests and status changes of other sessions on the same acpmux link are dropped
  (the link watches all sessions only to get this session's status). A closed tab, or one whose
  record now names another session, ends its attachment at its next record or call. Limit: the
  daemon has no install id, so it cannot check the record's `host`; a record naming a session of
  another machine reaches this machine's acpmux only when a session with that id or name exists
  here.
  The app does not bind or rewrite the remote record (no `bind-conversation-tab-session` from a
  remote tab).
- Local-state exposure: the client sees the tab's acpmux page and records (the chat it asked
  for), nothing about other sessions, the daemon's socket paths or the acpmux home. Refusals are
  codes. The app turns off this Mac's git reads for a remote tab, so no local folder is read on
  the chat's behalf.
- Permission requests: acpmux announces them on the attachment; the daemon forwards them as
  `agent-session-permission` and keeps their ids. An answer names an announced id, once
  (`agent_session.unknown_permission` otherwise). The daemon never answers by itself, and the
  app's transport still requires a fresh user gesture for an allow.

### Landing review (2026-10-08)

Checked against the relay rules before landing on feat-cmux-next:

- Default deny holds. `handle_connection_frame` sends every `ClientTransport::Remote` or
  remote-relay frame to `remote_relay::handle_frame` before `agent_session_attach::try_handle`
  runs, and the relay gate names no `agent-session-*` verb. `try_handle` also refuses a non-Unix
  or remote client itself (`agent_session.not_trusted`), so a later dispatch reorder stays safe.
- Owner only. The verbs need a trusted Unix connection to the daemon socket; the server reach
  gets one only through the SSH carrier's sidecar under the owner's uid.
- Scoped to the session's objects. The only ID param is `surface`; it must name an
  `agent_session` tab of this store, the session comes from that record, the attach refuses an
  acpmux prefix match, and every later call re-reads the record (a rebound tab ends with
  `detached`). Permission answers must name an id announced on that attachment.
- Command-bearing params are denied: each params struct is `deny_unknown_fields`, and no struct
  has a command, cwd, agent, MCP server or session field.
- App side: a remote tab gets no git reads, no session rebind, no seed, no New Tab page and no
  tab conversion; `RemoteAcpmuxWire` answers every method outside its list `remote.unsupported`.
  Residual: records from the other machine render in this Mac's page with the same trust as a
  local agent's records, and page actions a user clicks (open tab, app actions) act on this Mac
  as they do for a local chat.

## Daemon config

The daemon resolves its acpmux socket at start like `cmux acp`: `ACPMUX_SOCKET`, else
`ACPMUX_HOME`, else the tag's home, else `~/.acpmux`. A headless brain daemon must run with the
brain's `ACPMUX_HOME` (the brain installer sets it in the daemon LaunchAgent).
