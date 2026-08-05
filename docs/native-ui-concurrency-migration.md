# Native UI And Concurrency Migration

This checklist is complete only when every box is checked and the residual gates return no matches.

## Native UI

- [x] macOS application lifecycle, menus, settings, debug windows, command palette, sidebars, browser overlays, and hosted extension surfaces use AppKit.
- [x] iOS application lifecycle, sign-in, onboarding, pairing, workspace navigation, terminal hosting, browser streaming, changes, artifacts, task composer, and settings use UIKit.
- [x] Bonsplit uses AppKit and ships no declarative UI dependency.
- [x] Ghostty's Apple framework uses AppKit/UIKit and ships no declarative UI dependency.
- [x] Sentry's Apple support code ships no declarative UI dependency.
- [x] PostHog is absent from the dependency graph.
- [x] Sources, tests, examples, scripts, fixtures, docs, CI, and review rules contain no retired framework imports, hosts, protocols, or names.
- [ ] macOS and iOS linked artifacts contain no retired framework load commands or symbols.

## Concurrency

- [ ] Every owned Swift package uses Swift tools 6.2, Swift 6 language mode, strict checking, and the approachable-concurrency feature set.
- [ ] AppKit/UIKit packages and application targets default to `MainActor`; transport, model, parser, daemon, and CLI targets remain explicitly nonisolated.
- [ ] Every Xcode target uses Swift 6, complete strict concurrency, and approachable concurrency.
- [ ] Main-actor hops use structured tasks or explicit isolation instead of queue dispatch.
- [ ] Owned asynchronous APIs use `async`/`throws`, task groups, actors, and async sequences where their callers permit it.
- [ ] Fire-and-forget tasks with lifecycle are stored and cancelled.
- [ ] Delays and timeouts use cancellable clock sleeps instead of queue deadlines.
- [ ] Required callback queues remain only at AppKit/UIKit, Dispatch source, Network, AVFoundation, XCTest, or third-party boundaries and are documented at the boundary.
- [ ] Every `@unchecked Sendable` in owned code has a synchronization or isolation justification.

## Verification

- [ ] macOS debug and release builds pass on the fleet compiler.
- [ ] iOS device archive and isolated simulator build pass on the fleet compiler.
- [ ] Focused package and hosted tests pass under Swift 6.
- [ ] Relevant macOS and iOS end-to-end tests pass.
- [ ] Tagged macOS and iOS paths are exercised end to end and captured in screenshots.
- [ ] The final source, dependency, generated-interface, binary-link, and symbol gates all return zero retired-framework evidence.
