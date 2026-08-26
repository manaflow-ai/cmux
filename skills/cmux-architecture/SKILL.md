---
name: cmux-architecture
description: "cmux package architecture, refactor layering, dependency inversion, file organization, DocC documentation, package design discipline, testability, and Swift 6 concurrency rules. Use before adding or meaningfully rewriting Swift files, Swift packages, coordinators, services, repositories, or public package APIs."
---

# cmux Architecture

## Package architecture

cmux is migrating from a single app target into Swift Packages under `Packages/`. Every new package must be:

- **Ergonomic.** Default to internal access; `public` only what downstream consumers actually use.
- **Acyclic.** Packages form a strict DAG. Share a type by lifting it to a lower package or defining a protocol seam in the consumer. Every new dependency edge requires re-checking that the graph stays acyclic.
- **Whole-domain.** One package owns a full domain (settings, appearance, workspace, terminal, browser, command palette). `CmuxAppearanceMath` + `CmuxAppearanceTheme` + `CmuxAppearanceSettings` is folder structure inside `CmuxAppearance`, not module structure. A boundary exists because more than one consumer needs the contents, or a build/test seam must exist.

When in doubt, extract leaf-first: the package with no internal dependencies. Existing packages under `Packages/` predate this policy; do not use them as design references.

Wiring a new package into `cmux.xcodeproj` needs explicit pbxproj entries in **both** the `cmux` and `cmux-unit` targets. See [references/package-boundaries.md](references/package-boundaries.md).

**Group folders.** Every package lives physically under exactly one group directory: `Packages/Shared/<pkg>` (both apps), `Packages/iOS/<pkg>` (iOS only), or `Packages/macOS/<pkg>` (macOS only). `cmux.xcworkspace/contents.xcworkspacedata` mirrors that folder shape, with three groups whose container locations are those folders and every package directory as a FileRef under its folder's group. The folder is the source of truth: to move a package, `git mv` the directory then run `python3 scripts/check-workspace-package-groups.py --write`. Cross-group `.package(path:)` deps use `../../<Group>/<Name>`. Never hand-edit workspace group membership. CI runs `python3 scripts/check-workspace-package-groups.py --check` and fails on drift.

**Lockfiles.** Do not gitignore cmux-owned `Package.resolved` files; SwiftPM resolution changes must be visible in PR diffs. Track the root Xcode lockfile and every cmux-owned package-local `Package.resolved` produced by standalone `swift package resolve` / `swift build` / `swift test`. A package-local lockfile is the source of truth for that package's standalone resolution and is not replaced by `cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Vendored third-party directories may keep their upstream ignore policy. CI runs `python3 scripts/check-package-resolved-policy.py`.

**Feature flags mean remote PostHog runtime flags.** Unless the user explicitly asks for a compile-time flag, local setting, or environment variable, implement a feature flag through `CmuxFeatureFlags` with a PostHog key, an explicit unavailable fallback, registry metadata, live update behavior, and focused tests. A local override may support dogfood but must not be the production control plane.

## Layers

Five layers, dependencies point only downward:

1. **Core** (`CmuxCore`): pure `Sendable` values, IDs, DTOs, errors, shared protocol seams. No AppKit/SwiftUI/I/O. The lift target when two domains need the same type.
2. **Services / infrastructure**: `actor`s implementing core protocols against the outside world (process/PTY, filesystem, sockets, web API, notifications, auth). One package per cohesive capability.
3. **Domain / state**: `@MainActor @Observable` models plus Coordinators, one package per feature domain, owning that domain's mutable state. Exemplar `CmuxSettings`.
4. **UI**: SwiftUI/AppKit views, one UI package per domain package, depending only on its domain package plus Core, never a Service directly. Exemplar `CmuxSettingsUI`.
5. **Executable** (`cmuxApp` / `AppDelegate`): thin composition shim, no business logic.

Classify every extracted entity by intent:

- **Coordinator**: `@MainActor @Observable` orchestrator that sequences a user flow and owns navigation/selection/lifecycle state, calling Services and child models. Does no I/O itself.
- **Service**: `actor` (or `@MainActor` only when an AppKit main-thread API forces it) performing one outside-world capability; exposes `async`/`await` plus `AsyncStream`; holds only its own resource handles and no UI state.
- **Repository**: `actor` mediating one persistence source of truth (file, defaults, web API) behind CRUD-shaped async methods returning value types. Precedents: `JSONConfigStore`, `UserDefaultsSettingsStore`.

**Dependency inversion.** Lower packages publish protocols; concrete Services/Repositories conform; higher layers depend on `any Protocol`, never the concrete type, and never a stored property reaching across modules. Constructor (`init`) injection only: no global container, no singleton, no `static let shared`. The executable app target is the single composition root, the one place concretes are named and the object graph is assembled. SwiftUI `Environment` may carry already-constructed `@Observable` models down a view tree (as `SettingsRuntime` does), never service wiring.

**State and SwiftUI.** Domain state lives in `@MainActor @Observable` models, never `ObservableObject`/`@Published`. A god model decomposes into cohesive child `@Observable` sub-models owned by their domain packages and composed by held reference; cross-domain reads go behind read-only protocols. In views use `@State` (owned), `@Bindable` or plain `let` (passed in), or `@Environment(M.self)` plus `.environment(...)` (injected). Never `@StateObject` / `@ObservedObject` / `@EnvironmentObject` / `.environmentObject(_:)`.

**Executable-target boundary (invert, never work around):**

1. `@main` `cmuxApp` and `AppDelegate` stay in the executable target as the thin composition shim. That residual is the intended end state, not debt.
2. A type is declared in exactly one module and a lower package cannot extend a higher-owned type, so `AppDelegate+*` / `cmuxApp+*` / `Workspace+*` extensions do not move down. Extract the behavior into a Coordinator/Service/Repository, have the god object own an instance, and reduce the extension to a one-line forward.
3. Stored properties cannot cross module boundaries. Decompose god-model state into child `@Observable` sub-models owned by domain packages, composed by held reference, with cross-cutting reads behind read-only protocols.

## File organization

One major type per file, named after the type (`Control.swift`, `LabeledChoice.swift`, `ListControl.swift`, not one shared `SettingControl.swift`). Applies to all new code in `Packages/` and all new app-target files.

- Trivial private helpers, nested types, and single-line extensions used only inside the file may stay with the parent type. Anything with a meaningful body gets its own file, including a `private final class` nested in another file's type.
- Conformance-adding extensions for a type defined elsewhere go in `TypeName+Conformance.swift` or `TypeName+Feature.swift`, not bundled into the consuming feature file.
- Type-erased wrappers live next to what they erase: `Foo.swift` and `AnyFoo.swift`.
- The god files (`ContentView.swift`, `Workspace.swift`, `TabManager.swift`, `cmuxApp.swift`) are what this rule exists to stop. Splitting one file per type is correct even if it triples the file count. File count is cheap; "find this type" being unanswerable is expensive.

## Documentation

Every `public` symbol in a new package under `Packages/` gets a Swift-DocC `///` comment at the time it is written. Docs are part of the API surface, not follow-up work.

- First line is a one-sentence summary that fits on one line and ends with a period. Blank `///` line before any discussion paragraph. Use `- Parameter name:` / `- Returns:` / `- Throws:` on `init` and `func` symbols that take parameters or throw. Markdown is fine.
- Reference symbols with double backticks (`` ``CmuxSetting`` ``); plain backticks for non-symbol code (`UserDefaults.standard`).
- Document what a type represents and when to use it, the meaning of each enum case, init parameter defaults and their reason, property invariants, method behavior, and which generic `Value`/`Element` shapes are accepted and why.
- Non-trivial APIs get at least one short example in a fenced `swift` block, ideally a real declaration from this codebase.
- `internal` and `private` symbols get a one-line `///` when the intent is non-obvious. The public boundary is the one that needs full coverage.
- Update the doc comment in the same edit that changes behavior or signature. Doc comments describe the contract from outside; inline `//` is reserved for non-obvious *why*.

Main app target code is not retroactively required to be documented.

## Package design discipline

- **No shared-singleton accessors.** `static let standard` / `shared` / `default` on a package type holding runtime state is a singleton by another name. Construct at the app startup site and inject. `static let` is fine for declarations (identifiers, schema entries, enum cases), not for behavior.
- **No namespace-enums.** `enum Foo { static func bar() }` is a fake namespace with no instances, no DI, and no test seam. Prefer a value-typed struct passed via constructor when the helper might gain configuration.
- **No parallel hand-maintained registries.** When a list mirrors declared items (`catalog.all` mirroring stored properties), derive it via `Mirror` reflection or a macro. Two sources of truth drift silently.
- **Prefer compile-time invariants to runtime traps.** `guard ... else { assertionFailure(...); return default }` for a "programmer error" case should be encoded in the type system (phantom types, separate concrete flavors). Runtime traps become silent fallbacks in release builds.
- **No free functions.** Top-level `func` declarations, any visibility including file-scope `private func`, are banned; scope functionality to the entity that owns the responsibility. The only sanctioned exception is a `@convention(c)` trampoline a C API forces, with a one-line justification.

## Testability

Every public type added to `Packages/` must be testable from a test target without launching the app target, booting AppKit, or depending on the user's filesystem or `UserDefaults.standard`.

- `UserDefaults`, `FileManager`, on-disk paths, environment variables, and clocks arrive through `init` parameters. Tests pass a `UserDefaults(suiteName:)` scoped to the test, a temp directory URL, a fixed `Date`.
- No implementation hardcodes `.shared` / `.standard`.
- **No static test hooks.** A `nonisolated(unsafe) static var fooForTesting` (or any global mutable override a test swaps in) leaks across tests and usually needs a lock. Replace it with a protocol seam through `init`, e.g. `init(commandRunner: any CommandRunning = CommandRunner())`. Deleting the static hook and its lock is part of the extraction, not a follow-up.
- Prefer returning the changed value and letting the caller persist over mutating global state and returning `Void`.
- Surface observation as `AsyncStream` so tests can assert the yielded sequence, rather than `NotificationCenter`-only patterns that need a runloop spin.
- Show the test-instantiation pattern in the package `README.md` or DocC catalog.

If a design is hard to test, it is wrong. Reach for the constructor parameter list, not the test bench.

## Swift 6 concurrency

New code in `Packages/`, new app-target files, and meaningful rewrites use `actor`, `async`/`await`, `AsyncStream`/`AsyncSequence`, `@Observable`, and `@MainActor`.

**Forbidden without a written justification in the PR description:**

- **Locks**: `NSLock`, `NSRecursiveLock`, `os_unfair_lock`, `OSAllocatedUnfairLock`, `pthread_mutex_t`, `Synchronization.Mutex`, `DispatchSemaphore` used as a lock. Ongoing mutable shared state belongs in an `actor` with `async` reads and writes.
- **KVO via `NSObject` subclassing** to override `observeValue(forKeyPath:...)` or call `addObserver(_:forKeyPath:...)`. Use `NotificationCenter.default.notifications(named:)` or the `NSKeyValueObservation` token API at the seam only.
- **`DispatchQueue` as a synchronization primitive** (`queue.sync { ... }` serializing mutable state). Queues are fine for event delivery, not for protecting state.
- **Combine for change propagation**: `@Published`, `ObservableObject`, `PassthroughSubject`/`CurrentValueSubject`, `AnyCancellable`.
- **Completion-handler public APIs** (`(Result<T, Error>) -> Void`, `(T?, Error?) -> Void`). Use `async throws -> T`; wrap a legacy callback with `withCheckedContinuation`/`withCheckedThrowingContinuation` confined to that one seam.
- **`DispatchQueue.main.async`**. Annotate the destination `@MainActor` and `await` it.
- **Sleeping as a synchronization substitute**: any sleep used to poll for a condition, let state settle before reading, or race a callback/animation. `DispatchQueue.asyncAfter` is banned outright (not cancellable by structure, not testable).
- **A single-method `actor` used as a mutex.** `actor Guard { func claim() -> Bool }` forces synchronous callers (a `Process` termination handler, a `DispatchSource` event handler, a `withCheckedContinuation` resume race) through `Task { await guard.claim() }`, adding suspension points, ordering hops, and reentrancy surface to a fundamentally synchronous compare-and-set. Use the lock carve-out instead.

**Required shape**: mutable shared state to an `actor` with `async` accessors and an `AsyncStream` for observers; SwiftUI-render-friendly state to an `@Observable @MainActor` view model subscribing to that stream and projecting snapshots (never read actor state synchronously from view code); cross-process and cross-thread invariants expressed through actor isolation; new public observable surfaces as `AsyncStream`/`AsyncSequence`.

**Carve-outs**, each with a one-line justification comment on the declaration and hidden behind an `AsyncStream` or `actor` surface so callers never see them:

- `DispatchSource.makeFileSystemObjectSource` for file watching, `makeReadSource`/`makeWriteSource` for low-level socket I/O (no async-native replacement).
- A bounded, cancellable `Clock.sleep` (preferred) or `Task.sleep` for a genuine delay or deadline that is itself the intended behavior (minimum display duration, auto-dismiss, check timeout). Drive it from an injected `Clock` so tests advance virtual time, store the `Task`, and cancel it on the relevant lifecycle transition. Never to poll, settle, or race.
- `DispatchSource.makeTimerSource` (one-shot) only when a genuine deadline must fire outside any async context, in a non-`async` type with no `Task` to host the sleep. Prefer `Clock.sleep` whenever the code is already async or actor-isolated; a raw timer is not cancellation-integrated or testable and has suspend/resume/cancel footguns.
- A lock for a short, non-blocking synchronous compare-and-set called from non-async callbacks. Canonical case: several synchronous `Process`/`DispatchSource` callbacks race to resume one `withCheckedContinuation` exactly once, guarded by `OSAllocatedUnfairLock(initialState:)` over a `Bool`. Not for guarding ongoing domain state.
- `NSKeyValueObservation` token when wrapping a Foundation/AppKit type that exposes change only via KVO.

When extracting existing code that uses a forbidden primitive, reshape it at the seam instead of copying it; usually it wants an `actor`. Drain `Process` pipes concurrently on detached tasks keyed by the raw fd (`Int32` is `Sendable`, `FileHandle` is not).

`@unchecked Sendable` and `nonisolated(unsafe)` require a comment explaining the safety argument, or the diff is rejected. `@unchecked Sendable` on an entire actor or struct is almost always wrong; prefer `nonisolated(unsafe) let` on the single non-Sendable property.

Existing app-target code may keep the old primitives until rewritten. Do not retrofit blindly.

## Detailed references

- [references/package-boundaries.md](references/package-boundaries.md): extraction order, dependency graph, composition root, pbxproj wiring.
- [references/concurrency-carveouts.md](references/concurrency-carveouts.md): carve-out examples and the reviewer reject-list.
- [references/file-api-discipline.md](references/file-api-discipline.md): one-type-per-file, DocC, design smells.
