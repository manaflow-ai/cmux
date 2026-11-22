# The Feed page: React views, daemon owner

Status: plan, 2026-11-06, lane small-views-react (feed part). Binding: feed.md (item model, lifecycle,
ownership), react-pages.md (page pattern), OWNERSHIP-PRINCIPLES.md. Leo, 2026-11-06: "ok we need to go
all hands on deck here. don't just do baby steps. we can just... do it".

## 1. What moves

| Today (Swift) | After |
| --- | --- |
| `CmuxNextFeed` views (list, inbox, detail, answer controls, Reports basket, Needs you) | `webviews/src/pages/feed/` (one page, routes `#/inbox`, `#/list`, `#/needs-you`) |
| `FeedModel`, `FeedLedger`, `FeedOrderedIndex`, `FeedIntent.apply`, `FeedGrouping`, `FeedInboxFilter`, `FeedRowContent`, `FeedChoiceValidation`, `FeedDrafts` (drafts become page state) | `cmux-feed-core::client` (pure, no I/O) |
| `CloudFeedSource` (`/v1/wire/feed` socket, presence, resend) | the daemon's feed client (`cmux-tui-core`), on the app's cloud lease (`cloud-session-set`) |
| `InMemoryFeedSource` / `LocalFeedSourceAdapter` (GitHub items, update cards) | `cmux-feed-core::client::IntegrationOwner` in the daemon, in memory as today |
| `GitHubFeedSource`, `GitHubCLIClient` (`gh api` polling) | the daemon (`gh api`, same queries, ETags, 120 s default interval) |
| Reports basket mailbox reader and reply | the daemon (acpmux mailbox `reports:<user>`, reply through acpmux) |
| `FeedHostView` in the Inbox page tab and the right sidebar section | `PageWebView(descriptor: .feed)` in the same two hosts (the Shift-Cmd-I Feed panel was removed on base, e5eef45664c4) |

Stays native (glue or security): `FeedApproveProofCheck`, `AcpmuxPermissionFeedBridge`,
`FeedInstallPrincipal`, `FeedPendingConfirm`, `FeedHandoff*`,
`FeedGitHubActions` (types commands into a terminal), `FeedControl` socket verbs, notification
banners. They read feed state through the daemon ops below, never a Swift mirror.

## 2. Daemon ops (`feed-client-v1`)

Only the app's own process reaches these ops: its verified main connection (not bound to an agent) or
a page relay of that same process. An agent or a script on the socket gets `origin.forbidden`
(`app_process_only`) for reads too: the view holds the person's whole feed, Reports and GitHub results.

The page calls `cmux.feed.<op>`; `DaemonPageRelay` forwards it to the daemon as `feed.<op>`. Native
callers use the same ops. Times are Unix ms. Every mutation takes an idempotency key.

| Op | Kind | Params -> result |
| --- | --- | --- |
| `feed.view.read` | read | `{layout: "list"\|"inbox"\|"needs_you", filter?: {connection: "feed"\|"github", category: "all"\|"unread"\|"needs_you"\|"notices", query?: string}, tz_offset_min?: int, limit?: int (<= 2000)}` -> `FeedView` |
| `feed.view.changed` | stream | daemon event `feed-view-changed {revision, changed: [id]}` once per commit that changes anything shown (`changed` names the items whose value moved; empty for a connection change alone); the reader re-reads the view or `feed.item.get`s the changed ids |
| `feed.item.get` | read | `{ids: [string] (<= 500), confirmed?: bool}` -> `{items: [ViewItem]}`; with `confirmed: true` the owners' items only, wire JSON without this client's overlay or the view fields |
| `feed.items.list` | read | `{state?: "open"\|"closed", home?: "cloud"\|"local", confirmed?: bool}` -> `{items}` newest first, bounded by the mirror (native consumers; `confirmed: true` as above) |
| `feed.intent` | mutation | `{kind: "answer"\|"decline"\|"read"\|"archive"\|"snooze"\|"mark_all_read", item?, items? (a read takes 1..2000, every item a view shows, so Mark All Read is one call and one gesture, and the daemon sends the cloud owner ops of at most 256 ids, its limit per op, settling the intent once all settled; archive and snooze take 1..256), answer?, until?, before?}` -> `{settled: true}` once every owner it went to settled it, `{settled: false}` when none did within 15 s (it stays pending and shown; its settle line ends it and `feed-view-changed` says so). A retry with a settled key answers again without a second op. Refusals: `feed.closed` (details `{item}`: the owner's item), `feed.moving`, `feed.disconnected` (a cloud item while the owner is unreachable: nothing queues), `feed.rejected`; a malformed intent or an incomplete choice answer is `validation.invalid` |
| `feed.post` | mutation, app connection only | `{item: FeedItem}` into the integration owner (dedupe as `InMemoryFeedSource.post`) -> `{id, deduped}` |
| `feed.withdraw` | mutation, app connection only | `{dedupe_key}` -> `{cancelled: [id]}` |
| `feed.github.configure` | mutation, app connection only | `{enabled, interval_s?}` (120 by default, clamped to 30..3600) -> `{enabled, interval_s}`; on starts the poller, off stops it |
| `feed.github.refresh` | mutation | `{}` -> `{enabled}` (a user wakeup; the poller's in-flight guard drops one during a pass) |
| `feed.github.find_work` | read | `{}` -> `{reviews: [GitHubWork], assigned: [GitHubWork]}`, `GitHubWork = {id, number, title, url, repo, author?, body?, state?, branch?, updated_at}` (the Find Work palette; read now with `gh`) |
| `feed.reports.read` | read | `{}` -> `{revision, available, reports: [{id, sender, body, created_at}]}` (newest first, at most 200) |
| `feed.reports.changed` | stream | daemon event `feed-reports-changed {revision}` |
| `feed.reports.reply` | mutation | `{to (the sending session), text (<= 64 KiB), prompt_id?}` (the prompt id defaults to the idempotency key, so a retry delivers once) -> `{sent: bool}` |
| `feed.presence.set` | mutation, app connection only | `{active}` -> `{active}` (the owner's push rule; an activation also wakes a Reports reader that gave up). Active belongs to the connection that set it: when it closes, cleanly or not, the owner hears inactive unless another frontend still holds it; a new daemon starts inactive |

Wire names: the ops are a routed namespace (`feed`, owner `feed`) and a page entry (`feed`) in
`cmux-tui/spec/page-router.json`, not catalog operations. The page's reads are `read`; `feed.intent`,
`feed.github.refresh` and `feed.reports.reply` are `gesture`; the app-only ops are on no page. The
page hears `feed-view-changed` and `feed-reports-changed` (`cmux.feed.view.changed`,
`cmux.feed.reports.changed` to the page). A refusal is the catalog's `operation.failed` with the feed
code in `details.extra.code` (and `details.extra.details.item` for `feed.closed`); an app-only op from
any other connection is `origin.forbidden {reason: "app_connection_only"}`.

`FeedView`:

```
{revision, loaded, account: {id, user} | null, connection: {state: "connecting"|"connected"|"disconnected", reason?},
 counts: {open_requests, unread_notices, badge, unread},
 github: {enabled}, reports: {available},
 groups: [{id: "requests"|"rest"|"needs_you"|"today"|"earlier", entries: [Entry]}],
 total}
Entry = {id, item: ViewItem, members: [ViewItem] (thread members after the head), unread}
ViewItem = the item's wire JSON (FeedDO shape, snake_case: id, home, kind, title, body, prompt, priority,
  dedupe_key, thread, context, attachments, actions, expires_at, poster, state, answer, cancel,
  read_at, seen_at, archived_at, snoozed_until, count, revision, created_at, updated_at, closed_at)
  plus pending: bool,
  row: {headline, detail?, detail_is_code, who?, where?, icon, urgent, dimmed, local},
  github?: {title, repo, number, url, body?, branch?, checks: [{name, conclusion}]},
  github_actions?: ["open"|"checkout"|"start_agent"|"approve"|"request_changes"|"comment"]
  (the wire JSON also carries the derived `type`: "notice" or "request")
```

`loaded` is true only once the cloud owner's snapshot came for this account (the integration owner,
in the daemon, is always current). Before it, while connecting or after a first connection that
failed, the view may be empty without meaning that nothing waits; an account change unloads it
again. A reader that replaces a whole set from the view (the phone's Needs you, Home's notices) acts
only on a settled view: loaded, or signed out (`connection.reason == "signed_out"`, no cloud part).

`account` is the cloud lease's person the view is for (`id`: the lease identity, `stack:<project>:<user>`
or `selfhost:<origin>:<user>`; `user`: the person's user id), set as soon as the lease names it, before any
snapshot; null signed out. Whatever a reader keeps from a view belongs to that account: a view of another
account, loaded or not, or signed out, drops it at once without sending an empty set. The phone's Needs you
(`FeedNeedsYouPhone`, `MobileHostSupervisor`) hands a kept set only to a hostd of the same user, so a sign-in
as B never shows B's phones A's requests; a disconnect of the same account keeps it.

`connection` is the cloud owner's: `disconnected` reasons are `signed_out`, `expired`,
`unauthenticated` (the app hears `cloud-session-needed` and renews the lease), `forbidden`,
`unavailable` and `offline`. Items of the integration owner stay writable while it is down.

`list` gives `requests` (open requests by priority, then newest) and `rest` (newest first);
`inbox` gives `needs_you`, `today`, `earlier` (by the reader's calendar day, `tz_offset_min`), with
thread members collapsed under the newest; `needs_you` gives `needs_you` only. Archived and snoozed
items are out; a snooze that ends shows again with the next read.

Opening an item's context (terminal, tab, browser tab, sign-in pane, URL) is a native UI op:
`cmux.app.action.run {action: "feed.openItem", args: {item}}`. GitHub actions run
`feed.githubAction {item, action, comment?}`. Strings are the page's (generated from the
Feed xcstrings); the daemon returns no display text beyond item content and names.

## 3. Page

`webviews/src/pages/feed/`: `model.ts` (pure: filter state, selection, drafts, choice validation
for the Send button, relative time), `FeedPage.tsx` (route switch), `InboxView.tsx` (tabs GitHub /
Feed / Reports, filter field, category menu, Mark All Read, Refresh, grouped list beside the
detail), `ListView.tsx` (title, badge, Mark All Read, request cards with inline answers, rows),
`NeedsYouView.tsx`, `ReportsView.tsx`, `AnswerControls.tsx` (approve, choice, question, confirm,
review, sign-in, passkey, handoff, file, input, custom), `store.ts` (reads `feed.view.read` on open
and on each `feed.view.changed`, a newer read supersedes an older reply; no polling),
`mockProvider.ts`, `feed.gallery.tsx`. Lists virtualize past 200 rows.

## 4. Slices

| # | PR | Gate |
| --- | --- | --- |
| F1 | `cmux-feed-core::client` + daemon feed client, ops, GitHub poller, reports | cargo tests |
| F2 | the React page against a mock provider, gallery variants | bun tests, tsc |
| F3 | Swift hosts the page in the Inbox tab and the sidebar; native consumers read the daemon; delete `CmuxNextFeed`'s views, model, sources and their tests | compile check, Swift tests |

## 5. F1 as built

- `cmux-feed-core::client` holds the pure parts (mirror, overlay, ledger, integration owner, the
  `FeedDO` stream state machine, GitHub mapping and state, Reports basket, view builder). The
  daemon's `feed_client` (cmux-tui-core) runs three threads, each ending at `Mux::shutdown`: the
  cloud driver (waits on the socket, a backoff of 1 s doubling to 30 s, or a new lease; a queued
  frame interrupts the receive through `CloudWire::interrupter`), the GitHub poller (only while on;
  waits the interval or a wakeup) and the Reports reader (one `_acpmux/mail/wait` per pass on
  `reports:<the lease's Stack user>`; while acpmux is down it retries with a backoff of 250 ms
  doubling to 30 s and stays at 30 s, one failed local connect each; a wakeup ends a wait).
- The socket is opened through the cloud link's backend with the lease's bearer
  (`CloudConversations::open_owner_wire`), so the token stays in that crate. Not
  `cmux_cloud_wire::StreamMirror`: the feed owner's events carry the changed items, not the op log.
- The item place (`row.who` / `row.where`): the daemon resolves `context.tab` (`tab_…` or a
  surface id), else `context.terminal` (`term_…`), else `context.acp_session` (the bound agent chat
  tab) to the workspace's display name, the tab's display title and its harness
  (`server/feed_places.rs`), from one snapshot per read taken before the feed lock; else
  `context.workspace` names the workspace alone, and an unknown id falls back to the poster. A
  rename shows on the next read: it emits no `feed-view-changed` of its own. No keepalive probe on the
  feed socket (a dead socket is found by its close or the next send). `FeedWireEncode.post` was
  unused in Swift and is not ported.
