# C7 `notify`: banners, inline actions, Live Activities

Status: implemented (device verification pending), 2026-10-06. Branch `feat-cmux-next-ios-c7-notify` off
`feat-cmux-next-ios`. Binding: PLAN.md (this directory, scope C7, rules 4), a0-rpc.md 5.8 (notify family),
b1-control-do.md (fan-out stays in `FeedDO` and `UserDO`), c6-feed.md (items, intents, `FeedNavigator`),
c16-platform.md 4 (`NotificationRouteDecoder`, `.feed(item:)`), c11-settings.md 1.4
(`NotificationPreferencesSink`, per-kind prefs), a1-shell.md 1.3, feed.md 3.4, 3.6, 7.3.

## 1. Ownership

| State | Owner | On the phone |
| --- | --- | --- |
| whether and when an item pushes, its text, its category | `FeedDO` (`feed.push_due`, feed.md 7.3) | the delivered banner only |
| push targets, this device's push preferences, Live Activity tokens | `UserDO` (`push_targets`, `push_prefs`, `activities`) | intents (`push.target.*`, `push.prefs.set`, `notify.activity.*`) |
| the unread total the badge shows | `FeedDO` counts (open requests + unread active notices) | `aps.badge` on alerts, `cmux.badge` on dismiss pushes, mirror count on foreground |
| answers, declines, read marks from a banner | the user, as C6 `FeedIntent`s with an idempotency key | not kept: one send, the owner settles it |
| which banners are on screen, the Activity UI | iOS | system state, reconciled from owner pushes |

No second copy of any owner state exists on the phone. A banner action is an intent; its key is stable
per (item, action, text), so a repeated delivery of one tap commits once. Nothing queues: a send that
fails says "Answer not sent" on the lock screen and the item stays open on the owner.
The in-app Feed tab derives that same key for equivalent answer and mark-read actions through
`FeedPushIntent.makeIdempotencyKey`, allowing the owner ledger to collapse a banner/tab race even
though the banner uses `/v1/ops` and the tab uses the feed WebSocket.

## 2. Categories and actions

The feed owner names the category in `aps.category`; the app registers every one at launch.

| Category | Feed kind | Actions (in order) |
| --- | --- | --- |
| `FEED_APPROVE` | `approve` without a session scope | Allow (unlock), Deny (destructive) |
| `FEED_APPROVE_SESSION` | `approve` offering `session` | Allow Once (unlock), Allow for Session (unlock), Deny |
| `FEED_QUESTION` | `question` | Reply (text input, unlock) |
| `FEED_PLAN` | `review` with subject `plan` | Approve (unlock), Request Changes (text input, unlock) |
| `FEED_CONFIRM` | `confirm` | Confirm (unlock), Cancel (destructive) |
| `FEED_CHOICE`, `FEED_REVIEW` | `choice`, other reviews | none: a tap opens the item |
| `FEED_SIGN_IN`, `FEED_PASSKEY`, `FEED_HANDOFF` | Mac-only kinds | Open on Mac |
| `FEED_NOTICE` | notices | Mark Read |
| `cmux.terminal` | terminal alerts (Mac relay) | none; a tap routes through `cmux.route` |

Only an action the item's own category offers can answer it (a crafted push cannot answer a confirm with
Allow). Approving needs an unlocked phone (`authenticationRequired`); denying and cancelling do not.

Each answer maps to the kind's answer schema (feed.md 3.4) through C6's `FeedReply`:
Allow/Allow Once/Allow for Session -> `.permission(allow: true, scope: nil|once|session)`, Deny ->
`.permission(allow: false)`, Reply -> `.text`, Approve/Request Changes -> `.plan(approved:comment:)`,
Confirm/Cancel -> `.confirm`, Mark Read -> `FeedIntent.read`. The intent goes out through
`OpsFeedIntentPerformer` (`POST /v1/ops`, origin `user`, the install principal), not the feed WebSocket:
a banner action runs with the app suspended, and one HTTPS request fits the background budget where a
socket welcome plus snapshot does not. `UIApplication.beginBackgroundTask` wraps the send; its expiry
cancels it, which reports "not sent".

Outcomes: committed -> the banner is removed and the badge follows the next owner push; refused
`feed.closed` -> "Answered elsewhere" notice; other refusal or no network -> "Answer not sent", tap opens
the item. A tap (default action) routes through `ShellRouter`: `cmux.route` when present, else
`.feed(item:)` to `FeedNavigator`.

## 3. Remote dismiss and badge

When an item that was pushed (`pushed_at` set) stops needing the user (a request closes, a notice is read
or archived), `FeedDO` sends one background push (`apns-push-type: background`, priority 5,
`content-available: 1`) with `cmux.dismiss = [item ids]` and `cmux.badge = n` to the user's push targets.
The app removes delivered notifications with those identifiers (APNs uses `apns-collapse-id`, the item
id, as the request identifier) and sets the badge. iOS throttles background pushes, so the foreground
path repeats it: when the app becomes active it takes the feed mirror's first live snapshot, sets the
badge from it and removes delivered feed banners whose items no longer need the user. Every alert push
carries `aps.badge`.

`notify.badge.set` (a0-rpc.md 5.8, an owner event on `user:`) is not committed by this lane: the count is
`FeedDO`'s, and committing every read mark into `UserDO` is churn that `UserDO` must avoid (feed.md 4).
The badge reaches the phone in the pushes above; a `user:` stream event can follow when a phone client
subscribes to that stream.

## 4. Preferences (C11 sink)

`CloudNotificationPreferencesSink` implements C11's `NotificationPreferencesSink`: it sends
`push.prefs.set {kinds, sound, time_sensitive}` (new `UserDO` op, install principal, iOS installs only,
kept per install so a later token registration keeps it) and writes the same value to the shared
keychain store for the Notification Service extension. `NotificationKind` and `NotificationPreferences`
move to `CmuxFeedPushCore` so the app, Settings, the extension and the tests share one definition.

`FeedDO` filters per target: an item whose kind the device turned off is not sent to that device. Kind
mapping (same table in Swift and TS, with vectors on both sides): `approve` -> permission; `question`,
`choice`, `confirm`, `input`, `file` -> question; `review` -> plan approval; notices -> finished; items
with a terminal context from a `system` poster -> terminal alert. Sound off drops `aps.sound`.
Time-sensitive on sets `interruption-level: time-sensitive` for permission, question and plan pushes (and
always for `urgent`); off sends `active`.

## 5. Notification Service extension

Runs for every feed alert (`mutable-content: 1`), before the encrypted Mac relay path it already had:

1. Category assignment: a missing or unknown category is derived from `cmux.kind`, `cmux.type` and
   `cmux.scopes` with the same table as the owner.
2. Preference filter: a kind turned off on this device becomes passive and silent. Truly dropping a push
   needs `com.apple.developer.usernotifications.filtering`, which Apple grants on request; until then the
   owner filter in section 4 is the real one.
3. Expired: `cmux.expires_at` in the past becomes passive and silent, body "No longer needs you".
4. Preview shortening: title 80, subtitle 80, body 178 characters on a character boundary with an
   ellipsis, so the lock screen shows a whole line instead of a cut word.
5. Level and sound follow the device preferences (time-sensitive downgraded to active when off).

The decision is a pure function (`PushPresentation`) in `CmuxFeedPushCore`, tested on macOS.

## 6. Live Activities

`CmuxiOSLiveActivity` (package module) holds `AgentActivityAttributes` (host, task or terminal, agent
name) with `AgentActivityState` as `ContentState` (`phase` running | needsInput | done | failed, `title`,
`detail`, `started` unix seconds, `item`), and the widget UI: lock screen banner and Dynamic Island
(compact, minimal, expanded) with the phase, the elapsed timer (`Text(timerInterval:)`) and, in
needs-input, the request title with a deep link to the item. The widget extension target
`AgentActivityWidget` in `ios/cmux-ios.xcodeproj` contains only the `@main` bundle.

`AgentActivityCenter` (app, MainActor) starts an Activity with `pushType: .token`, follows
`pushTokenUpdates` and registers each token with `notify.activity.register {activity, push_token, subject,
title, started_at}`, and sends `notify.activity.end` when the Activity ends or is dismissed. Entry points:
C8's dispatch receipt and C5's workspace row call `start`; DEV has "Start sample Live Activity".

`UserDO` keeps registrations (16 per install, 32 per user, dropped after 12 h, the ActivityKit lifetime,
and with the install). `FeedDO` updates them after each commit: for an activity whose subject matches an
item's `context` (terminal or task, host when both name one), an open request moves it to needs-input
(title, item, alert) and closing the last one moves it back to running. Updates go to APNs with
`apns-push-type: liveactivity`, topic `<bundle>.push-type.liveactivity`, `event: update`. Done and failed
come from the task owner (`task.state.set`, a0-rpc.md 5.9) once B1 mirrors task state; until then the
phone ends the Activity. Push-to-start tokens (iOS 17.2) are a follow-up for the same reason.

## 7. Modules

| Module | Adds |
| --- | --- |
| `Packages/Shared/CmuxFeedPushCore` | categories and actions above, `FeedPushIntent`, `NotificationKind`/`NotificationPreferences` (moved from C11), `PushPresentation` (extension decision), `RemoteDismiss`, `AgentActivityState`/`AgentActivitySubject`, `CloudOpsSending` (moved from CmuxiOSPush), op builders `push.prefs.set`, `notify.activity.*` |
| `CmuxiOSNotifyCore` (new, platform neutral) | `FeedPushIntent` -> C6 `FeedIntent`, `OpsFeedIntentPerformer`, `FeedNotificationReconciler` (badge and stale banners from a feed mirror) |
| `CmuxiOSFeedCloud` | `FeedIntent.wireParams(device:)` (public view of the existing encoder) |
| `CmuxiOSPush` | `FeedNotificationResponder` over intents with a background task, categories, `RemoteNotificationHandler`, `AgentActivityCenter`, `ForegroundNotificationSync` |
| `CmuxiOSLiveActivity` (new) | attributes and widget views |
| `CmuxiOSApp` | `CloudNotificationPreferencesSink` in `notificationPreferencesSinkFactory`, delegate wiring, DEV sample activity |
| `ios/NotificationService` | links `CmuxFeedPushCore`, runs section 5 |
| `ios/AgentActivityWidget` | new widget extension target (uncompiled unless Xcode builds the project) |
| `backend/apps/api` | `push.prefs.set`, `notify.activity.*` in `UserDO`; per-target filter, level, badge, dismiss and Live Activity sends in `FeedDO` and `push/apns.ts` |

## 8. Parity (a1-shell.md 1.3)

Covered: categories with inline actions, time-sensitive level per preference, remote dismiss, clear on
foreground, background inline reply under a background task, badge. Gaps: `cmux.terminal.reply` (inline
reply into a Mac terminal) needs the terminal input path (D1 over `CmuxLink`); terminal banners open
only. Mac-to-phone end-to-end push keys keep the existing `CmuxPhonePush` path in the extension.

## 9. Verification (2026-10-06)

- `swift test` in `Packages/Shared/CmuxFeedPushCore`: 40 tests (payload decoding, action mapping, scoped
  and plan actions, extension decision, owner `notify_kind`, dismiss payload, activity state coding, op bodies).
- `CmuxiOSNotifyCoreTests` (9) and `CmuxiOSSettingsCoreTests` (35, after the type move) pass on macOS through
  a scratch package linking the same sources.
- `Packages/Shared/CmuxMobileWire` tests (16) and the protocol `mobile-wire.test.ts` (43) pass with the
  catalog, schema and fixture changes.
- `backend/apps/api` vitest: `test/notify.test.ts` (UserDO ops, kind table, per-device shaping, dismiss,
  badge, Live Activity state and requests, after-commit effects on real DO storage) and the extended
  `test/push.test.ts` e2e; the whole suite (757 tests) passes; `tsc` clean; catalog and TS client regenerated;
  file-size check passes. Nothing deployed.
- `CmuxiOSApp` (with `CmuxiOSLiveActivity`) builds for `arm64-apple-ios17.0-simulator` with SwiftPM, no
  warnings in the touched modules. `NotificationService.swift` and `AgentActivityWidgetBundle.swift`
  typecheck with `swiftc` against the SwiftPM-built modules; the two Xcode extension targets are not
  compiled (no local `xcodebuild`). Release signing needs `com.cmux.app.AgentActivityWidget` registered.
- Needs a device: banner actions from the lock screen under the background budget, Answered elsewhere and
  Answer not sent notices, remote dismiss (iOS throttles background pushes), foreground badge sync, the
  extension's decisions on real pushes, Live Activity rendering, token registration and push updates. No
  tagged build (known blocked).
