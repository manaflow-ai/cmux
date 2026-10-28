# Home DMs and group chats: end-to-end audit (2026-10-19)

Ask (Lawrence, u2422): "Make sure that direct messages and group chats work inside of Home."

Scope: person-to-person DMs (`dm`) and multi-person groups (`group`) in the native Home
(Messages view, `CmuxNextHome` + `MessagesLab`) and the Channels webview, local and cloud owner.
Message requests, invite Accept/Decline/Block and the `addr_…` decode fix belong to
`plans/cmux-next/home-messaging-invites/` (a111) and are not repeated here.

Path of one message: Home UI → `HomeStore.perform(HomeOp)` (`CmuxHomeCore`) →
`HomeSourceRouter` → `CloudHomeSource` (cloud owner) or `DaemonHomeSource` (local owner) →
daemon `cloud-conversation-op` (`cmux-tui-cloud-conversations`, allow list `contract.rs:12`) →
Worker `POST /v1/ops` → `ConversationDO` (home-core reducer) → outbox `inbox.bump` per human →
`UserDO` inbox → `inbox:<user>` stream → peer's daemon → `cloud-inbox-changed` → peer's Home row;
the open conversation streams `/v1/wire/conv/<id>` → `cloud-conversation-changed`.

## 1. Status per capability

| # | Capability | Backend (Worker) | Daemon | Mac native Home | Channels webview |
|---|---|---|---|---|---|
| 1 | Start a DM (contact, email) | ok (`dm.open`, by email links a verified owner since f1566d56be9) | ok | ok (compose sheet, sidebar search) | contacts only, no email |
| 2 | Create a group (name, members) | ok (`conversation.create`, 64 max) | ok | ok (2+ picks) | local only |
| 3 | Rename group | ok (`title.set`) | ok | **missing** (no op, no UI; only the Chief name) | missing |
| 4 | Add members | ok (`participants.add`, reach rule) | ok | **missing** | local only |
| 5 | Remove member / leave | ok (`participants.remove`; owner handoff; last human archives) | ok | **missing** | missing |
| 6 | Member list / group info | n/a | n/a | **missing** (header click opens Chief settings only) | count + 4 faces |
| 7 | Sender name/avatar per message in groups | n/a | n/a | **missing** in the MessagesLab transcript the app draws | ok |
| 8 | Read cursor, unread counts | ok | ok | ok | ok |
| 9 | Typing indicator | ok (DO memory broadcast) | ok (`cloud-conversation-typing`) | **local owner only**; the cloud source drops `setTyping` and never decodes the cloud event | receives only |
| 10 | Delivery state, failed + Retry | n/a | n/a | states drawn, **no Retry / Delete UI** (`HomeStore.retry`, `discardFailed` unused) | n/a |
| 11 | Attachments | ok | ok | **cloud chats fail** (`CloudHomeSource` has no upload/fetch) | ok local |
| 12 | @mentions in groups | ok (runs; counts) | ok | received ones bold; **no autocomplete, no mention runs sent** | partial |
| 13 | Mute per chat, notifications | ok (`inbox.mute`, push skips muted) | **`inbox.mute` not on `CLOUD_INBOX_OP_KINDS`** | read-only; `setMuted` refused by both sources; the vendored sidebar's Hide Alerts item has no delegate | display only |
| 14 | History across restart and devices | ok | ok (no daemon queue by design) | ok (`HomeCache`, intent log) | ok |
| 15 | DMs/groups in the Home list next to Chiefs | ok | ok | ok | ok |
| 16 | Palette / CLI / MCP | n/a | `cloud-*` refused to non-app clients (lease gate, intended) | `home.newMessage` palette only (`cli: guiOnly`); **no send, rename, members, leave, mute action** | n/a |
| 17 | Two-account end-to-end proof | workerd vitest with fake Stack JWTs, scattered per op | fake cloud only | none | none |

## 2. Broken or missing, by cause

1. Group management never reached the client. `HomeOp` has no rename, add or remove case
   (`CmuxHomeCore/Model/HomeOp.swift`), though the cloud wire enum already encodes
   `participants.add`, `participants.remove` and `title.set` (`CloudConversationOp.swift`).
2. Mute stops at the daemon allow list, and both Swift sources refuse `setMuted`
   (`CloudHomeSource+Ops.swift:59`, `HomeCoreMapping.swift:173`).
3. Cloud typing: `CloudHomeSource.submit` answers `.setTyping` locally ("not in part 1"); the
   daemon has supported it since `cloud-conversation-typing-v1`.
4. The transcript (`MessagesLabHomeView`) has no sender-name row; in a group every incoming
   bubble looks the same.
5. No Retry/Delete on a Not Delivered row.
6. Cloud attachments: no `upload`/`fetch` in `CloudHomeSource` (HomeSource default throws).
7. No mention autocomplete in the native composer.
8. No CLI/MCP verbs for sending or managing person chats.
9. Reach: two people with no shared team and no connection cannot `dm.open` by user id
   (`not_reachable`); the email path (invite / message request, a111) is the way in. A shared
   group is no connection, so co-members still cannot DM each other by id.
10. Tests: no single two-account scenario covers DM + group lifecycle; mute over HTTP,
    `muted_until`, mention counts after edit, and the 64 cap are untested.

## 3. Plan in this branch (defaults picked; Lawrence never waits)

- A. `HomeOp.renameConversation`, `.addParticipants`, `.removeParticipant` (leave = remove me),
  mapped on the cloud source and the mock; the local owner refuses what it lacks.
- B. Mute: `inbox.mute` on the daemon allow list (spec + Rust test); `setMuted` sent through
  `cloud-inbox-op`; sidebar Hide Alerts / Show Alerts wired.
- C. Cloud typing both ways.
- D. Retry and Delete on Not Delivered rows.
- E. Sender names in group transcripts.
- F. Group info sheet: name (rename), members (add, remove), Leave, Mute.
- G. Registered actions for all of it (palette, row menu, CLI via `cmux action`, MCP):
  `home.send`, `home.renameConversation`, `home.addMembers`, `home.removeMember`,
  `home.leaveConversation`, `home.muteConversation`, `home.unmuteConversation`,
  `home.conversationInfo`.
- H. Proof: one two-account (three-account for groups) workerd scenario through the real Worker
  routes and sockets; failing-first Swift and Rust tests.

Not in this branch (reported as open): cloud attachments upload/fetch (6), mention
autocomplete (7), message requests UI (a111), an app-to-app test against staging with two real
accounts (needs staging credentials).

## 4. Team use (2026-10-24, a625)

Ask (Lawrence): team group chats in cmux-next, so the team uses them instead of another chat app;
run them on Durable Objects unless there is a concrete blocker.

Storage decision: Durable Objects, already in place; no migration. Each conversation (DM, group,
Chief) is one `ConversationDO` (SQLite class since migration v6): one writer orders every op, the
ledger and history live in its SQLite, its hibernatable sockets (`/v1/wire/conv/<id>`) fan out
changes and typing to members, and an outbox bumps each member's `UserDO` inbox (unread, mentions,
mute, push). No blocker found. The one per-group piece not built is people presence (online or
last seen); the DO's socket list can answer it (an attachment per member socket, the way typing
works) when it is built.

Fixed here:
- Reach (`home-reach.ts`): the rule asked only the request's team, which is a session's personal
  team unless it names another, so two members of a shared Stack team got `not_reachable` for a DM
  by id or a group. It now also checks each team of the caller's `UserDO` team index (16.7), each
  confirmed by its TeamDO (`test/home-reach-shared-team.test.ts`).
- New Message (`HomeDirectory`): read `team.members.list` with no team, so it listed only the
  personal team. It now lists the members of every team from `user.teams.list`, each person once
  (`HomeDirectoryTeamMembersTests`).

Still open for team use: online presence per member; a team-wide group made from the roster in one
step (today: pick the members); the `chief.create` and `question.answer` cloud op kinds; an
app-to-app check on staging with two real accounts in one shared team (needs their sign-ins).
