---
name: cmux-architecture
description: "cmux package architecture, refactor layering, dependency inversion, file organization, DocC documentation, package design discipline, testability, and Swift 6 concurrency rules. Use before adding or meaningfully rewriting Swift files, Swift packages, coordinators, services, repositories, or public package APIs."
---

# cmux Architecture

Use this before adding or meaningfully rewriting Swift in `Packages/` or the app
target. The rules below are the decisions; open the reference for the area you
are touching when you need examples, lists or wiring steps.

| Touching | Read |
| --- | --- |
| A new package, a package move, `Package.resolved`, a feature flag, Xcode project wiring | [package-boundaries.md](references/package-boundaries.md) |
| Where a type belongs, injection, SwiftUI state, `AppDelegate` extensions, testability | [layering.md](references/layering.md) |
| File splits, DocC comments, singletons, namespace enums, free functions | [file-api-discipline.md](references/file-api-discipline.md) |
| Locks, queues, sleeps, Combine, `@unchecked Sendable` | [concurrency-carveouts.md](references/concurrency-carveouts.md) |
| Xcode/Swift version differences, macOS 14 runtime limits | [swift-6-0-compatibility.md](references/swift-6-0-compatibility.md) |

## Packages

- A new package is ergonomic (internal by default), acyclic (a strict DAG; lift a
  shared type down or add a protocol seam), and whole-domain (one package per
  domain, not per slice). Extract leaf-first. Existing packages predate this
  policy; do not copy them as design references.
- The macOS app is `Packages/macOS/CmuxNext`, one module per feature. A new app
  module is a target in that `Package.swift`, with no pbxproj edit. The only
  Xcode target is `cmux-next`, which links the `CmuxNextApp` product.
- Packages live under `Packages/{Shared,iOS,macOS}/<pkg>`. To move one, `git mv`
  it and run `python3 scripts/check-workspace-package-groups.py --write`; never
  hand-edit workspace group membership.
- Track every cmux-owned `Package.resolved`; never gitignore one.
- "Feature flag" means a remote PostHog flag declared with a `FLAG(key: …)`
  comment and linted by `scripts/lint-feature-flags.py`, unless the user
  explicitly asks for a compile-time flag, setting or env var.

## Layers

Core → Services → Domain/state → UI → Executable, dependencies pointing only
down. Coordinators are `@MainActor @Observable` and do no I/O; Services and
Repositories are `actor`s. Higher layers depend on `any Protocol` through `init`
injection; the app target is the only composition root. No singletons, no
`static let shared`, no global container. Domain state is `@Observable`, never
`ObservableObject`/`@Published`; views never use `@StateObject`,
`@ObservedObject` or `@EnvironmentObject`. `AppDelegate+*` extensions do not
move down: extract the behavior and forward to it.

Every public package type is testable without the app, AppKit, the user's files
or `UserDefaults.standard`: defaults, file managers, paths, env and clocks arrive
through `init`, and there are no static test hooks.

## Files and APIs

- One major type per file, named after it. `scripts/cmux-next/check-no-godfiles.sh`
  enforces this in `Packages/macOS/CmuxNext`.
- Every `public` symbol in a new package gets a DocC `///` comment when written.
- No namespace enums, no free functions (except a forced `@convention(c)`
  trampoline), no hand-maintained registries that mirror declarations, and no
  `assertionFailure` fallbacks where the type system can hold the invariant.

## Swift 6 concurrency

New code uses `actor`, `async`/`await`, `AsyncStream`, `@Observable` and
`@MainActor`. Without a written justification in the PR, do not add locks,
KVO subclassing, queues used as locks, Combine, completion-handler public APIs,
`DispatchQueue.main.async`, `DispatchQueue.asyncAfter`, sleeps used to poll or
settle, or a single-method actor used as a mutex. The allowed carve-outs (file
and socket `DispatchSource`s, bounded injected-clock sleeps, a one-shot timer, a
compare-and-set lock for callback races, KVO tokens) each need a justification
comment and must stay behind an `actor` or `AsyncStream`. `@unchecked Sendable`
and `nonisolated(unsafe)` need a safety comment.

The app package needs Swift tools 6.2 and deploys to macOS 14; check Release
compiles and macOS 14 runtime limits with
[toolchain and macOS 14 compatibility](references/swift-6-0-compatibility.md).
