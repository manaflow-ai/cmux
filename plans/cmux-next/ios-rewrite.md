# cmux-next iOS rewrite

Status: proposal, lane 14, 2026-10-02. Binding: OWNERSHIP-PRINCIPLES.md, architecture.md,
skills/cmux-next-feature/SKILL.md. Spec (manaflow-ai/cmux-next-spec): IOS1 to IOS4, T1, T2, B10,
N10 to N13; spec/home-and-agents.md, spec/sync-and-transport.md, spec/identity-and-permissions.md.
Neighbors: lane 12 (transport), lane 13 (ghostty-next), lane 15 (Home messaging backend), lane 16
(Mac Home rendering), the Mac Home lead (plans/cmux-next/home.md on feat-cmux-next-home).

## 1. Goal

A new iOS app with the same bundle ids as today's app, written from scratch. Home is the first
screen: the chat list and transcript from MessagesLab (UIKit), with the Chief pinned at the top,
subchiefs, group chats of Chiefs and people, person-to-person DMs, search over Home messages, and
compose by email or phone that invites the person. "Invite" sits at the top right. Terminals come
later from ghostty-next (lane 13) over the new transport (lane 12). Sign-in stays. No iroh anywhere
in the new app (T1).

## 2. What we keep, and why

Kept as code (moved or linked unchanged; nothing else of the old app survives):

KEEP_LIST_PLACEHOLDER

Kept as configuration (identity must not change, IOS1):

- `ios/Config/*.xcconfig`: bundle ids (`dev.cmux.ios`, tagged `dev.cmux.ios.<tag>`, BETA
  `dev.cmux.app.beta`), team, URL scheme, auth environment keys, API base URL keys.
- `ios/Config/Info.plist`, `cmux.entitlements`, `cmux-release.entitlements` (keychain access
  group, app group, push), the `cmux-ios` scheme, product `cmux.app`, and the Info.plist keys the
  fleet recipe checks (`CMUXGitSHA`, `CMUXDevTag`, `CMUXApiBaseURL`).
- `ios/fastlane` metadata and `ios/scripts` release tooling (unused until a release, IOS1: no
  TestFlight now).

Deleted after the new app installs and signs in on the phone (step 3 in section 10):

DELETE_LIST_PLACEHOLDER

## 3. Architecture

```
cmux.app (ios/App: UIApplication + UIScene entry, ~50 lines)
  └─ CmuxiOSApp          composition root: dependencies, root flow (signed out -> sign-in, signed in -> Home)
       ├─ CmuxiOSAuth     adapter over the kept sign-in (Stack) + the DEBUG launch sign-in hook
       ├─ CmuxHomeUI      UIKit Home: list, transcript, composer, compose/invite, search, Chief creation
       │    └─ CmuxHomeCore (Packages/Shared, no UIKit): model, HomeSource, mirror + intent log, mock
       ├─ CmuxiOSTerminal protocols only until lanes 12/13 land: TerminalSessionSource, TerminalRenderer
       └─ CmuxiOSDesign   tokens: colors from the theme (no blue accents), type scale, metrics, motion
```

- One seam per dependency. Home talks only to `HomeSource` (CmuxHomeCore). Implementations: the
  mock (now), the cloud owners `ConversationDO` + `UserDO` through the `UserDO` gateway (lane 15,
  `cmux.wire/1`), and a Mac's local conversation owner while that Mac is reachable (D10).
  Terminals talk only to `TerminalSessionSource` (lane 12) and render through `TerminalRenderer`
  (lane 13). Feature modules never import a transport.
- UIKit on the hot path (list, transcript, composer); SwiftUI only for low-frequency forms
  (settings, the new-Chief sheet). This matches architecture.md section 3 on the Mac.
- Swift 6 language mode, strict concurrency, `@MainActor` UI, `Sendable` sources, no
  `DispatchQueue.asyncAfter`, no sleeps for synchronization, no polling.

## 4. Module layout

| Path | Module | Owns |
| --- | --- | --- |
| `ios/App/` | app target sources | `@main` delegate, scene delegate, launch screen, asset catalog |
| `ios/CmuxiOS/Package.swift` | package for the app's modules | iOS 18+ |
| `ios/CmuxiOS/Sources/CmuxiOSApp` | composition root | root flow, dependency container, DEV switches |
| `ios/CmuxiOS/Sources/CmuxiOSAuth` | sign-in adapter | wraps the kept auth packages; `AuthGate` protocol |
| `ios/CmuxiOS/Sources/CmuxHomeUI` | Home UI | list, transcript, composer, compose/invite, search |
| `ios/CmuxiOS/Sources/CmuxiOSTerminal` | terminal seam | protocols + an "unavailable" screen until lanes 12/13 |
| `ios/CmuxiOS/Sources/CmuxiOSDesign` | design tokens | colors, type, metrics, Reduce Motion/Transparency helpers |
| `Packages/Shared/CmuxHomeCore` | Home client core | platform-neutral; also offered to the Mac Home lead and lane 16 |

Files stay small (one type per file; `check-no-godfiles.sh` budgets apply to the new tree).

## 5. State ownership (clients are mirror + intent log)

| Entity | Owner | iPhone holds |
| --- | --- | --- |
| Cloud conversation (participants, messages, reactions, read cursors) | `ConversationDO` | mirror pages (tail + paged history), never the full log |
| Account inbox (list, pins, mutes, unread, push queue) | `UserDO` | mirror |
| Chief principal and grants | `UserDO` (personal) / `TeamDO` (team) | display fields only |
| Invites (email via Resend, SMS via SendBlue) | the owner that commits `conversation.start` / `invite` | the receipt |
| Local-only conversation of a Mac | that Mac's `cmux` daemon | mirror while reachable, hidden while it sleeps |
| Terminals | the session host on each machine | only visible surfaces |
| Open conversation, scroll position, composer draft, list density, search query | the app (client view state) | memory; the draft and density persist on device only |
| Sign-in tokens | Keychain (kept auth code) | nothing beyond a request |

Rules (implemented in CmuxHomeCore and tested):

- The mirror changes only from owner events and fetched pages. Each stream (`inbox`,
  `conversation(id)`) has its revision; a jump of more than one is a gap and the client refetches
  that stream.
- One ordered intent log holds every unconfirmed op with its idempotency key. Visible state =
  mirror + intents. A send keeps its key as its id, so the committed echo replaces the pending
  bubble in place (no remove + insert, no flicker).
- An intent leaves the log on its echo (sends) or when the mirror reaches the revision the owner
  answered with. A refused send stays as "Not Delivered" until the user retries (new key) or
  discards; other refused ops are discarded and explained.

## 6. Offline behavior

- U5 holds: nothing queues. While the owners are unreachable, Home shows the cached inbox and
  transcripts read-only with an "Offline" state; Send, New Chief, Invite and pin are disabled and
  say why. A message typed offline stays in the composer as a draft (client view state).
- Intents sent before a disconnect stay visible as unconfirmed and are resent once on reconnect
  with their original keys; the owner dedupes them.
- Cold start reads a small on-device cache of the last inbox snapshot and the tail of the most
  recent conversations (bounded, about 2 MB), marked as cached until the first snapshot arrives.
  The cache is a projection; it never feeds intents.

## 7. Push

- Register with APNs after sign-in; the device token goes to `UserDO` as part of the install record
  (lane 15 owns the op; until then the existing registration endpoint is used if lane 15 keeps it).
- `UserDO` sends a push per message for user U (unless muted); an `approval` part always notifies.
  Payload: conversation id, message seq, sender display name, a short preview; `mutable-content`
  lets the Notification Service extension decrypt or shorten nothing it cannot verify.
- Tapping a push opens that conversation at the message; the app fetches the tail if the mirror
  lacks it. Badge = account unread from `UserDO`.
- Notification actions: Reply (inline text, sent as a normal intent when the app process runs it)
  and Mark Read.

## 8. Accessibility

- Every row and bubble is one accessibility element with a full label ("Chief, 2 unread, The
  nightly is out, 12 minutes ago"); custom actions for Pin, Mute, Reply, React.
- Dynamic Type up to AX5: rows and bubbles re-measure; the list switches to a stacked layout at
  accessibility sizes.
- VoiceOver reads new messages in the open conversation as announcements (polite), never steals
  focus. Reduce Motion replaces the send flight and spring scrolls with fades. Reduce
  Transparency replaces glass with opaque fills. Increase Contrast raises bubble contrast.
- All strings localized (`String(localized:defaultValue:bundle:)`), en and ja plus every language
  `check-l10n.sh` lists, short chrome strings.

## 9. Performance budgets

| Metric | Budget | How measured |
| --- | --- | --- |
| Cold start to first Home frame (cached inbox) | < 400 ms on iPhone 16 Pro | os_signpost from process start to first list commit |
| Cold start to live data | < 1.2 s on Wi-Fi | signpost to the first owner snapshot applied |
| List and transcript scrolling | 120 Hz, 0 hitches over 5 s flings | Instruments Animation Hitches; a `HomeBench` DEV action that flings |
| Transcript with 1M messages | no hitch on jump, send or rotate; < 150 MB RSS | mock source with a generated 1M history |
| Send tap to bubble on screen | < 1 frame (intent overlay) | signpost |
| Memory, idle on Home | < 120 MB | Xcode memory gauge on device |
| Idle CPU, Home visible, nothing changing | 0% (no timers, no polling) | Instruments Time Profiler |

Mechanisms: the transcript is virtualized (only visible rows exist); text is measured off the main
thread and cached by (message id, width, content size category); the mirror holds a bounded window
per conversation; events are coalesced to one UI update per frame.

## 10. Steps

1. Done: CmuxHomeCore (model, HomeSource, mirror + intent log, mock, tests).
2. App shell: new target tree, repoint the `cmux-ios` scheme, kept sign-in, Home against the mock.
   Fleet build, install on the phone, screenshots.
3. Delete the old app code listed in section 2 once step 2 passes the auth gate on the phone.
4. Prototypes for Lawrence to pick: Home list density (comfortable, compact, stacked) and the
   compose/invite flow (inline To: field, invite sheet, contact picker first), behind a DEV switch.
5. Real backend: a `CloudHomeSource` over `cmux.wire/1` when lane 15 publishes the ops.
6. Terminals: `TerminalSessionSource` on the lane 12 transport, rendering through ghostty-next.
7. Push, the on-device cache, accessibility audit, performance runs on device.

## 11. Open decisions

DECISIONS_PLACEHOLDER
