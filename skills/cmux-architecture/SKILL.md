---
name: cmux-architecture
description: "cmux package architecture, refactor layering, dependency inversion, file organization, DocC documentation, package design discipline, testability, and Swift 6 concurrency rules. Use before adding or meaningfully rewriting Swift files, Swift packages, coordinators, services, repositories, or public package APIs."
---

# cmux Architecture

## Package architecture

We are migrating cmux from a single app target into Swift Packages under `Packages/`. Every new package must satisfy three rules:

- **Ergonomic.** Public API surface matches what callers naturally want to write. Default to internal access; expose `public` only for types and functions that downstream consumers actually use. Avoid friction such as forcing every call site through a builder or wrapper when a direct API is fine.
- **No dependency cycles.** Packages form a strict DAG. A package may only depend on packages strictly lower in the graph. When two packages need to share a type, lift it to a common lower-level package or define a protocol seam in the consumer. Every new dependency edge requires re-checking that the graph stays acyclic.
- **Clear but not overly narrow responsibilities.** A package owns one full domain (e.g. _settings_, _appearance_, _workspace_, _terminal_, _browser_, _command palette_), not a slice of one. A package called "appearance math" or "workspace model" is too narrow — it forces every consumer that touches the surrounding domain to also depend on the sibling slices. Prefer a single `CmuxAppearance` that owns settings, theming, colors, glass, and snapshots together, over `CmuxAppearanceMath` + `CmuxAppearanceTheme` + `CmuxAppearanceSettings`. Don't fragment a domain into `CmuxFooFormatting` + `CmuxFooLogic` + `CmuxFooState` — that's folder structure inside a single package, not module structure. A package boundary exists because more than one consumer needs the contents, or a build/test seam needs to exist.

When in doubt, **extract leaf-first**: pull out the package that has no internal dependencies. Consumers in the app target stay put and only update imports. Each leaf shrinks the app target without requiring downstream packages to exist yet.

The existing packages under `Packages/` predate this policy and should not be used as design references.

**Wiring a new local package into the project.** `cmux.xcodeproj` lists package dependencies explicitly (it is not a synchronized-folder project). Adding `Packages/CmuxFoo` means mirroring an existing package's `project.pbxproj` entries — one `XCLocalSwiftPackageReference` (in the project's `packageReferences`), one `XCSwiftPackageProductDependency`, and a `PBXBuildFile` linked in the Frameworks phase of **every** target that imports it. The app-target packages link into **both** `cmux` and `cmux-unit` (so tests can `import` and inject them); copy a recent leaf like `CmuxSocketControl` for the exact shape, then run `scripts/normalize-pbxproj.py` and `scripts/check-pbxproj.sh`. A package the app builds against but `cmux-unit` does not link will compile the app yet fail the test target.

## Refactor architecture: layers, Coordinator/Service/Repository, dependency inversion

These higher-level patterns are binding on every new or moved/meaningfully-rewritten file. (The full blueprint, with worked examples and the per-god decomposition, lives in the cmuxterm-hq control repo under `docs/cmux-refactor-audit/blueprint/`; the enforceable core is below.)

**Layered, downward-only DAG.** Packages form a strict acyclic graph in five layers; dependencies point only downward:

1. **Core** (e.g. `CmuxCore`) — pure `Sendable` values, IDs, DTOs, errors, and the protocol seams shared across domains. No AppKit/SwiftUI/I/O. The lift target when two domains need the same type.
2. **Services / infrastructure** — `actor`s implementing core protocols against the outside world (process/PTY, filesystem, sockets, web API, notifications, auth). One package per cohesive capability.
3. **Domain / state** — `@MainActor @Observable` models + Coordinators, one package per feature domain; owns that domain's mutable state. `CmuxSettings` is the exemplar.
4. **UI** — SwiftUI/AppKit views, one UI package per domain package, depending only on its domain package + Core, never on a Service directly. `CmuxSettingsUI` is the exemplar.
5. **Executable** (`cmuxApp` / `AppDelegate`) — a thin composition shim, no business logic.

**Classify every extracted entity by intent:**

- **Coordinator** — a `@MainActor @Observable` orchestrator that sequences a user flow and owns navigation/selection/lifecycle state, calling Services and child models. Does no I/O itself.
- **Service** — an `actor` (or `@MainActor` only when an AppKit main-thread API forces it) performing one outside-world capability; exposes `async`/`await` + `AsyncStream`, holds only its own resource handles, holds no UI state.
- **Repository** — an `actor` mediating one persistence source of truth (file, defaults, web API) behind CRUD-shaped async methods returning value types. Precedents: `JSONConfigStore`, `UserDefaultsSettingsStore`.

**Dependency inversion.** Lower packages publish protocols; concrete Services/Repositories conform; higher layers depend on `any Protocol`, never the concrete type. Share a type by lifting it to Core or defining a protocol seam in the consumer — never a stored property reaching across modules. Injection is constructor (`init`) injection only: no global container, no singleton, no `static let shared`. The **executable app target is the single composition root** — the one place concretes are named and the object graph is assembled. SwiftUI `Environment` may carry already-constructed `@Observable` models down a view tree (as `SettingsRuntime` does), but is never the source of truth for service wiring.

**State + SwiftUI wiring.** Domain state lives in `@MainActor @Observable` models (never `ObservableObject`/`@Published`). A god model decomposes into cohesive child `@Observable` sub-models owned by their domain packages and composed by the home object via held references; cross-domain reads go behind read-only protocols. In views use `@State` (owned), `@Bindable` / plain `let` (passed-in), or `@Environment(M.self)` + `.environment(...)` (injected) — never `@StateObject` / `@ObservedObject` / `@EnvironmentObject` / `.environmentObject(_:)`.

**Executable-target boundary (three hard constraints — invert, never work around):**

1. `@main` `cmuxApp` and `AppDelegate` stay in the executable target as the thin composition shim; that residual is the intended end state, not debt.
2. A type is declared in exactly one module and a lower package cannot extend a higher-owned type, so `AppDelegate+*` / `cmuxApp+*` / `Workspace+*` extensions do not move down: extract the behavior into a Coordinator/Service/Repository, have the god object own an instance, and reduce the extension to a one-line forward.
3. Stored properties cannot cross module boundaries: decompose god-model state into child `@Observable` sub-models owned by domain packages, composed by held reference, with cross-cutting reads behind read-only protocols.

## File organization

One major type per file. Each `struct`, `class`, `enum`, `actor`, or `protocol` that is part of a public API (or has any meaningful body) lives in its own file named after the type (`Control.swift`, `LabeledChoice.swift`, `ListControl.swift` — not one shared `SettingControl.swift`). This rule applies to all new code in `Packages/` and to any new files added to the app target.

- Small, closely-bound helpers (`private struct`, nested types, single-line extensions used only inside the file) can stay with the parent type. Anything bigger or independently meaningful gets its own file.
- Conformance-adding extensions for a type defined elsewhere go in `TypeName+Conformance.swift` or `TypeName+Feature.swift`, not bundled into the consuming feature file.
- Type-erased wrappers (`AnyFoo`) live next to the type they erase (`Foo.swift` and `AnyFoo.swift`), each in its own file.
- Existing god files (`ContentView.swift`, `Workspace.swift`, `TabManager.swift`, `cmuxApp.swift`) are the pattern this rule exists to stop. When migrating code out of them, split into one file per type even if it triples the file count. File count is cheap; "find this type" being unanswerable is expensive.

## Documentation

Every `public` symbol in any new Swift package under `Packages/` is documented with a Swift-DocC triple-slash comment at the time of writing. Treat docs as part of the API surface, not as follow-up work.

- **Format.** Use `///` doc comments above the symbol. First line is a one-sentence summary that fits on a single line and ends with a period. If more context is needed, leave a blank `///` line, then add a discussion paragraph. Use `- Parameter name:` / `- Returns:` / `- Throws:` callouts on `init` and `func` symbols that take parameters or throw. Use Markdown freely (bold, fenced code blocks for examples, backticks for inline code).
- **Cross-references.** Refer to other symbols using double-backticks: `` ``CmuxSetting`` ``. Plain backticks are for non-symbol code (`UserDefaults.standard`, `@AppStorage`).
- **What to document on each symbol.** Types: what they represent and when to use them. Enums: meaning of each case. Init parameters: especially defaults and the reason for them. Properties: what value they hold and any invariants. Methods: what they do, plus parameters/returns/throws. Generic constraints: which `Value` / `Element` shapes the type accepts and why (e.g., `Sendable & Codable`).
- **Examples.** Non-trivial APIs get at least one example in a fenced ` ```swift ` block, ideally a real declaration from this codebase. Keep examples short and idiomatic.
- **Internal vs public.** `internal` and `private` symbols get a one-line `///` when the intent is non-obvious; verbosity is not required at that scope. The public boundary is the one that needs full coverage.
- **No stale docs.** When you change a symbol's behavior or signature, update its doc comment in the same edit. Docs that describe last week's behavior are worse than no docs.
- **Don't comment-narrate the body.** Doc comments describe the contract from the outside. Inline `//` comments inside method bodies are reserved for non-obvious *why*, not *what* (the existing rule from the top-level guidance still applies).

This rule applies to all packages under `Packages/`. Code in the main app target is not retroactively required to be documented, but new `public` symbols added to packages must be.

## Package design discipline

These are the recurring design mistakes that have to be caught at the design step, not at code review:

- **No shared-singleton accessors.** `static let standard` / `shared` / `default` on a package type that holds runtime state is a singleton-by-another-name. Construct the package type at the app's startup site and inject it. `static let` is fine for *declarations* — identifiers, schema entries, enum cases — but not for behavior.
- **No namespace-enums.** `enum Foo { static func bar() }` (a no-case enum used as a namespace) is a fake namespace that fights the rest of the design (no instances, no DI, no test seam). Prefer a value-typed struct passed via constructor when the helper might gain configuration, or a file-scope `private func` for pure helpers internal to one file.
- **No parallel hand-maintained registries.** When a list mirrors a set of declared items (e.g. `catalog.all` mirroring the catalog's stored properties), derive the list via `Mirror` reflection or a macro. Two sources of truth drift silently; the IDE doesn't tell you.
- **Prefer compile-time invariants to runtime traps.** If the pattern is `guard ... else { assertionFailure(...); return default }` for a "programmer error" case, encode it in the type system (phantom types, separate concrete flavors). Runtime traps become silent fallbacks in release builds.
- **No free functions.** Functionality is always scoped to an entity that owns the responsibility: a method on a value type, an extension on the type the operation belongs to, or a member of the Coordinator/Service/Repository that uses it. Top-level `func` declarations (any visibility, including file-scope `private func`) are banned. The only sanctioned exception is a `@convention(c)` trampoline a C API forces on us, marked with a one-line justification.
- **Nested types still count for the one-major-type-per-file rule.** A `private final class WatcherAttachment` inside `JSONConfigFileWatcher.swift` is a major type. Move it to its own file the moment it has a meaningful body.

## Testability

Every public type added to `Packages/` must be **testable from a test target** without launching the app target, without booting AppKit, and without depending on the user's filesystem or `UserDefaults.standard`. Production-grade designs surface a test seam at every boundary:

- **No global state in package code.** Every public type that needs `UserDefaults`, `FileManager`, an on-disk path, an environment variable, or a clock takes it via initializer parameter. Tests pass a `UserDefaults(suiteName:)` scoped to the test, a temp directory URL, a fixed `Date`, etc.
- **No reliance on `.shared` / `.standard`.** A public type that hardcodes `UserDefaults.standard` or `FileManager.default` inside its implementation cannot be tested without polluting the developer's actual settings. Inject these at the seam.
- **Test through injected seams, never a static test hook.** A `nonisolated(unsafe) static var fooForTesting` (or any global mutable "override" a test swaps in) is global state by another name: it leaks across tests, forces `nonisolated(unsafe)`, and usually needs a lock. Replace it with a protocol seam injected through `init` (e.g. `init(commandRunner: any CommandRunning = CommandRunner())`); the test passes a conforming fake. When you extract such a type into a package, deleting the static hook (and the lock it required) is part of the extraction, not a follow-up.
- **Public APIs return values, not side effects, where possible.** A function that mutates global UserDefaults and returns `Void` is harder to test than one that returns the changed value and lets the caller persist. Prefer pure transformations + thin imperative layers.
- **Asynchronous APIs surface their observation as `AsyncStream`.** Tests can iterate `AsyncStream` deterministically and assert the sequence of yielded values. Avoid `NotificationCenter`-only patterns where the test has to spin a runloop.
- **Document the test pattern** alongside any non-trivial public surface. The package's `README.md` and any DocC catalog should show how to instantiate the type with test-friendly dependencies.

If a design is hard to test, it is wrong. Reach for the constructor parameter list, not the test bench.

## Modern Swift concurrency

All new code in `Packages/` and any new files added to the app target use Swift 6 concurrency primitives: `actor`, `async`/`await`, `AsyncStream`/`AsyncSequence`, `@Observable`, `@MainActor`. Old primitives — locks, manual KVO, `@Published`, completion handlers, `DispatchQueue` used as a serial lock — are not allowed.

If you find yourself reaching for a lock to protect ongoing mutable shared state, the type is almost always the wrong shape — promote it to an `actor`. The exception is the narrow lock carve-out below.

**Do not introduce a single-method `actor` purely as a mutex.** An `actor Guard { func claim() -> Bool }` whose only job is to guard a flag is a lock with extra ceremony: it forces synchronous callers — a `Process` termination handler, a `DispatchSource` event handler, a `withCheckedContinuation` resume race — through `Task { await guard.claim() }`, which adds suspension points, ordering hops, and reentrancy surface to what is fundamentally a synchronous compare-and-set. That makes the code worse, not safer. A tiny synchronous guard like that belongs in the lock carve-out, not an actor.

When **extracting** existing code that uses a forbidden primitive into a package, reconsider the shape at the seam rather than copying it blindly — usually it wants an `actor`. But a one-shot single-resume guard (a `Process` termination handler vs. a timeout vs. a spawn failure racing to resume one `withCheckedContinuation`) is exactly a case the lock carve-out covers: keep a synchronous primitive, hidden behind the type. Drain `Process` pipes concurrently on detached tasks keyed by the raw fd (an `Int32` is `Sendable`; a `FileHandle` is not).

**Forbidden in new code (no exceptions without a written justification in the PR description):**

- **Locks.** `NSLock`, `NSRecursiveLock`, `os_unfair_lock`, `OSAllocatedUnfairLock`, `pthread_mutex_t`, `Synchronization.Mutex`, `DispatchSemaphore` used as a lock. Use `actor` isolation. Mutable shared state belongs in an actor; reads and writes are `async`. (Narrow carve-out below: a lock is allowed where the `actor`/`async` alternative would genuinely worsen the code, with justification.)
- **KVO via `NSObject` subclassing.** Any `class Foo: NSObject` whose purpose is to override `observeValue(forKeyPath:...)` or call `addObserver(_:forKeyPath:...)`. Replace with `NotificationCenter.default.notifications(named:)` `AsyncSequence`, or the `NSKeyValueObservation` token API at the seam only.
- **`DispatchQueue` used as a synchronization primitive.** A `DispatchQueue(label:)` accessed via `queue.sync { ... }` to serialize mutable state is a lock with different syntax. Use an `actor`. Queues are fine for *event delivery* (e.g. a `DispatchSource` handler), not for protecting state.
- **Combine for change propagation.** No `@Published`, no `ObservableObject`, no `PassthroughSubject`/`CurrentValueSubject`, no `AnyCancellable` for change observation. Use `@Observable` (Observation framework, Swift 5.9+) for SwiftUI state, or `AsyncStream`/`AsyncSequence` for cross-actor change propagation.
- **Completion-handler APIs.** Authoring a new public API with a `(Result<T, Error>) -> Void` or `(T?, Error?) -> Void` callback is forbidden. Use `async throws -> T`. When wrapping a legacy callback at the boundary, use `withCheckedContinuation`/`withCheckedThrowingContinuation` and keep it confined to that one seam.
- **`DispatchQueue.main.async { ... }`.** Annotate the destination with `@MainActor`. Call sites either `await` the main-isolated function or are themselves `@MainActor`.
- **Sleeping as a synchronization substitute.** `Task.sleep` / `Clock.sleep` (or any sleep) used to *poll* for a condition, to let state "settle" before reading it, or to *race* a callback/animation is forbidden — use a real signal (`AsyncStream`, `NSKeyValueObservation`, a completion, a state change). `DispatchQueue.asyncAfter` is banned outright (it is neither cancellable-by-structure nor testable). A *bounded, cancellable, intended* delay or deadline is allowed under the `Clock.sleep` carve-out below.

**Required shape:**

- Mutable shared state → `actor`. Reads/writes/reset are `async`. Observers receive `AsyncStream` returned by the actor.
- SwiftUI view-render-friendly state → `@Observable @MainActor` view-model that subscribes to the actor's `AsyncStream` and projects snapshots. Don't read actor state synchronously from view code.
- Cross-process / cross-thread invariants → expressed via actor isolation, not via locks or queues.
- New public observable surfaces → `AsyncStream` or `AsyncSequence`. Not callbacks, not `@Published`, not raw `NotificationCenter` subscription.

**Acceptable with a one-line justification comment on the declaration:**

These low-level primitives have no async-native replacement. They must be hidden behind an `AsyncStream` or `actor` surface; callers never see them.

- `DispatchSource.makeFileSystemObjectSource` for file watching (no Foundation async equivalent).
- `DispatchSource.makeReadSource`/`makeWriteSource` for low-level socket I/O.
- **A bounded, cancellable `Clock.sleep` (preferred) or `Task.sleep` for a genuine delay/deadline** that is itself the intended behavior — a minimum display duration, an auto-dismiss, a check timeout. Drive it from an *injected* `Clock` (or a duration) so tests advance virtual time with no real waiting, and wire the sleeping `Task`'s cancellation to the relevant lifecycle so a state transition cancels the pending delay (store the `Task`, cancel it on transition; or use `withTaskCancellationHandler`). For true delays/deadlines only, never to poll, settle, or race — those still require a real signal. One-line justification on the call site.
- `DispatchSource.makeTimerSource` (one-shot) **only when a genuine deadline must fire outside any async context** — a non-`async` type with no `Task` to host the sleep. Prefer the `Clock.sleep` carve-out above whenever the code is already on an actor or in async code (it is cancellation-integrated and testable; a raw `DispatchSource` timer is not, and has suspend/resume/cancel footguns). Hide the timer behind the type, cancel it on the non-timeout path, and never use it to poll or fake a sleep.
- A **lock for a synchronous compare-and-set called from non-async callbacks**, where promoting to an `actor` would only add `Task`/`await` hops and reentrancy. The canonical case is a one-shot resume guard: several synchronous `Process`/`DispatchSource` callbacks race to resume one `withCheckedContinuation` exactly once. `OSAllocatedUnfairLock(initialState:)` guarding a `Bool` (claimed once, checked synchronously in each callback) is correct, deterministic, and lets the callback resume the continuation inline. This carve-out is for short, non-blocking critical sections over a tiny flag/counter — not for guarding ongoing domain state (that is still an `actor`). Keep it private to the type, with a one-line justification.
- `NSKeyValueObservation` token (the closure-based API) when wrapping a Foundation/AppKit type that exposes change only via KVO.

**`@unchecked Sendable` and `nonisolated(unsafe)`:**

Both require a comment on the declaration explaining the safety argument. Examples that pass review:

```swift
// Wraps DispatchSourceFileSystemObject; every mutation happens on `queue`.
private final class WatcherAttachment: @unchecked Sendable { ... }

// UserDefaults is Apple-documented thread-safe; OK to read nonisolated.
private nonisolated(unsafe) let defaults: UserDefaults
```

Without a justification comment, the diff is rejected. `@unchecked Sendable` on an entire actor or struct is almost always wrong; prefer `nonisolated(unsafe) let` on the single non-Sendable property.

**Scope and enforcement:**

- Applies to: every new file in `Packages/`, every new file in the app target, every meaningful rewrite of an existing Swift file.
- Existing app target code may continue to use the old primitives until rewritten. Do not retrofit blindly.
- Code review checklist (Codex, CodeRabbit, Greptile, and human reviewers): reject diffs that introduce `@Published`/`ObservableObject`/`DispatchQueue.main.async`/`addObserver(_:forKeyPath:...)`/`DispatchQueue.asyncAfter` in new code, or `Task.sleep`/`Clock.sleep` used to poll, settle, or race rather than as a bounded, cancellable, injected-clock delay with justification. Reject a lock (`NSLock`/`OSAllocatedUnfairLock`/etc.) or `@unchecked Sendable`/`nonisolated(unsafe)` unless it falls under a documented carve-out *and* carries a one-line justification — and reject a single-method `actor` that exists only to guard a flag (use the lock carve-out instead).

## Detailed references

- Read [references/package-boundaries.md](references/package-boundaries.md) for detailed package extraction, dependency graph, composition-root, and pbxproj wiring guidance.
- Read [references/concurrency-carveouts.md](references/concurrency-carveouts.md) for detailed examples and review guidance around actors, locks, DispatchSource, sleep, `@unchecked Sendable`, and `nonisolated(unsafe)`.
- Read [references/file-api-discipline.md](references/file-api-discipline.md) for one-type-per-file, DocC, public API, and design-smell details.
