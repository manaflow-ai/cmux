# cmux next: remote conversations on a paired server (relay analysis)

Status: revision 3 (lane 10, server), after the security review of bd5ceb79a51 (1 P0, 4 P1,
5 P2), with the coordinator's decisions D-A and D-B of 2026-10-04. No code yet; the review agent
re-checks this revision before any code. Decisions D1 and D2 of 2026-10-04: the MacBook opens the daemon
conversations of a paired Mac mini over lane 12's `cmux link` overlay; the server is a
`MachineRegistry` kind `paired {install_id, name, path_state}`. This is the analysis that
`skills/cmux-socket-policy/references/remote-relay-authorization.md` requires before code.
Decided: D-A, the remote approval minimum with no waiver (section 6); D-B, a distinct
`remote_<install>` participant added at pairing (section 5); D-C, a paired device is the same
person; D-D, offline revocation limits 24 h / 72 h; D-E, the daemon-side PreToolUse hook.

## 1. Threat model

- The remote party is a paired install of the server's owner (server.md 6.2). It is treated as
  a **compromised client**: a stolen laptop, a malicious process of the laptop user, a forged
  frame. It never inherits local trust.
- Protected on the server: terminals, workspaces, agent sessions and their tools, files,
  localhost services, the store, tokens and keys, pending pairing codes, memory files,
  automations, and the user's other data.
- A message to the owner's Chief is an instruction to a model with the full tool catalog. That is
  remote execution through the model and is handled as such (section 6).

## 2. Transport position and identity

- `cmux link` (lane 12, not built yet) is the only process that reaches the daemon for a remote
  peer. It connects to a **separate daemon remote-relay entry** (its own Unix socket, 0600), never
  to the admin socket. The daemon accepts a connection there only after it checks the peer with
  the audit token (`LOCAL_PEERTOKEN`, macOS) or `SO_PEERCRED` (Linux): same uid, and on macOS the
  cmux team code signature of the link binary (on Linux, `SO_PEERCRED` checks the uid only; the
  socket's 0600 mode and folder carry the rest). There is no env or debug bypass, also not for
  ad-hoc DEV builds (a DEV build without a team signature cannot serve remote peers).
- Identity: WireGuard authenticates the peer static key; the link maps it to the install id
  through the pairing record (allowed IP: the /128 from the install id) and sends the **stamp**
  `{install_id, user_id, wg_key}` as the first out-of-band record of each stream that
  `link.dial {host, service: "daemon"}` opens. The daemon trusts the stamp and nothing else.
  No stamp, a stamp on the admin socket, or a stamp from a process that fails the peer check:
  the stream is closed before the first frame.
- New transport kind `ClientTransport::RemoteRelay(stamp)` beside Unix and WebSocket.
  `is_unix()` is **false** for it, so `require_local`, `url_open::start` and
  `loopback_forward::try_handle` refuse it by their existing checks. Tests pin this (section 9).
- Principal: `conversation_principal` becomes an enum `Local | Agent(participant) |
  Remote(stamp)`. An absent principal is refused; there is no default to `LOCAL_USER` for any
  connection on the remote entry.

## 3. Gate position (frame level, before every router)

`handle_connection_message` today routes resource-protocol, `loopback-*` and
`scheduler.dispatch` frames before the command parse, and `UrlOpen` runs first in
`handle_request_with_cancellation`. The remote gate therefore runs **first in
`handle_connection_message`** for `RemoteRelay` connections, before the resource router,
loopback, scheduler and URL-open paths:

- every resource-protocol, `loopback-*`, `scheduler.*`, `url-open` and binary frame: refused;
- every command not on the allowlist (section 4): refused;
- an allowlisted command: params checked (section 7), then dispatched.

A second filter runs at the **outbound writer** of a remote connection: only allow-listed event
kinds for owned conversations leave it (section 8). Nothing reaches the remote writer directly.

## 4. Allowlist (default deny, exact names, never prefixes)

| Command | Remote | Rule |
| --- | --- | --- |
| `identify` | yes | reply built from a remote-only struct: protocol version and the conversation capabilities; no socket path, pid, state dir, hostname, window or client ids |
| `set-client-info` | yes, reduced | accepts only `name` and `capabilities` from an allowlist (`local-conversations-v1` and its read features); refuses any other capability (for example `loopback-forward`); ignores `user_id`, `display_name` and every `device_*` field; identity is only the stamp |
| `subscribe` | yes, reduced | no `surface` and no `tree_events` params (refused); the stream gets only section 8 events |
| `conversation-list` | yes | owned conversations only (section 5) |
| `conversation-snapshot`, `conversation-history` | yes | owned `conversation` only |
| `conversation-op` | partly | kinds `message.send`, `message.edit`, `message.retract`, `reaction.add`, `reaction.remove`, `read_cursor.set`; approval kinds and any other kind refused by name |
| `conversation-typing` | yes | owned conversation |
| `conversation-create`, `participants.add`, `title.set` | no (v1) | |
| `conversation-search`, `conversation-tabs`, `new-conversation-tab` | **no** | named here because they share the prefix; nothing is allowed by prefix |
| `conversation-agent-token`, `conversation-bind` | **never** | credential minting and binding |
| all other commands (workspace, screen, pane, tab, terminal, browser, raw, send-keys, write, lifecycle, plugin, journal, notification, pairing, session, url-open, loopback, scheduler) | **never** | table test over the daemon's whole command list; a new command is denied until added here with an analysis |

## 5. Owned objects and the remote participant (D-B)

- Owner scope (v1): the stamp's `user_id` must equal the server **owner** (the `user` of the
  stored pairing record); a peer that is not the owner owns nothing. The store's list, snapshot
  and history do no participant check today, so the gate applies the clause below.
- Unknown and unowned conversation or message IDs give the **same** error (`remote_denied`), so a
  peer cannot probe. Ref forms, prefixes and names are refused.
- **Remote participant (D-B).** Each paired install has a distinct participant
  `remote_<install>` with kind `human` and a new field **`person: "user_local"`** (the same human
  as the server's own user; display name "<owner name> (<device name>)").
  - **Same person (D-C, decided yes):** the wake rule (home.md 2: with more than one human
    the Chief wakes only on a mention, a reply or a DM) and the participant budget
    (`MAX_PARTICIPANTS`) count distinct **persons**, not participant ids. A paired device therefore
    does not change how the Chief answers the owner's plain local messages, and devices do not use
    up the budget.
  - **Which conversations:** every conversation whose participants include `user_local`, at
    pairing time and later: a conversation created afterwards with `user_local` gets the
    `remote_<install>` participant of every active paired install in the same commit.
  - **Who adds and removes it:** new system-only ops `participants.add_system` and
    `participants.remove_system`, accepted only from the daemon's own pairing and revocation path
    (principal `System`), refused from local clients, agents and remote peers. A conversation at
    its person budget refuses the add, and pairing reports it.
  - **Remove:** `participants.remove_system` takes the participant out of the list; its past
    messages stay with author `remote_<install>` and show "removed device"; nothing can be sent
    or edited as that participant again.
  - The remote actor is always `remote_<install>`, **never** `user_local`; a request that names
    another actor gives `actor_mismatch`. Authorship is per device: a remote peer can edit or
    retract only messages its own `remote_<install>` sent (`not_author` otherwise).
  - Every remote op and message carries `origin: {kind: "remote", install}` in the op ledger and on
    the message. This changes the `cmux-conversation` wire types and the conformance corpus that
    the cloud `ConversationDO` replays, so the change lands with a coordination line and the corpus
    update in the same push, agreed first with the `ConversationDO` owner (the backend lead)
    through a coordination line.
- Owned conversation: `remote_<install>` is a participant and the stamp's `user_id` is the server
  owner. The gate checks this for list, snapshot, history, typing and ops.

## 6. Remote prompts to agents (D-A, decided: no waiver)

A `message.send` from a remote principal into a conversation with an agent starts a
**remote-origin prompt chain**.

1. **Fixed minimum.** In a remote-origin chain every side-effect tool needs an approval: every MCP
   write, Bash and other shell, file writes, child agent spawn, `automation.deploy`, settings,
   `CLAUDE.md` and hooks edits, every memory-file change (`LOG.txt`, `TREE/`) and every scheduled
   automation change. Reads outside the Chief's workspace need an approval too, because their
   output returns to the remote as text. **Workspace** for the Chief is `$MUX_HOME` (its home
   folder); for another agent it is the workspace root of its session. A tool the gate cannot
   classify needs an approval. Nothing lowers the minimum: not the remote, the model, a setting,
   `CLAUDE.md`, a hook config or a permission mode; there is no waiver.
2. **Where it is enforced (D-E, decided; the acpmux and agent-host owner confirms):** in the daemon, not in the agent's permission
   mode (Claude Code sets that per session, so a mixed session or a bypass-mode child would
   escape it).
   - Claude Code sessions (the Chief and every child it spawns): the agent host installs a
     **PreToolUse hook** owned by the daemon for every session it starts, set in the managed
     settings layer so the session cannot remove it. PreToolUse hooks run in every permission
     mode, including bypass. The hook asks the daemon `turn.origin {session, tool, input}`; for a
     remote chain the daemon decides: allow (classified read inside the workspace), or hold the
     call until an approval arrives and then allow, or deny. A hook timeout or a daemon error
     denies.
   - ACP agents (acpmux): the same daemon decision at acpmux's permission step
     (`session/request_permission`), per prompt, not per session.
3. **Mixed prompts.** A prompt that contains any remote message is a remote prompt, also when
   local messages are in it.
4. **Lifetime of the mark (P2-A).** The mark belongs to the prompt chain for its whole life: the
   prompt, its tool calls, its child sessions and its `[mux-event]` follow-ups. A later local
   message starts a new chain; it never clears a chain that is still running.
5. **Presence proof and channel.** Each approval needs a presence proof (lane 15: the presence key
   with Touch ID, or an approval on a second device). Approvals go through the cloud (lane 15
   approval ops on the owner's devices), never over the link: the link refuses approval ops.
   **A LAN-only server (no cloud) therefore denies every remote side effect;** remote reads inside
   the workspace still work.
6. **Offline approver.** No answer in 10 minutes: deny, and the chain is cancelled.
7. **Revocation** (section 10) cancels the chain, its child sessions, its open approvals and its
   queued outbox.

## 7. Params and content

- `initial_command`, `command`, `tmux_start_command`, `pane_start_command` are refused on every
  method, with no exception.
- Unknown params are refused (no pass-through). New ID-shaped params are denied until scoped.
- `message.send` and `message.edit` accept only `text` parts; `work` parts and approval parts are
  refused by name.
- `runs[].link` is displayed as text and opened only by a user click on the MacBook.

## 8. Outbound filter and redaction (allow-list)

- The remote writer serializes **remote-only structs** (a projection, not the local types with
  fields removed): `RemoteSummary {id, title, participants: [{id, kind, display_name}], last_seq,
  rev, updated_at, last_message}`, `RemoteMessage {id, seq, author, parts (text only), reply_to,
  created_at, edited_at, retracted_at, reactions, origin}`. `acp_session`, `work.session`,
  `work.host`, `work.preview` (it can carry secrets) and `read_cursors` keyed by other participants'
  ids are not in the projection; the peer gets only its own read cursor.
- Events allowed at the writer: `conversation-changed` and `conversation-typing` for owned
  conversations only. Everything else is dropped there, including `pairing-requested` (it carries
  the pairing code, today sent straight to the writer by `subscribe`), terminal output, tree
  events and `ClientChanged` echoes.
- Errors to the remote are codes only, never text with paths or ids. Mapping: `unknown_conversation`,
  `unknown_message`, `not_participant` and every gate refusal -> `remote_denied`; kept as is:
  `actor_mismatch`, `not_author`, `invalid_parts`, `idempotency_conflict`, `cursor_regression`,
  `approval_required`; anything else -> `remote_error`.
- Projections for every event change: `Change::Message` and `Change::MessageUpdated` ->
  `RemoteMessage`; `Change::ReadCursor` -> sent only for the peer's own cursor;
  `Change::Conversation` -> `RemoteSummary`.

## 9. Policy tests (red first, before the feature)

Transport and gate:
- `RemoteRelay.is_unix()` is false, and url-open, loopback-open and a resource-protocol frame
  from a remote connection are refused before their routers.
- a stream without a stamp; a stamp on the admin socket; a stamp from a process that fails the
  peer check (wrong uid or signature); stamp fields inside a frame are ignored.
- an absent principal on the remote entry is refused (no `LOCAL_USER` default).
- table test over every daemon command: only section 4 commands pass; `conversation-search`,
  `conversation-tabs`, `new-conversation-tab`, `conversation-agent-token`, `conversation-bind`
  are refused.
- `set-client-info` with `capabilities: ["loopback-forward"]` is refused; `user_id`,
  `display_name`, `device_*` are ignored (the principal stays the stamp).
- `subscribe` with `surface` or `tree_events` is refused; a pending pairing request is never
  written to a remote connection.

Ownership and mapping:
- pairing adds `remote_<install>` to the owner's conversations; owner peer: `message.send` into a
  `user_local + agent_mux + remote_<install>` conversation succeeds; the stored author is
  `remote_<install>` and the message has `origin.kind == "remote"`; `actor: "user_local"` in a
  remote request gives `actor_mismatch`.
- `message.edit` or `message.retract` of a `user_local`, agent or other-device message:
  `not_author`.
- non-owner peer: list is empty, snapshot of an owner conversation gives `remote_denied`.
- unknown and unowned ids give byte-identical errors.
- each command-bearing param on every allowed method, a `work` part and an approval part are
  refused.

Redaction:
- a serialization test: the remote JSON of a summary, a message and each event contains only the
  section 8 fields (allow-list check, so a new local field cannot leak).

Participants (section 5):
- after pairing, the Chief's wake behavior on a plain local message is unchanged (person count);
- pairing into a conversation at its person budget fails and is reported;
- `participants.add_system` and `participants.remove_system` from a remote peer, a local client or
  an agent: refused; after remove, the device's old messages keep their author and no op is
  accepted as that participant.
- `Change::ReadCursor` of another participant and `Change::Conversation` are projected (or
  dropped) as section 8 says.

Turns and revocation:
- a remote-origin turn asks approval for a write tool and for an outside read; the origin reaches
  a child session and a `[mux-event]` follow-up; it ends at a local human message; an approval
  without a presence proof is not accepted; an unanswered approval after 10 minutes denies and
  cancels the turn; memory-file and scheduled-automation changes ask approval.
- a prompt with one remote and one local message is fully remote; a local message during a running
  remote chain does not clear its mark; a bypass-mode child of a remote chain still asks.
- no setting, `CLAUDE.md`, hook config or permission mode lowers the minimum; an unclassified tool
  asks; the hook's timeout or a daemon error denies.
- revocation recheck with an injected clock: 24 hours -> new streams refused, 72 hours -> existing
  closed, unreachable cloud before that closes nothing.
- revocation cancels the turn, its children, its open approvals and its outbox, and closes the
  stream; also while the server is offline from the cloud (section 10).

## 10. Revocation

- A revoke from the cloud (`host.revoke`, `install.revoke_by_team`) reaches the server through its
  cloud connection; in one step the server deletes the pairing record of that install, runs
  `participants.remove_system` for its `remote_<install>`, closes its streams and cancels its
  remote-origin chains (section 6, rule 7).
- Offline from the cloud (D-D, decided): the link rechecks each paired install with
  the control plane every 5 minutes and on each new stream. An unreachable cloud is not a revoke:
  - last good check older than **24 hours**: new streams from that install are refused, existing
    streams stay;
  - last good check older than **72 hours**: existing streams are closed too;
  - a check that says "revoked": everything at once, as above.
  Tests use an injected clock.

## 11. Open items

1. Lane 12: `cmux link` does not exist yet. Proposed contract (lane 12 v4): link socket 0600 with
   uid and code-signature checks; `link.dial {host: install_id, service: "daemon"}` returns a
   daemon-protocol stream and `host.watch` path events; first slice direct path only, pairing
   record peers, no relay. Coordinator decision pending.
2. The pairing record on the server: `cmux server pair` (branch feat-cmux-next-server-pair)
   stores `{host, team, user, install}`; the gate reads `user` as the owner.
3. The MacBook side: the `paired` `MachineRegistry` kind runs the existing `ConversationMirror`
   against the link stream with no local-admin assumptions.
4. Attachments (future): a fetch is scoped to an owned message's attachment, never by path.
