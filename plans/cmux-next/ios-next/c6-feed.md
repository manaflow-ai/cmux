# C6 `feed`: the Feed tab on iPhone

Status: implemented (device verification pending), 2026-10-08. Branch `feat-cmux-next-ios-c6-feed` off `feat-cmux-next-ios`. Binding:
PLAN.md (this directory), a1-shell.md (seams, 1.14 parity), feed.md (item model 3.1, kinds 3.4,
lifecycle 3.6, read and seen 3.7, ops 6, push 7.3), OWNERSHIP-PRINCIPLES.md.

## 1. Ownership

| State | Owner | On the phone |
| --- | --- | --- |
| items, lifecycle, answers, read/seen/archived | `FeedDO` (one per user) | confirmed mirror, written only from owner frames |
| pending answers, declines, read marks | the user, as intents | one ordered intent log; visible = mirror + log |
| filter, grouping, scroll, open item, composer draft | the phone | client view state, never synced |

No other optimistic copy exists. An intent leaves the log when its receipt arrives and the mirror
has reached the receipt's revision (committed), or at once when refused or not sent. While the owner
is unreachable every control is disabled and an intent throws `offline`; nothing queues. On
reconnect `CloudFeedSource` resends only intents it sent before the drop, with the same keys, and
settles keys the snapshot reports as decided.

## 2. Modules

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSFeatureKit/Feed` | seam: `FeedItem` and its kinds, `FeedReply`, `FeedIntent` (+ pure overlay), `FeedSource`, `MockFeedSource` | Foundation |
| `CmuxiOSFeedModel` | `FeedStore` (mirror + intent log over a source), `FeedFilter`, `FeedGrouping`, `FeedSections`, `FeedNotice` (user-facing outcome of an intent) | Foundation, FeatureKit |
| `CmuxiOSFeedCloud` | `CloudFeedSource` over `/v1/wire/feed`, `FeedMirror` (revision and gap rule), wire codec, `FeedWireTransport` seam (URLSession WebSocket in the app, a fake in tests) | Foundation, FeatureKit |
| `CmuxiOSFeed` | UIKit screens: `FeedViewController`, cards, composer, detail, haptics, `FeedNavigator` | UIKit, SwiftUI, FeatureKit, FeedModel, Design |

Model and Cloud are platform-neutral, so their Swift Testing suites run with `swift test` on macOS
through a scratch package (as A1 did). `CmuxiOSShell` imports `CmuxiOSFeed` only to replace the
placeholder in `ShellContent.controller(for:)`; `CmuxiOSApp` fills `realFactories.feed`.

## 3. Seam changes (C6 owns `FeedSource`)

A1's seam had four kinds and a flat reply. FeedDO's model is richer, so the seam now follows feed.md
3.4 for the kinds a phone can answer and keeps the rest read-only:

| FeedDO kind | `FeedItemKind` | Inline controls |
| --- | --- | --- |
| `approve` | `.permission` (action type, summary, command, cwd, tool, risk, scopes) | Allow (primary), Deny, scope menu (once, session, always as offered) |
| `question` | `.question` (question, suggestions, multiline) | suggestion chips, Reply opens the composer |
| `choice` | `.choice` (1-4 questions, 2-8 options, multi, allow other) | option chips per question, Other opens the composer, Submit when every question has a pick |
| `review` with subject `plan` | `.planApproval` (ref, checklist) | Approve, Request changes (composer for the comment) |
| `confirm` | `.confirm` | confirm and cancel labels, destructive style |
| `notice` | `.done` | summary card; read, archive |
| `sign-in`, `passkey`, `handoff`, `input`, `file`, other reviews, custom | `.unsupported(kind, needsMac)` | read-only, "Answer on your Mac"; Decline stays available |

`FeedSource` is now `updates()` plus `perform(_ intent: FeedIntent) -> IntentReceipt`, where the
intent kinds are answer, decline (`feed.cancel` reason `declined`), read, read all, seen and archive.
`FeedIntent.apply(to:)` is the pure overlay, mirroring the owner's rules: answers and declines apply
only to open requests, open requests are never archived.

## 4. CloudFeedSource

`cmux.wire/1` on `GET /v1/wire/feed`, subprotocols `cmux.wire.v1, bearer.<install token>`.

1. `welcome` names the user; the source subscribes with `pending` = unsettled keys and no `after_seq`
   (resumed log events carry no items, so a resubscribe always takes the snapshot).
2. `snapshot {seq, state.items, decided}` replaces the mirror at `seq`, settles decided keys (receipt
   at the decided sequence, or refused) and resends the rest in send order.
3. `event {seq, items, present?}` upserts the changed items; `present` drops pruned ids. `seq` must be
   mirror + 1: a gap sends `snapshot.request` with the pending keys and ignores events until the
   snapshot arrives. An older or equal `seq` is a duplicate and is dropped.
4. `reject {idempotency_key, code}` is held until `request-settled {idempotency_key, sequence, ok}`,
   which answers the waiting `perform`: committed at `sequence`, or refused with the reason
   (`feed.closed` becomes "answered elsewhere").
5. An `error` frame with an intent's key (the socket gate refused it, for example
   `owner.unreachable`) refuses that intent; one without a key while a snapshot is awaited ends the
   session. A socket error ends the session; the source shows offline and reconnects after a
   doubling delay on an injected clock (500 ms to 30 s, reset on a snapshot). No polling.
7. The socket stays open while a screen subscribes or an intent it sent is unsettled, so leaving
   the tab right after an answer never reports a committed answer as failed.
6. Every snapshot it yields is coalesced newest-only per subscriber, like `MockSnapshotHub`.

Ops go out as `op` frames with origin `user`; answers use the kind's answer schema (feed.md 3.4). The
DEV mock/real switch picks it: `AppContainer.realFactories.feed` is filled when the API origin and
install identity exist, else the seam stays on the mock and DEV shows "not registered".

### 4.1 Reliability hardening (2026-10-08)

`CloudFeedSource` treats an idempotency key as one local operation as well as one owner operation.
Concurrent callers that reuse a stable key share the single outbound `op` frame and all receive its
one settled receipt, including callers that join while a replacement socket is still reconnecting.
`FeedStore` derives the same `FeedPushIntent` key for equivalent in-app answer and read actions, so a
lock-screen HTTPS action racing the Feed tab carries the same owner key even though the transports
are separate. `CmuxiOSFeedCloudTests` covers fan-out and reconnect joining; model and push tests pin
the shared key mapping. Device and real-network verification remain the D3 gate below.

## 5. Screen

- `UICollectionView` list (compositional, diffable by item id, reconfigure on change, no animation
  under Reduce Motion). Card content uses `UIHostingConfiguration` (SwiftUI inside the UIKit cell):
  low-frequency rich controls, while the list, diffing, swipes and navigation stay UIKit.
- Header: segmented filter (Needs input, Unread, All), menu with grouping (none, workspace, agent),
  Mark All Read. Sections: with grouping none, "Needs input" then "Earlier"; otherwise one section per
  workspace or agent, open requests first inside it.
- Snoozed and archived items never show (snooze itself is not offered on the phone yet).
- Read: opening an item (tap pushes the detail) reads it; Mark Read swipe; answering reads it. Seen:
  cells that display while the screen is visible are reported in one `feed.seen` per main-actor turn,
  so the owner does not push what the user already saw (feed.md 7.3).
- Swipes: leading Mark Read; trailing Archive (closed items) or Decline (open requests, destructive).
- Empty states with `UIContentUnavailableConfiguration` per filter; offline banner while the
  connection is not live, plus an offline empty state when there is nothing to show.
- Haptics: success on a committed answer, warning on a refusal, error when not sent; selection on
  chips. VoiceOver: each cell is one element with a combined label and custom actions for every
  inline control (Allow, Deny, each option, Reply, Approve, Request Changes, Mark Read, Archive,
  Decline). Dynamic Type through text styles only; chips wrap.
- Push: `FeedNotificationResponder.openItem` selects the tab and opens the item via `FeedNavigator`
  (parked until the screen exists).

## 6. Parity with the shipping app (a1-shell.md 1.14)

Covered: Needs Input filter, full text (detail), permission allow/deny with scopes, plan approve and
revise with feedback, multi-question answers with Other, free-text reply, resolution labels,
offline state. Gaps: a refusal settled from a reconnect snapshot's decided keys carries no reason,
so it is not labeled "answered elsewhere"; plan "modes" (auto-accept, bypass) have no field in FeedDO's `review` answer;
the quoted-reply reference and per-terminal reply fallback belong to the terminal path (D1/C7). Banner
categories and inline push reply stay C7.

## 7. Verification

- Swift Testing: `CmuxiOSFeedModelTests` (overlay, retire on revision, refusal and offline, filters,
  grouping, sections), `CmuxiOSFeedCloudTests` (decode, encode, mirror gap rule, source over a fake
  transport: snapshot, settle, decided keys, reconnect resend, gap resync), updated FeatureKit tests.
- `CmuxiOSApp` compiles for `arm64-apple-ios17.0-simulator` with SwiftPM.
- Tagged build `nxc6` through `ios/scripts/reload-cloud.sh`; blockers recorded in the landed line.
