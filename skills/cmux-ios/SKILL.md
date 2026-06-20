---
name: cmux-ios
description: "Architecture and package rules for the cmux iOS companion app (ios/, Packages/iOS) and the cross-platform Packages/Shared layer. Use when editing the iOS app, Packages/iOS or Packages/Shared packages, MobileShellComposite, Mac pairing/RPC, mobile terminal mirroring, or deciding whether a type belongs in Shared vs iOS-only vs macOS-only."
---

# cmux iOS Companion

The iOS app mirrors a paired Mac's multiplexer state to mobile: pairing/reconnect, live Ghostty terminal mirroring over JSON-RPC, agent-chat UI, presence, push, browser, and QR pairing. It is a **separate Xcode build** from the macOS app and shares only the `Packages/Shared/*` layer.

## Where things live

- `ios/` — the iOS app target: `ios/cmux/` (app + `AppCompositionRoot.swift`), `ios/cmux.xcworkspace`, `ios/cmux-ios.xcodeproj`, `ios/cmuxPackage/`, `ios/cmuxUITests/`, `ios/Config/`, `ios/scripts/`. Build/test this workspace separately from the root macOS app.
- `Packages/iOS/*` — **iOS-app-only** SPM packages (15): `CmuxMobileShell`, `CmuxMobileShellModel`, `CmuxMobileShellUI`, `CmuxMobileRPC`, `CmuxMobileTransport`, `CmuxMobilePairedMac`, `CmuxMobileWorkspace`, `CmuxMobileTerminal`, `CmuxMobileTerminalKit`, `CmuxMobileBrowser`, `CmuxMobileCamera`, `CmuxMobileAnalytics`, `CmuxMobileDiagnostics`, `CmuxMobileSupport`, `CmuxAgentChatUI`.
- `Packages/Shared/*` — used by **both** apps (5): `CMUXAuthCore`, `CmuxAuthRuntime`, `CMUXMobileCore`, `CmuxAgentChat`, `CmuxSyncStore`. Pure Swift 6 (`swiftLanguageMode(.v6)`), **no AppKit/UIKit/Ghostty**.

## Package-group discipline (CI-enforced)

- A type used by **both** apps belongs in `Packages/Shared/`; iOS-only in `Packages/iOS/`; macOS-only in `Packages/macOS/`. The iOS app must never reach into `Packages/macOS/*`.
- The physical group folder is the source of truth, and `cmux.xcworkspace/contents.xcworkspacedata` mirrors it. Move a package with `git mv` then `python3 scripts/check-workspace-package-groups.py --write`; CI runs `--check`. Cross-group deps use `.package(path: "../../<Group>/<Name>")`. (See [`.github/review-bot-rules/swift-workspace-package-group-mirroring.md`](../../.github/review-bot-rules/swift-workspace-package-group-mirroring.md).)
- `Package.resolved` policy and the Swift 6 concurrency/architecture rules apply exactly as on macOS — load `cmux-architecture`.

## The mobile shell

- `MobileShellComposite` (`Packages/iOS/CmuxMobileShell`) is the iOS god-store, exposed as `public typealias CMUXMobileShellStore = MobileShellComposite`; every view binds to it. Decompose growth into cohesive child `@Observable` sub-models, not more god-store surface.
- Strict dependency chain: `CmuxMobileShellModel ← CmuxMobileShell ← CmuxMobileShellUI` (model → composite → UI). Keep it acyclic and downward-only.

## Terminal mirroring & pairing

- **Mirror model:** the Mac owns the real PTY; bytes stream to the iOS Ghostty surface (`CmuxMobileTerminal`). The iOS surface does not own a PTY.
- **effectiveGrid / letterbox:** the daemon is authoritative for the min cols×rows across attached devices; the iOS surface pins its render to that grid and letterboxes the remainder.
- Pairing/reconnect and the multiplexed JSON-RPC transport live in `CmuxMobileRPC` / `CmuxMobileTransport` / `CmuxMobilePairedMac`; auth retry and a serialized writer are part of that contract. Presence is via `Packages/Shared` + the Cloudflare presence worker (`PresenceClient`).

## Tests

- Package tests run standalone: `swift test --package-path Packages/iOS/<pkg>` or `Packages/Shared/<pkg>` (e.g. `CmuxAgentChat` has `ChatConversationStoreTests`, `ChatSessionOrderingTests`, `TranscriptBatchAssemblerTests`). iOS UI tests live in `ios/cmuxUITests`.
- The live agent-chat domain model (`ChatConversationStore`, transcript parsers) is shared via `Packages/Shared/CmuxAgentChat` — changes there affect both apps; cover both sides.
