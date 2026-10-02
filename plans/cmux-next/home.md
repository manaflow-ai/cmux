# cmux-next Home: local conversations, native renderer, the local mux

Status: phase A (local only), Home lead under the coordinator, 2026-10-01. Binding rules:
OWNERSHIP-PRINCIPLES.md, architecture.md. System spec: manaflow-ai/cmux-next-spec
`spec/home-and-agents.md` (D9, D10, D20, D23). Input only: branch `feat-mux` (PR 16279),
`Prototypes/MessagesLab/appkit-virtual`.

## 1. Who owns what (phase A)

| Entity | Owner | Role | Others |
| --- | --- | --- | --- |
| Local conversation: participants, title, messages (seq), edits, retractions, reactions, read cursors | local conversation owner: crate `cmux-conversation` (pure reducer) hosted by the `cmux` daemon (today the cmux-tui daemon process) as its own actor and SQLite file | owner | app, CLI, mux brain host send typed ops |
| Typing indicator | same owner, ephemeral (memory only, never stored) | owner | broadcast only |
| mux transcript (prompts, tool calls, replies) | acpmux, session `mux` | owner | the brain host projects turn ends into conversation messages |
| mux memory (OptMem `LOG.txt` + `TREE/`) | the mux brain host, `MemoryStore` over a local git repo (`$MUX_HOME/memory`) | owner | the mux reads it through hooks and `mux memory` |
| Child agents (ACP subagents) | acpmux on the machine that runs them | owner | the brain host watches them (`_acpmux/watch`), no polling |
| `showsHome`, open conversation, transcript scroll, composer draft | the window (client view state) | client | never persisted, never in workspace ids, never sent |
| Home renderer state (row layers, measured heights, page window) | `CmuxNextHome` view | client | derived |

### Decision: a new local conversation owner, not the workspace store

Local conversations get their own owner (crate + actor + file) inside the `cmux` daemon process,
next to (not inside) the workspace store and the session host:

1. Conversations are not layout. The workspace store holds the arrangement document; putting a
   1M-message, append-heavy log with paging into it would make it the next god store and couple its
   sync (DocDO, D2) to conversation sync (ConversationDO, D10).
2. Same reducer as the cloud: `cmux-conversation` has no I/O and only serde, so `ConversationDO`
   runs the same reducer as a WASM build. Local and cloud speak the same ops and events, so one Swift
   client serves both owner kinds.
3. The daemon process is the right host: it is always running on the Mac, it outlives the app, it
   already authenticates local clients on its socket, and the app is a client of it. A Swift owner in
   the app would make a client the owner (forbidden), and a separate Bun server is what the spec
   removes.
4. The spec overview places it on the "acpmux side" of the one `cmux` binary. Until PR 16174 merges,
   the daemon is the cmux-tui process the app bundles; because the owner is its own crate and actor
   with its own file, moving it next to acpmux is a hosting change, not a redesign.

Persistence: `conversations.sqlite3` in the daemon session state directory (next to
`workspace-registry.sqlite3`; tagged builds: `~/Library/Application Support/cmux/tags/<tag>/tui/<session>/`).
Tables `conversation`, `message (conversation, seq)`, `op_ledger (conversation, idempotency_key,
fingerprint, result)`, `read_cursor`. One SQLite transaction per op holds the write, the ledger row and
the new revision; the event is published only after the commit.

## 2. Wire contract (daemon v2 line protocol, capability `local-conversations-v1`)

Commands use the daemon's `{"id":N,"cmd":"…",…}` framing; replies are `{"id":N,"ok":true,"data":…}`
or `{"id":N,"ok":false,"error":"…","error_code":"…"}`. All fields are snake_case.

Types:

```
ConversationId = "conv_<26 base32>"   (owner-assigned)
ParticipantId  = "user_local" (the Mac's user) | "agent_<name>" (e.g. "agent_mux") | "user_<id>" (cloud)
Participant    = {id, kind: "human"|"agent", display_name, agent_class?: "mux"|"agent", acp_session?: string}
PartRef        = {message_id, part_index}
TextRun        = {start, length, mention?: ParticipantId, link?: string}          (UTF-16 offsets)
Part           = {type:"text", text, runs?: [TextRun]}
               | {type:"work", session, host?: string, status: "running"|"done"|"failed"|"waiting", preview?: string}
Reaction       = {author, part_index, kind: {tapback: "love"|"like"|"dislike"|"laugh"|"emphasize"|"question"} | {emoji}, at}
Message        = {id: "msg_…", conversation, seq (1-based, dense per conversation), client_msg_id, author,
                  parts: [Part], reply_to?: PartRef, created_at (RFC 3339 ms UTC), edited_at?, retracted_at?,
                  reactions: [Reaction]}
Summary        = {id, owner: "local", title, participants: [Participant], last_seq, rev, created_at, updated_at,
                  last_message?: Message, read_cursors: {ParticipantId: seq}}
```

Commands:

| cmd | params | data |
| --- | --- | --- |
| `conversation-list` | `{}` | `{conversations: [Summary]}` newest `updated_at` first |
| `conversation-create` | `{idempotency_key, actor, title, participants: [Participant]}` | `{conversation: Summary, replayed}` |
| `conversation-snapshot` | `{conversation, tail}` (tail 1...500) | `{conversation: Summary, messages: [Message]}` ascending seq |
| `conversation-history` | `{conversation, before_seq, limit}` (limit 1...500) | `{messages: [Message]}` ascending seq, all `< before_seq` |
| `conversation-op` | `{conversation, idempotency_key, actor, transaction?, op}` | `{transaction?, rev, seq?, replayed, change}` |
| `conversation-typing` | `{conversation, actor, on}` | `{}` (ephemeral) |

`op` (tagged by `kind`):

| kind | fields | rule |
| --- | --- | --- |
| `message.send` | `client_msg_id, parts, reply_to?` | idempotency_key must equal client_msg_id; parts 1...16, text <= 64 KiB; reply_to names an existing message part |
| `message.edit` | `message_id, parts` | author only; not retracted |
| `message.retract` | `message_id` | author only; parts become empty |
| `reaction.add` / `reaction.remove` | `message_id, part_index, reaction` (a reaction `kind` object; named `reaction` because `kind` is the op tag) | one reaction per (author, part, kind); add/remove are separate records, so concurrent tapbacks never overwrite each other |
| `read_cursor.set` | `seq` | the actor's own cursor only; monotonic; `<= last_seq` |
| `participants.add` | `participant` | id unique |
| `title.set` | `title` | 1...200 chars |

Rejects use `error_code` `conversation_rejected` with `data`-free `error` text and a stable reason in
the message (`not_participant`, `not_author`, `unknown_message`, `invalid_parts`, `idempotency_conflict`,
`cursor_regression`, `unknown_conversation`). Replaying an op with the same idempotency key and the
same fingerprint returns the stored result with `replayed: true` and emits nothing (invariant 5).

Events (after the normal `subscribe`):

```
{"event":"conversation-changed","conversation":id,"rev":N,"transaction":?,
 "change":{"kind":"message","message":Message}
        | {"kind":"message-updated","message":Message}
        | {"kind":"read-cursor","participant":id,"seq":N}
        | {"kind":"conversation","conversation":Summary}}
{"event":"conversation-typing","conversation":id,"participant":id,"on":bool}
```

`rev` is per conversation and increases by exactly one per committed op, so a mirror that sees a gap
refetches the snapshot. The op reply carries the same `rev` and `transaction`; whichever arrives first
settles the intent.

Identity gap (phase A): `actor` is declared by the client and the owner checks only membership. The
authenticated per-connection identity (ownership.md step "authenticated client identity") replaces it;
the brain host then connects with the mux's launch credential.

## 3. App: mirror, intent log, Home surface

- `CmuxNextDaemon/Conversations`: request types, `ConversationMirror` (confirmed pages by seq, `rev`,
  written only by owner events and fetched pages) and `ConversationIntentLog` (pending `message.send`
  keyed by `client_msg_id`; leaves the log on echo or reject; resent with the same key after a
  reconnect). Visible transcript = mirror + pending intents.
- `CmuxNextHome` (feature UI, no daemon import): the native renderer ported from MessagesLab
  `appkit-virtual` (virtualized CALayer rows, background rasterization, paged window, render-server
  send animation), the conversation list and the composer. Colors come only from `Palette` inside the
  window's theme scope. Outgoing bubbles use an inverted fill (theme foreground, background text), not
  blue (visual rule: no blue accents).
- `CmuxNextApp`: `WindowState.showsHome` (client view state); Cmd-1 = `home.show`, Cmd-2...8 =
  workspaces 1...7, Cmd-9 = last workspace; a Home row pinned above the sidebar list; the workspace
  stays mounted under Home.

## 4. The local mux (brain host)

- The mux is acpmux session `mux` (harness `claude-sr`, cwd `$MUX_HOME/session`, prompt and memory
  hooks there). `$MUX_HOME` defaults to `~/.cmux/mux`; tagged builds use `~/.cmux/mux/tags/<tag>` so
  tests never touch the real memory.
- The brain host (`mux/host`, TypeScript on Bun, re-owned from `feat-mux` `mux/local` + `mux/cli`) is a
  client of two owners and listens on nothing: it subscribes to `conversation-changed` on the daemon
  socket, prompts the mux for each human message (acpmux `promptId` = message id, deduped by acpmux),
  posts the mux's turn reply as `message.send` with `actor: "agent_mux"` and `client_msg_id` = the acpmux
  turn id (deduped by the owner), sets typing while a turn runs, and turns child events (sessions
  tagged `mux.parent=mux`: turn end, permission request) into `[mux-event]` prompts.
- Tools: the shared operation catalog. `cmux mcp serve` (branch `feat-cmux-next-mcp`) is passed to the
  mux's acpmux session as an MCP server, so every cmux call carries `origin: "mcp"`; until that binary
  ships, the mux uses the Rust `cmux` CLI (`origin: "script"`). The `mux cmux` relay from `feat-mux` is
  not ported (it ran arbitrary CLI argv with the terminal's rights).
- Lifecycle: the app starts the brain host detached when Home first opens (one instance per
  `$MUX_HOME`, pid lock), like the acpmux daemon; it outlives the app. Interim: the spec places the
  brain host inside the `cmux` binary; this TypeScript host moves there when acpmux does.

## 5. DMs and @mux (designed now, built with ConversationDO)

- Owner kinds: `local` (this section's owner) and `cloud` (`ConversationDO`, needs an account). Same
  ops, same events, same reducer.
- DM id: `conv_dm_<base32(sha256(sorted(user_a, user_b)))[0..26]>`, so a DM is never duplicated.
  `conversation-create` with kind `dm` is idempotent by that id.
- Participants: humans (`user_…`) and agents (`agent_…` with `owner_user` and `agent_class`). Talking to
  another person's mux = adding their mux participant; it acts with its owner's grants, never the
  sender's.
- Mentions: `TextRun.mention = ParticipantId`. Wake rule: in a conversation with more than one human or
  more than one agent, an agent wakes only on a mention, a reply to its own message, or a DM; with one
  human and one mux it wakes on every human message.
- Budget: at most 4 agent turns per human message per conversation and a 2 s minimum gap between agent
  turns, enforced by the owner (reject `agent_budget`), so two muxes cannot loop.
- Non-owner prompts: a non-owner may talk to a mux; any op beyond `read` and replies becomes an
  `approval` part addressed to the mux's owner (`approval.request` / `approval.decide`).
- Unread: cloud unread comes from `UserDO` folding read cursors; local unread is computed by the app from
  the local owner's read cursors.
- Promotion: `conversation.promote` copies a local conversation into a new `ConversationDO`; the local
  one becomes read-only with a pointer. No automatic sync between kinds.
