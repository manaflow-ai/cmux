# Home state ownership: one writer, durable stores, rebuildable caches

Status: 2026-10-05, branch `feat-cmux-next-chief-one-history`. Lawrence: "we need the same chat
history trajectory to show, always" and "the conversation history [must be] persistent even
across restarts, like in iMessage". Rules: OWNERSHIP-PRINCIPLES.md (one writer per entity, typed
ops with idempotency keys, clients are mirror plus intent log). This file names, for every piece of
Home state, its one owner, where it is durable, which components hold copies, and how each copy is
rebuilt. It is consistent with home.md, home-mac.md, home-messaging.md, chief-mac.md, optchat.md
and chief-done.md; section 5 lists the two places where it changes them.

## 1. The split before this branch, and the fix

On 2026-10-05 Lawrence's laptop had three Chiefs (read-only count, `scripts/cmux-next/chief-home-migrate.py
--tag-glob 'hmchief*'`):

| tag | Chief conversation (tag daemon store) | OptChat memory (`~/.cmux/mux/tags/<tag>`) |
| --- | --- | --- |
| hmchief | 1 message (a compactor notice) | 0 entries; its host still running |
| hmchief2 | no Home data on disk | none |
| hmchief3 | 11 messages (5 human, 5 replies, 1 notice) | 34 entries (5 user, 7 talk, 11 tool, 11 echo), 66 summaries |
| hmchief4 | 1 human message, never answered | 0 entries (its host stopped: acpmux had no claude-sr) |

Each tag had its own mux home, its own daemon session (`cmux-app-<tag>`, its own
`conversations.sqlite3`) and its own acpmux (`~/.acpmux/tags/<tag>`). The Home transcript reads
the daemon conversation; the Chief's memory is the OptChat log. Within one tag they converge: the
host logs every human message after `host.json.logged_seq` and re-posts every reply in its outbox
under the same key. Across tags nothing connected them.

Fix (decision, from first principles): **one Chief home per account, holding the one
conversation owner, the one memory and the one host.** `~/.cmux/chief/<account>/`:

| path | what | single writer |
| --- | --- | --- |
| `tui/<cmux-chief-hash dir>/conversations.sqlite3` | every Home conversation (the Chief's and any other local one) | the Chief owner: cmux-tui session `cmux-chief-<fnv32(home)>`, detached, shared by every build |
| `optchat/chat/{main,tree}`, git | the Chief's OptChat memory | the brain host |
| `optchat/host.json` | the host's cursor (`logged_seq`), outbox, pending turn, children | the brain host |
| `state/host.lock` | flock: one host per home | the brain host |
| `optchat/engine.json` (traces branch) | the Chief's engine (harness, model, effort) | see section 2 |
| `acpmux/` | the Chief's turn, compactor and subagent sessions | the acpmux daemon of that home |

Every DEV tag, NIGHTLY and Release build resolves the same home (`ChiefHome`); isolated launches
(agent preflights with `CMUX_NEXT_NO_ACTIVATE=1`, test windows, showcase,
`CMUX_NEXT_CHIEF_ISOLATED=1`) use `~/.cmux/chief/isolated/<tag>`, and `CMUX_NEXT_CHIEF_HOME` names
one explicitly. A build's own daemon keeps only build-shaped state: workspaces, terminals, the Home
workspace and its tabs (a conversation tab names a conversation of the Chief owner by id).

Why not reconcile per-tag stores from the log instead: a conversation store is append-only with
owner-assigned `seq` and `created_at`, and a human message reaches it before the log. With two
stores, a message typed in tag B while no host serves B lands before history that the log already
holds from tag A, and no append can put it back in order; replaying the log would also need the
host to write messages as the user (a forged-author op the owner rightly refuses) and would stamp
old messages with today's time. One owner makes the order the owner's order and leaves the
existing cursor and outbox to keep the memory equal to it. It is also the shape of the end state:
the cloud ConversationDO is one owner for the Chief main conversation
(`optchat-lab/brains/DESIGN-cmux-lawrence.md` section 1); the local Chief owner is its stand-in.

## 2. Every piece of Home state

| state | one owner (writer) | durable store | copies (caches, projections) | how a copy is rebuilt |
| --- | --- | --- | --- | --- |
| Chief conversation messages | Chief owner (local) or ConversationDO (cloud) | `conversations.sqlite3` (WAL, `synchronous=FULL`, `fullfsync`), DO SQLite `msg` rows | HomeStore mirror (tail window 60, pages of 80), `HomeService.conversations` and sessions, MessagesLab projection; app Home cache (section 4) | inbox snapshot plus tail snapshot on every connect; any `rev` gap refetches; older pages on scroll |
| DMs, groups | same owners (local: user + mux only; cloud: ConversationDO, inbox in UserDO) | same | same | same |
| attachments | uploader writes content-addressed blobs; owner holds refs | R2 by hash (cloud), slot rows in DO SQLite; local daemon stores parts with hashes | `Caches/cmux-home-blobs/<hash>`, `$TMPDIR/cmux-home-media-<pid>` bubble pictures | fetched by hash on demand; blob cache pruned (7 days, 1 GB) |
| read state | the owner (`read_cursor` table, `head.read_cursors`); written only by that participant, monotonic | owner store | mirror summaries | inbox snapshot; a lost cursor op is re-sent by the next visible-newest event |
| typing | the owner, in memory only | none, by design | mirror | none; clears on reconnect |
| compose draft (text, attachment chips) | the client view (one per device) | app Home cache, per conversation (section 4), never synced | the view | restored when the conversation opens |
| pending and failed sends (intent log) | the client | app Home cache: the intent log entries (section 4) | HomeStore `log`, send queue | restored as unconfirmed at launch and resent under the same keys at the first connection; "Not Delivered" stays until retried or discarded |
| scroll position | the client view | app Home cache: newest visible message id and its offset, per conversation | the view | restored at open; a message newer than the anchor scrolls to the bottom |
| OptChat log and tree | the brain host of the Chief home | `optchat/chat`, fsync per message, a git commit per turn | the host's in-memory view; turn sessions see a rendered view | read at host start |
| host state | the brain host | `optchat/host.json` (temp file, fsync, rename) | none | read at start; lost: recovered from the log epoch (chief-mac.md) |
| engine settings | the brain host (traces branch: the app and `chief engine set` both write today; target: both send a typed change the host applies and writes) | `optchat/engine.json` | the engine bar | read at each turn start |
| active app | the app that last opened or activated Home (last writer wins) | `state/app.sock`, `state/app-daemon.sock`: symlinks to its control and tagged daemon sockets (`ChiefAppLinks`) | none: the host and turns get the constant link paths (`CMUX_SOCKET_PATH`, `CMUX_APP_DAEMON_SOCKET`; agreed with feat-cmux-next-chief-ws-routing) | republished on Home open and app activation; a quit removes only its own links |
| subagent links | the brain host (`spawns` in host.json); each workspace is the build daemon's | host.json; workspace registry | the agent pane | reconciled with acpmux at host start |
| traces | the brain host | `optchat/traces/<day>.jsonl` (append-only) | the engine bar's stats | re-read |
| agent token | the Chief owner mints it for the user's connection | `agent_token` (hash only) | `<home>/agent-token` (0600) | minted on every Home open; a new token ends old bindings, the host re-reads the file at reconnect |

A copy is never a writer: the owner's snapshots and events overwrite every cached value, guarded by
`rev` and `seq`, and the client changes owner state only through typed ops with idempotency keys.

## 3. What happens on each event

| event | Chief / local conversations | memory and host | client state (draft, sends, scroll) |
| --- | --- | --- | --- |
| app quit, relaunch | owner keeps running (detached); history unchanged | host keeps running (it outlives the app) | restored from the app Home cache |
| app crash | as quit | as quit | the cache holds what it held at the last write (a draft written per keystroke batch, a send before it is sent) |
| daemon restart (keep-layout or not) | the build daemon's restart touches no conversation; a Chief owner restart reloads its SQLite file (nothing in memory but typing and bindings) | host reconnects, re-reads the token, catches up from `logged_seq` | unchanged; pending sends resend under the same key |
| a new DEV tag build | opens the same Chief home: same owner, same history | the running host keeps serving; its launch exits at once | the cache is per Chief home and account, so the new tag shows the same drafts and sends |
| macOS reboot | owner starts on the first Home open and reads its file | host starts on the first Home open, reads log and host.json, recovers a pending turn (recover.rs) | restored |
| sign-out, sign-in | the Mac Chief is per macOS user (`default`) until the cloud Chief (decided 2026-10-06); cloud conversations need the session | unchanged | the cloud part of the cache stays on disk for the account and shows again at sign-in; nothing is shown signed out |
| switching accounts | `CMUX_NEXT_CHIEF_ACCOUNT` (later the cloud user id) picks another Chief home | another home, another host | the cache is keyed by account |
| network offline | local conversations unaffected; cloud ones show from the cache, Send is off (H17) | local brain unaffected | drafts stay; sends logged before the disconnect resend after |
| the brain moves to cmux-lawrence | the cloud ConversationDO becomes the owner of the Chief main conversation | `memory export --seal` from the Chief home, `memory import` there | unchanged |

## 4. The app Home cache (client-owned, rebuildable)

`~/Library/Caches/cmux-home/<owner key>/` where the owner key is the Chief home's session for the
local owner and `cloud-<user id>` for the cloud source. It holds the last inbox snapshot, the tail
window of each conversation the user opened, the intent log, drafts and scroll anchors. HomeStore
seeds its mirror from it before the source connects (the Home list and the open conversation show
at once, marked not yet live), and writes it after owner snapshots and events, never from its own
intents. Deleting it loses only drafts and unsent sends; the history comes back from the owner.
A quit or forced exit writes the pending batch at once (`HomeStore.flushCache`).
macOS may purge Caches; that is the same as deleting it.

Built on this branch (HomeCache, HomeStore, HomeProjection): the list and opened conversations,
text sends (unconfirmed and Not Delivered) and drafts. Writes are coalesced for 250 ms and done at
once on `HomeStore.flushCache()`, which the app calls at quit and forced exit; a crash can still
lose the last 250 ms of changes. Not built yet: sends with attachments (their local files are not
kept), and restoring the scroll anchor in the view (HomeStore keeps it; the vendored MessagesLab
scroll engine has no entry point to restore an offset, so a conversation still opens at the newest
message). There is no Mac cloud Home source yet (iOS runs the mock); when it lands it gets the same
cache under `cloud-<user id>`.

## 5. Changes to other plans

- home.md section 4 and chief-mac.md: "`$MUX_HOME` defaults to `~/.cmux/mux`; tagged builds use
  `~/.cmux/mux/tags/<tag>`" is replaced by the Chief home above. The host contract
  (`host --daemon-socket --mux-home`, the flock) is unchanged; the socket is now the Chief owner's.
- home-messaging.md line 60 and home.md line 17 ("draft, scroll: client, never persisted"): drafts,
  scroll anchors and the intent log are now persisted by the client in its own cache (Lawrence,
  2026-10-05). They are still never synced and never in workspace ids. H17 stands: the cache
  restores only sends logged before a disconnect; no new send queues offline.
- Home conversations now live in the Chief owner, so a tag daemon's relay of local conversations
  to the iPhone no longer includes them. Accepted until the cloud relay (decided 2026-10-06: Mac
  first, iOS later).
- chief-mac.md section 10 ("This Chief remembers on this device only") stays true: one Chief home
  per Mac account. It is no longer per build.

## 6. Brain move (DESIGN-cmux-lawrence.md)

Decided 2026-10-06 (coordinator): the move carries the conversation, not only the memory. The
export reads the Chief home (`memory export --mux-home ~/.cmux/chief/default --seal`) and adds
`conversation.jsonl`; before the brain starts on cmux-lawrence, the user's session imports it into
the cloud chief main conversation with a `conversation.import` op on ConversationDO (same rules as
the local owner's `conversation-import`: authors and times kept, seqs the owner's, keys skipped,
older history refused), and `memory import` binds the brain's host state with every imported
message logged. The sealed laptop home's host refuses to start; the app then shows the cloud Chief
as the Chief tab (gap G6). optchat-lab `brains/DESIGN-cmux-lawrence.md` section 5 step 3 and gap
G13 (branch `chief-one-history-brain-import`).

## 7. Migration (the app, once)

Decided 2026-10-06 (coordinator): no manual step. A build with the Chief home moves the old
per-tag Chiefs itself when the Chief owner first answers, before Home or the brain host use it
(`ChiefMigration`):

1. Isolated homes, and homes with `migration.json`, do nothing.
2. If any old tag's host still holds its `state/host.lock`, Home shows "Quit older cmux DEV builds
   to merge Chief history" and the owner stays unpublished for this launch; the next launch tries
   again. No process is stopped.
3. The app takes the Chief home's host lock (so no host writes the memory meanwhile), reads every
   old tag store (from a copy) and memory, and plans the merge: messages in time order with ids,
   authors, times and client ids kept, duplicates dropped; the largest memory kept, every human
   message no memory held appended with its own time; an unlogged message dated before the
   memory's last message moves after it, so the chat and the memory hold the same human messages
   in the same order; several memories interleave by time (summaries rebuilt).
4. The owner imports the messages (`conversation-import`, cmux-tui conversation_import.rs): it
   assigns seqs and the rev, keeps authors and times only for an import, skips a key it holds,
   refuses history older than what it holds, and serves trusted local user connections only (an
   agent connection is refused; the remote relay's allowlist does not admit the command).
5. The memory and `host.json` (bound to the Chief conversation, every imported message logged) are
   written; `migration.json` records the move. Old homes and stores stay untouched.

`scripts/cmux-next/chief-home-migrate.py` was removed with this decision: it wrote the owner's
SQLite file directly.
