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

| Kept piece | Now in | Why |
| --- | --- | --- |
| `MobileAuthComposition`, `DeferredSignInHook`, `MobileAuthBuildPolicy`, `MobileKeychainAccessGroupPolicy`, `ProtectedDataAvailability` (from `ios/cmuxPackage/cmuxFeature`) | `CmuxiOSAuth/Composition` | the Stack sign-in graph: environment resolution from `CMUXAuthEnvironment`/`CMUXApiBaseURL`, Keychain token store with the same service and access group (signed-in users stay signed in), DEBUG auto-login that the dogfood launcher drives, project-switch handling |
| Sign-in screens: `SignInView`, restore status, billing recovery, email-code policy, error presentation, OAuth providers, Game of Life header, small view helpers (from `CmuxMobileShellUI`, `CmuxMobileWorkspace`) | `CmuxiOSAuth/SignIn` | IOS1 allows keeping the sign-in flow; it is tested and localized (9 languages) |
| `Packages/Shared/CMUXAuthCore`, `CmuxAuthRuntime`, `CMUXMobileCore`, `vendor/stack-auth-swift-sdk-prerelease` | unchanged | the Mac app uses them too; `AuthCoordinator` is the sign-in owner |
| `Packages/iOS/CmuxMobileSupport` | unchanged | `L10n`, `UITestConfig`, keyboard dismissal, glass button styles; the Mac uses it too |
| `Packages/macOS/CmuxPhonePush`, `ios/NotificationService` | unchanged | push key material and the extension; plain pushes pass through; revisit when the new transport defines sender keys |
| The 38 sign-in strings of the app catalog | `ios/cmux/Resources/Localizable.xcstrings` | `L10n` reads the main bundle |

Kept as configuration (identity must not change, IOS1):

- `ios/Config/*.xcconfig`: bundle ids (`dev.cmux.ios`, tagged `dev.cmux.ios.<tag>`, BETA
  `dev.cmux.app.beta`), team, URL scheme, auth environment keys, API base URL keys.
- `ios/Config/Info.plist`, `cmux.entitlements`, `cmux-release.entitlements` (keychain access
  group, app group, push), the `cmux-ios` scheme, product `cmux.app`, and the Info.plist keys the
  fleet recipe checks (`CMUXGitSHA`, `CMUXDevTag`, `CMUXApiBaseURL`).
- `ios/fastlane` metadata and `ios/scripts` release tooling (unused until a release, IOS1: no
  TestFlight now).

Deleted after the new app installs and signs in on the phone (step 3 in section 10):

- `ios/cmuxPackage` (cmuxFeature, CmuxIrohReleaseGateSupport): iroh and irx runtime, pairing, the old root scene.
- iOS-only packages: CmuxAgentChatUI, CmuxMobileAnalytics, CmuxMobileBrowser, CmuxMobileBrowserStream,
  CmuxMobileCamera, CmuxMobileChanges, CmuxMobileCrashReporting, CmuxMobileDiagnostics,
  CmuxMobilePairedMac, CmuxMobileShell, CmuxMobileShellUI, CmuxMobileSimulatorStream,
  CmuxMobileTerminal, CmuxMobileTerminalKit, CmuxMobileToast, CmuxMobileTransport,
  CmuxMobileWorkspace; Shared iOS-only CmuxAgentChat, CmuxClientConfig, CmuxSimulatorStreamKit,
  CmuxWorkspacePresence.
- `ios/cmuxUITests` and the `iroh-soak` test plan (they drive the old UI); new UI tests come with the new screens.
- Kept because the Mac links them: CmuxMobileRPC, CmuxMobileSSH, CmuxMobileShellModel,
  CmuxMobileSupport, CmuxMobileTunnel.
- Same change edits what references the deleted paths: `ios/cmux.xcworkspace`, root
  `cmux.xcworkspace`, `scripts/check-workspace-package-groups.py`,
  `scripts/lint-ios-package-conventions.sh`, and the workflows `test-ios.yml`,
  `test-feed-reply-providers.yml`, `reload-build.yml`, `ios-e2e.yml`, `ios-testflight.yml`,
  `ios-screenshots.yml`, `ios-appstore-upload.yml`, `iroh-release-gate.yml`.

## 3. Architecture

```
cmux.app (ios/cmux: UIApplication + UIScene entry, ~30 lines)
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
- One window scene for now (`UIApplicationSupportsMultipleScenes` is false): auth and Home have one
  owner per process; iPad multi-window comes back with per-scene roots.
- Swift 6 language mode, strict concurrency, `@MainActor` UI, `Sendable` sources, no
  `DispatchQueue.asyncAfter`, no sleeps for synchronization, no polling.

## 4. Module layout

| Path | Module | Owns |
| --- | --- | --- |
| `ios/cmux/` | app target sources | `@main` delegate and scene delegate (one file), assets, string catalogs |
| `ios/CmuxiOS/Package.swift` | package for the app's modules | iOS 17+ (the app's floor) |
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
   Fleet build, install on the phone, screenshots. Dogfood proof: launcher readiness mode
   `app-receipt` (the DEBUG app writes a secret-free receipt after sign-in plus one authenticated
   API call; a credential-free relaunch must report `session_source: restored`), selected by the
   Info.plist key `CMUXDogfoodReadiness`; the old app keeps the Mac pairing gate.
3. Delete the old app code listed in section 2 once step 2 passes the auth gate on the phone.
4. Prototypes for Lawrence to pick: Home list density (comfortable, compact, stacked) and the
   compose/invite flow (inline To: field, invite sheet, contact picker first), behind a DEV switch.
5. Real backend: a `CloudHomeSource` over `cmux.wire/1` when lane 15 publishes the ops.
6. Terminals: `TerminalSessionSource` on the lane 12 transport, rendering through ghostty-next.
   - Rendering: GhosttyKit only through the pinned ghostty-next release
     (`.binaryTarget(url:checksum:)`, plans/cmux-next/ghostty-next.md), in manual I/O mode: the
     phone parses bytes only to draw them; attach, resize, flood catch-up and drift repair use a
     host snapshot. Keys are encoded by Ghostty's encoder from `pressesBegan`; input goes to
     `io_write_cb` on the caller's thread.
   - Sizing (ghostty-next section 6): the software keyboard never changes the phone's rows; the
     phone counts toward "smallest viewer" only while the terminal is on screen in the foreground;
     a grow waits 250 ms; previews never count. `TerminalSessionSource.setPresence` carries this.
   - Transport (plans/cmux-next/transport.md): WireGuard runs inside the app, no Network
     Extension; the device key never leaves the phone; paths are LAN, NAT-punched direct, the
     cloud tunnel ("via cloud region") and the per-host relay; `TerminalPath` is the badge.
     A mock `TerminalSessionSource` comes first; the engine plugs in when its iOS build lands.
   - Memory (ghostty-next ios-v5): the phone's ghostty config sets `scrollback-limit-bytes` to
     the 8 MiB budget (`ios.terminal.scrollbackBytes`). Every READY and HISTORY restore applies
     that cap, not the host's limit, and trims only the oldest complete history pages; screens
     and on-screen Kitty images stay. The viewer restores READY only and never asks for HISTORY
     (history comes from the host on demand, ghostty-next section 7). This replaced the ios-v4
     self-trim (re-encode READY and restore it), which dropped all local scrollback.
7. Push, the on-device cache, accessibility audit, performance runs on device.

## 11. Open decisions

- DECISION: raise the app's floor from iOS 17 to iOS 18? RECOMMEND: yes, after the first dogfood round,
  because UIKit observation tracking and newer list APIs remove glue code; today the new packages
  build for iOS 17 to keep the current floor.
- DECISION: Home messages offline. RECOMMEND: keep U5 (nothing queues; the composer keeps a local
  draft), because a queued send that fails later is worse than a disabled Send with a reason.
- DECISION: transcript renderer. RECOMMEND: the shared rendering core from lane 16 (MessagesLab
  `catalyst/` core with the row recycler) plus an iPhone screen layer here (keyboard machine, input
  bar, chat column from MessagesLab `ios/`), because two copies of a 4,000-line engine diverge at
  once. Until it lands, the transcript is a small interim list behind `TranscriptPresenting`.
- DECISION: the same-tag Mac build in the dogfood pipeline. RECOMMEND: keep it for now (backend
  origin check), add an iOS-only path once the app has no Mac dependency at all.
