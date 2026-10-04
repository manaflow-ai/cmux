# cmux next: remote conversations on a paired server (relay analysis)

Status: proposal for review (lane 10, server). No code yet. Decisions D1 and D2 of
2026-10-04: the MacBook opens the daemon conversations of a paired Mac mini over lane 12's
`cmux link` overlay interactive stream; the server is a third `MachineRegistry` kind beside
Cloud and SSH machines. This document is the remote relay analysis that
`skills/cmux-socket-policy/references/remote-relay-authorization.md` requires before any code.

## 1. Threat model

- The remote party is a **paired device of the server's owner** (an install registered under
  the owner by `server.pair.approve`, server.md 6.2). It reaches the server's session daemon
  through `cmux link`, which authenticates the peer's install key (lane 12, transport.md 8, 12a).
- A remote connection is treated as a **compromised client**: a stolen laptop, a malicious
  process of the laptop's user, or a forged frame that passed the link. It never inherits the
  trust of a local Unix connection (`user_local`, socket mode `automation`).
- What we protect on the server: terminals, workspaces, agents' sessions, files, the store,
  tokens (agent tokens, install keys), and the user's other conversations' metadata.

## 2. Principal and actor

- The daemon accepts remote frames only from the link's per-peer stream, never on its local
  Unix socket. The link hands each stream to the daemon with the **peer identity** it verified:
  `{install, user, team}` (lane 12 provides the location of this identity; open item 1).
- The daemon maps the peer to a principal `remote:<install>` and stamps every write's actor as
  the cloud participant `user_<user>`. `actor` in a request may be omitted; naming anyone else
  (including `user_local` or an agent) is refused with `actor_mismatch`, as for local
  connections today (home.md 2).
- v1 scope: the peer's `user` must equal the server's **owner** (the `owner` of the host record,
  stored by `cmux server pair` with the credentials). Any other team member is denied
  (`remote_denied`), also when the team policy would allow them later. Revoking the install
  (`host.revoke`, `install.revoke_by_team`) closes the link stream; the daemon also re-checks the
  peer on every new stream.

## 3. Policy: default deny, explicit allowlist

The gate runs in the daemon before dispatch, on every frame of a remote stream (a
`RemoteConversationPolicy` in the server crate, unit-tested without a socket). Anything not on
this list is refused with `error_code: remote_denied` and no detail.

| Command | Allowed? | Scope and shape |
| --- | --- | --- |
| `identify`, `set-client-info` | yes | identify answers protocol version and capabilities only: no socket path, pid, state dir, hostname or window ids |
| `subscribe` | yes, filtered | the stream receives only `conversation-changed` and `conversation-typing` for owned conversations (section 4); every other event kind is dropped at the gate |
| `conversation-list` | yes | only owned conversations |
| `conversation-snapshot`, `conversation-history` | yes | `conversation` must be owned |
| `conversation-op` | partly | kinds `message.send`, `message.edit`, `message.retract`, `reaction.add`, `reaction.remove`, `read_cursor.set` only; author-only rules stay in the reducer |
| `conversation-typing` | yes | owned conversation, actor = the peer |
| `conversation-create`, `participants.add`, `title.set` | no (v1) | adding participants can attach agents that act on the server; create comes back with an explicit decision |
| `conversation-agent-token`, `conversation-bind` | **never** | they mint or bind agent credentials |
| every workspace, screen, pane, tab, terminal, browser, raw, `send-keys`, `terminal write`, server lifecycle, plugin, journal, notification and session command | **never** | not conversation objects |

## 4. Owned objects (ID scoping)

- An owned conversation is one where the participants include `user_local` (the server's own
  user, who is the owner) or the peer's `user_<user>`. The gate resolves the `conversation` param
  against the owner's list on every request; ref forms, prefixes, names and unknown IDs are
  refused (`remote_denied`, never `unknown_conversation`, so the remote cannot probe IDs).
- `message_id` and `reply_to` must belong to that conversation (the reducer already checks;
  the gate adds a test).
- Any new ID-shaped param (`*_conversation`, `*_id`, arrays of them) is denied until the gate
  scopes it; the gate rejects unknown params instead of passing them through.

## 5. Command-bearing params and content

- `initial_command`, `command`, `tmux_start_command`, `pane_start_command` are refused on
  every method with no exception, also where the method ignores them today.
- `message.send` and `message.edit` accept only `text` parts (with `runs`). `work` parts
  (`session`, `host`, `status`) are refused: they name local sessions and hosts.
- `runs[].link` is shown as text on the MacBook and never opened without a user click; the
  MacBook never executes or opens anything from a server reply.

## 6. The required questions

1. **Can an allowed method execute commands or open content on local objects?** No method on
   the list spawns, respawns, writes to or opens a terminal, browser or file. The one indirect
   path is intended: a `message.send` into a conversation with the owner's agent (the OptChat
   Chief) is a prompt, and the agent acts on the server under the owner's identity. That equals
   the owner typing on the Mac mini. Controls: only the owner's paired install; the agent turn
   budget (home.md 2); dangerous agent actions still need the owner's approval levels with device
   proof (lane 15); revocation closes the stream.
2. **Can it mutate or destroy objects the remote does not own?** No: every ID is scoped
   (section 4); edit, retract and reactions stay author-only in the reducer; no create, no
   participant changes, no close or delete exists on the list.
3. **Does it read local state the remote has no business seeing?** Reduced: replies and events
   are redacted at the gate: `Participant.acp_session` is removed, `work` parts keep only
   `status` and `preview`, `identify` carries no paths or pids, and error text never includes
   paths. Message text in owned conversations is the owner's own data.

## 7. Policy tests (before the feature code, red first)

- allow: snapshot, history, list and `message.send` on an owned conversation from the owner's
  install; the stored message's author is `user_<user>`.
- deny: unknown conversation, ref-form and prefix IDs, a conversation that has neither owner nor
  peer as participant; `actor` set to `user_local` or an agent (`actor_mismatch`).
- deny: `conversation-agent-token`, `conversation-bind`, `conversation-create`,
  `participants.add`, `title.set`; every non-conversation command (a table test over the daemon's
  command list, so a new command is denied by default).
- deny: each command-bearing param on every allowed method; a `work` part in `message.send`.
- deny: a peer whose user is not the server owner; a revoked install.
- events: a subscribed remote stream never receives terminal, workspace or other events; an
  event for an unowned conversation is dropped; `acp_session` is redacted.

## 8. Open items

1. Lane 12: where the daemon reads the verified peer identity of a link stream, and the stream
   contract (framing of cmux.wire/1 on the interactive stream). The coordinator asked lane 12.
2. The owner record on the server: `cmux server pair` (helper A, branch
   feat-cmux-next-server-pair) stores `{host, team, user, install}`; the gate reads `user` as the
   owner.
3. The MacBook side: a `ServerMachineSession` in `MachineRegistry` that opens the link stream and
   runs the existing `ConversationMirror` against it, with no local-admin assumptions.
