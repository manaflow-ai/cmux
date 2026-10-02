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

Actor (owner-stamped): the owner derives every write's actor from the connection. A trusted local
(Unix) connection is `user_local` until it runs `conversation-bind {participant, token}` with a token
minted by `conversation-agent-token {participant}` (callable only by a `user_local` connection; the
owner stores the token's SHA-256, a new token replaces the old one). `actor` in requests is optional;
naming anyone but the connection's principal is refused (`actor_mismatch`). The app mints the mux's
token and hands it to the brain host in a 0600 file (`MUX_AGENT_TOKEN_FILE`). Remaining gap: any
same-uid process is `user_local` (socket mode `automation`, D16) until the launch credential lands.

Agent turn budget (owner-enforced): an agent `message.send` is refused with `agent_budget` after 4
agent messages since the last human message in that conversation, and with `agent_rate` within 2 s
of the last agent message. Replays of committed keys are never refused (the ledger is checked
first). The brain host retries an `agent_rate` reply once after the gap and drops `agent_budget`.

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
  turns, enforced by the owner (rejects `agent_budget`, `agent_rate`; built in phase A), so two muxes
  cannot loop.
- Non-owner prompts: a non-owner may talk to a mux; any op beyond `read` and replies becomes an
  `approval` part addressed to the mux's owner (`approval.request` / `approval.decide`).
- Unread: cloud unread comes from `UserDO` folding read cursors; local unread is computed by the app from
  the local owner's read cursors.
- Promotion: `conversation.promote` copies a local conversation into a new `ConversationDO`; the local
  one becomes read-only with a pointer. No automatic sync between kinds.

## 6. Phase A status (2026-10-02)

- Daemon owner: crate `cmux-conversation` + `conversation_store.rs`, capability `local-conversations-v1`
  (trusted local Unix connections only). Hosted focused run green (36967786594); the full run is
  being fixed. The app lists the capability in `awaitingPin` until the next cmux-tui pin cut, which
  belongs to the Rust CLI session; until then a tagged build needs `CMUX_NEXT_TUI_BIN=<hosted binary>`.
- App: Cmd-1 / `home.show`, Home row, `showsHome`, `HomeService` (mirror + intent log per open
  conversation, seeded property test against a reference owner), `HomeWindowModel`,
  `HomeTranscriptAdapter`, `debug.home`, `scripts/cmux-next/home-e2e.py`.
- Renderer: `CmuxNextHome` (port of MessagesLab appkit-virtual). The 1M-message bench of the module
  and of the prototype has not had a valid low-load run yet (machine load 100 to 180 for hours).
- Brain host: `mux/` (Bun; `bun run build` -> `mux/dist/mux`; 22 tests). The app starts it when
  `CMUX_NEXT_MUX_HOST` names that executable.
- Built since: owner-enforced turn budget, owner-stamped actor (`conversation-bind`), Markdown
  rendering of other participants' messages. Known gaps: no `request-settled`; edits/retractions by
  humans do not wake the mux; reply counts and thread connectors are not drawn.

## 7. Home = workspace (user decision relayed by the coordinator, 2026-10-02)

Home is a normal workspace with `kind: home`. Everything that works on a workspace (pinning,
sidebar section layouts, custom images, moves inside its section, panes, splits) applies; the
conversation UI is pane content. This replaces the per-window `showsHome` overlay of section 3.

Record shape (workspace store; proposal for the sections lead and the state-module owner):

```
Workspace {
  ...existing fields (id, name, icon/emoji/image, color, pinned, group, screens/panes/tabs)...,
  kind: "normal" | "home",                 // default "normal"; written only at creation
}
```

- Owner rules (workspace store reducer): at most one `kind: home` per store. The store creates
  it on first start (`workspace.create {kind: home}` with the fixed idempotency key `home`), so it
  exists offline and with no account. `workspace.close` of a home workspace is rejected
  (`home_not_closable`); moving it out of the first position of its top section is rejected;
  renaming, icon, emoji, image and color are allowed. No new presentation flags: `kind: home`
  implies tab bar hidden, fixed at the top, not closable; the client derives those from `kind`.
- Content: panes with tabs as in any workspace. New tab kind `conversation`
  (`{kind: "conversation", conversation: "conv_…", owner: "local"|"cloud"}`), a store record like
  frontend browser tabs, whose content is rendered by the client from the conversation owner. The
  default Home layout is one pane with the mux conversation tab (the chief/coordinator UI); the
  conversation list is a sidebar section or a second pane, not window chrome.
- Entry points: Cmd-1 = first item of the first top section (Home by default, sections lead);
  `home.show` = select the home workspace (a normal workspace selection, so `WindowState.workspaceID`
  names it; nothing Home-specific in window state).
- Client: `HomeView` becomes the pane content of a `conversation` tab (`HomeWindowModel` becomes
  per tab: the tab names the conversation, so selection is the tab, not view state); the mirror,
  intent log, adapter, renderer and the daemon conversation owner are unchanged.
- Migration from this branch: drop `WindowState.showsHome`, `HomePresenter`, `HomeNavigation`,
  `SidebarModel.isHomeActive` and `.selectHome` (the sections lead's Home item becomes the home
  workspace row), keep `home.show` with the new meaning, keep `SidebarNumbering` until the sections
  lead generalizes it.

## 8. Proposal: move the brain host into `cmux` (for the coordinator to ask Lawrence)

Phase A runs the brain host as a Bun-compiled executable named by `CMUX_NEXT_MUX_HOST` (DEV only,
outside the bundle). The target is one `cmux` binary (U7) where the brain host is a supervised role
next to acpmux, with no extra runtime on the Mac. Options:

1. Rust port (recommended). The host's hot paths are small and already typed: the daemon client
   (`local-conversations-v1`), the acpmux client (`session/new`, `session/prompt` with promptId,
   `_acpmux/watch`, `_acpmux/attach`), the inbox (wake rules, catch-up from the agent read cursor,
   turn folding, `turn:<session>:<seq>` reply keys), the supervisor (`mux.parent` children, work
   cards, `[mux-event]` prompts) and the pid lock. In Rust they become an actor in the acpmux role
   that talks to the conversation owner in-process (no socket, the owner stamps the mux principal
   directly) and to acpmux in-process. The OptMem memory (`wake`, `zoom`, `compact`, `toLines`, git
   file store) is about 300 lines of pure TypeScript and ports directly; compaction keeps using an
   acpmux summarizer session. The `mux` CLI verbs become `cmux mux memory|agents|hook|compact`.
   Cost: one owner for the Rust code; the TypeScript stays as the cloud brain (MuxDO) only.
2. Embed the TypeScript brain in `cmux` (QuickJS-ng, which the browser host already plans to embed
   per D12). Keeps one brain codebase for cloud and local, but needs Node-like APIs (sockets, child
   processes, file system, git) bridged into QuickJS; more glue than the port, and slower cold start.
3. Keep the Bun executable, bundled in `Contents/Resources/bin` (about 60 MB) and supervised by the
   daemon. Fastest to ship; adds a second runtime and 60 MB to the app; does not reach Linux hosts
   without a second build.

Recommendation: option 1 for the local host (small, in-process with both owners, no extra runtime);
keep `packages/brain` in TypeScript for the cloud MuxDO. PATH for agents stays the phase A stand-in
(user tool directories) until D26 decides the daemon login environment.
