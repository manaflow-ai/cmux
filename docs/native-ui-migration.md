# Native UI and concurrency migration

This migration removes SwiftUI from every cmux-owned target, example, test,
vendored fork, and linked dependency. macOS uses AppKit. iOS uses UIKit because
AppKit is unavailable there. Product behavior, accessibility, localization,
keyboard routing, restoration, and dogfood entry points remain supported.

## Baseline on 2026-08-02

- cmux: 1,077 text files mention SwiftUI, 743 Swift files import it, and those
  import files contain about 296,000 lines.
- cmux UI surface: about 665 `View` implementations, 48 view modifiers, 19
  button styles, 27 shapes, 130 `NSHosting*` references, and 23 `UIHosting*`
  references.
- bonsplit: 32 text files mention SwiftUI, 27 Swift files import it, and those
  files contain 19,365 lines.
- Ghostty fork: 69 text files mention SwiftUI, 63 Swift files import it, and
  those files contain 22,681 lines.
- Resolved dependencies: MarkdownUI, NetworkImage, PostHog, and Sentry contain
  compiled or product-adjacent SwiftUI integration. XcodeProj and swift-syntax
  contain unbuilt fixture references.
- Legacy concurrency in cmux Swift sources and tests includes 56 Combine
  imports, 54 `ObservableObject` references, 269 `@Published` properties, 715
  `DispatchQueue` references, 102 `asyncAfter` references, 355 semaphores, and
  201 detached tasks. Project targets still declare Swift 5 language mode.

The counts are discovery metrics. Completion is determined by the gates below.

## Migration checklist

- [ ] Toolchain and module policy
  - [ ] Move every owned target and package to Swift 6 language mode under the
    pinned Xcode 26 toolchain.
  - [ ] Use main-actor default isolation for executable and UI modules.
  - [ ] Use caller-isolated async defaults and explicit `@concurrent` only for
    measured CPU work that must leave the caller's actor.
  - [ ] Compile Debug and Release with complete data-race checking and no
    concurrency warnings.
- [ ] Shared state and asynchronous services
  - [ ] Replace Combine observation with Observation or `AsyncSequence`.
  - [ ] Replace callback-shaped owned APIs with `async` functions.
  - [ ] Replace queue-protected mutable state with actors.
  - [ ] Replace main-queue dispatch with actor isolation.
  - [ ] Replace delayed dispatch with injected, cancellable clocks.
  - [ ] Keep only documented synchronous compare-and-set or system callback
    carve-outs, each behind an actor or async surface.
- [ ] bonsplit fork
  - [x] Replace the public `View` and `@ViewBuilder` API with AppKit view and
    view-controller APIs.
  - [x] Replace split layout, tab chrome, drag and drop, menus, tooltips,
    overlays, and the example app with AppKit.
  - [x] Modernize its concurrency and prove the fork branch is reachable on
    `manaflow-ai/bonsplit` before updating cmux's pointer.
- [ ] macOS packages
  - [x] `CmuxSettingsUI` (0; native settings root, navigation, editors,
    account, and Sleepy controls complete)
  - [x] `CmuxSimulator` (0)
  - [x] `CmuxSwiftRenderUI` (0)
  - [x] `CmuxLiveEval` (0)
  - [x] `CmuxSidebarInterpreterService` (0)
  - [x] `CmuxUpdaterUI` (0)
  - [x] `CmuxCanvasUI` (0)
  - [x] `CmuxAppKitSupportUI` (0)
  - [x] `CmuxFoundation` (0; its temporary font adapter now lives only beside
    the remaining executable bridges)
  - [x] `CmuxExtensionKit` (0)
  - [x] `CmuxCommandPalette` (0)
- [ ] macOS executable
  - [ ] Replace the SwiftUI `App` entry point with `NSApplication` and an
    AppKit composition root.
  - [ ] Replace scene, environment, focused-value, storage, command, window,
    settings, toolbar, sheet, popover, and alert ownership with AppKit owners.
  - [ ] Replace the 13 importing files remaining under `Sources`, including the
    application root and remaining sidebar auxiliaries. Workspace, terminal,
    browser, Vault, Feed, titlebar controls, notifications popover, the
    right-sidebar root, and the browser design-mode composer are native AppKit.
    The installed-extension sidebar host, permission review, provider picker,
    and XPC renderer are also native.
  - [ ] Remove every `NSHostingView` and `NSHostingController` boundary.
- [ ] iOS packages and executable
  - [ ] `CmuxMobileShellUI` (172 import files; notification feed, terminal
    composer, artifact chip, shortcut settings, custom-action editor, and the
    workspace-list table host are UIKit)
  - [ ] `CmuxMobileSupport` (2 shared presentation helper import files)
  - [x] `CmuxAgentChatUI` (0)
  - [x] `CmuxMobileChanges` (0)
  - [x] `CmuxMobileTerminal` (0)
  - [x] `CmuxMobileToast` (0)
  - [x] `CmuxMobileBrowserStream` (0)
  - [x] `CmuxMobileBrowser` (0)
  - [x] `CmuxMobileWorkspace` (0)
  - [ ] Replace the SwiftUI `App` and scene graph with `UIApplicationDelegate`,
    `UISceneDelegate`, and UIKit coordinators.
  - [ ] Remove every `UIHostingController` and `UIHostingConfiguration` boundary.
- [x] Ghostty fork
  - [x] Replace the macOS application, settings, command palette, split tree,
    terminal chrome, update UI, overlays, and helpers with AppKit.
  - [x] Replace the Ghostty iOS application surface with UIKit.
  - [x] Remove the legacy declarative UI framework from GhosttyKit's public API and embedded build graph.
  - [x] Modernize concurrency and prove the fork branch is reachable on
    `manaflow-ai/ghostty` before updating cmux's pointer.
- [ ] External dependencies
  - [ ] Remove the stale MarkdownUI and NetworkImage package products.
  - [x] Remove the PostHog SDK and retain the two desktop activity metrics with
    a small actor-isolated URLSession transport. Feature flags use the existing
    first-party async control plane.
  - [x] Strip Sentry UI integrations in the `manaflow-ai/sentry-cocoa` fork
    while retaining crash and error reporting behavior.
  - [ ] Confirm every linked third-party product has no SwiftUI object-code
    dependency.
- [ ] Examples, tests, tooling, and documentation
  - [ ] Convert all sidebar extension examples and previews to native UI.
  - [ ] Replace framework-dependent unit fixtures with native controller and
    view behavior tests.
  - [ ] Update XCUITest paths for the native accessibility hierarchy.
  - [ ] Remove obsolete framework-specific lint rules, plans, docs, changelog
    prose, generated catalogs, and web copy.

## Completion gates

- [ ] A case-insensitive tracked-tree scan returns no `SwiftUI` occurrence in
  cmux, bonsplit, Ghostty, generated project files, or vendored source.
- [ ] No owned source declares `View`, `Scene`, `App`, `ViewModifier`,
  `ButtonStyle`, `Shape`, `NSHosting*`, or `UIHosting*` from SwiftUI.
- [ ] No package manifest, lockfile, Xcode project, or linker invocation adds a
  SwiftUI-dependent product.
- [ ] `otool -L` and `nm` checks on macOS, iOS, helper, extension, and framework
  artifacts find no direct SwiftUI load command or symbols.
- [ ] Debug and Release builds pass with Swift 6 complete concurrency checking,
  main-actor default isolation in UI targets, and no warnings.
- [ ] Focused package tests, `cmux-unit`, 1 to 3 relevant hosted macOS E2E
  classes, isolated iOS simulator UI tests, and device dogfood pass.
- [ ] Tagged macOS and iOS builds complete the exact launch, workspace, split,
  sidebar, terminal, browser, settings, update, authentication, and restore
  paths with screenshots or recordings.
