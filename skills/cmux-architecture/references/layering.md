# Layers and Roles

Expands the layering rules in [../SKILL.md](../SKILL.md): which layer a type
belongs to, how dependencies are injected, and where state lives.

## Five layers

Dependencies point only downward:

1. **Core**: pure `Sendable` values, IDs, DTOs, errors, shared protocol seams. No AppKit/SwiftUI/I/O. The lift target when two domains need the same type.
2. **Services / infrastructure**: `actor`s implementing core protocols against the outside world (process/PTY, filesystem, sockets, web API, notifications, auth). One package per cohesive capability.
3. **Domain / state**: `@MainActor @Observable` models plus Coordinators, one package per feature domain, owning that domain's mutable state. Exemplar `CmuxNextSettings`.
4. **UI**: SwiftUI/AppKit views, one UI package per domain package, depending only on its domain package plus Core, never a Service directly.
5. **Executable** (`App/main.swift` plus the `CmuxNextApp` module): thin composition shim, no business logic.

## Classify every extracted entity

- **Coordinator**: `@MainActor @Observable` orchestrator that sequences a user flow and owns navigation/selection/lifecycle state, calling Services and child models. Does no I/O itself.
- **Service**: `actor` (or `@MainActor` only when an AppKit main-thread API forces it) performing one outside-world capability; exposes `async`/`await` plus `AsyncStream`; holds only its own resource handles and no UI state.
- **Repository**: `actor` mediating one persistence source of truth (file, defaults, web API) behind CRUD-shaped async methods returning value types. A settings file store is the typical example.

## Dependency inversion and the composition root

Lower packages publish protocols; concrete Services/Repositories conform; higher
layers depend on `any Protocol`, never the concrete type, and never a stored
property reaching across modules. Constructor (`init`) injection only: no global
container, no singleton, no `static let shared`, no service lookups from package
internals.

The executable app target is the single composition root, the one place
concretes are named and the object graph is assembled. SwiftUI `Environment` may
carry already-constructed `@Observable` models down a view tree, never service
wiring.

## State and SwiftUI

Domain state lives in `@MainActor @Observable` models, never
`ObservableObject`/`@Published`. A god model decomposes into cohesive child
`@Observable` sub-models owned by their domain packages and composed by held
reference; cross-domain reads go behind read-only protocols.

In views use `@State` (owned), `@Bindable` or plain `let` (passed in), or
`@Environment(M.self)` plus `.environment(...)` (injected). Never `@StateObject` /
`@ObservedObject` / `@EnvironmentObject` / `.environmentObject(_:)`.

## Executable-target boundary (invert, never work around)

1. `CmuxNextApp` (its `AppDelegate` and composition types) is the thin composition shim. That residual is the intended end state, not debt.
2. A type is declared in exactly one module and a lower package cannot extend a higher-owned type, so `AppDelegate+*` extensions do not move down. Extract the behavior into a Coordinator/Service/Repository, have the god object own an instance, and reduce the extension to a one-line forward.
3. Stored properties cannot cross module boundaries. Decompose god-model state into child `@Observable` sub-models owned by domain packages, composed by held reference, with cross-cutting reads behind read-only protocols.

## Testability

Every public type added to `Packages/` must be testable from a test target
without launching the app target, booting AppKit, or depending on the user's
filesystem or `UserDefaults.standard`.

- `UserDefaults`, `FileManager`, on-disk paths, environment variables, and clocks arrive through `init` parameters. Tests pass a `UserDefaults(suiteName:)` scoped to the test, a temp directory URL, a fixed `Date`.
- No implementation hardcodes `.shared` / `.standard`.
- **No static test hooks.** A `nonisolated(unsafe) static var fooForTesting` (or any global mutable override a test swaps in) leaks across tests and usually needs a lock. Replace it with a protocol seam through `init`, e.g. `init(commandRunner: any CommandRunning = CommandRunner())`. Deleting the static hook and its lock is part of the extraction, not a follow-up.
- Prefer returning the changed value and letting the caller persist over mutating global state and returning `Void`.
- Surface observation as `AsyncStream` so tests can assert the yielded sequence, rather than `NotificationCenter`-only patterns that need a runloop spin.
- Show the test-instantiation pattern in the package `README.md` or DocC catalog.

If a design is hard to test, it is wrong. Reach for the constructor parameter
list, not the test bench.
