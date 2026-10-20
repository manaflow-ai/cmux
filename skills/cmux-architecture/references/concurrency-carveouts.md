# Swift 6 Concurrency

The full forbidden list, the required shape, the carve-outs, and the reviewer
reject-list for the concurrency rule in [../SKILL.md](../SKILL.md).

New code in `Packages/`, new app-target files, and meaningful rewrites use
`actor`, `async`/`await`, `AsyncStream`/`AsyncSequence`, `@Observable`, and
`@MainActor`. Existing app-target code may keep the old primitives until
rewritten. Do not retrofit blindly.

## Forbidden without a written justification in the PR description

- **Locks**: `NSLock`, `NSRecursiveLock`, `os_unfair_lock`, `OSAllocatedUnfairLock`, `pthread_mutex_t`, `Synchronization.Mutex`, `DispatchSemaphore` used as a lock. Ongoing mutable shared state belongs in an `actor` with `async` reads and writes.
- **KVO via `NSObject` subclassing** to override `observeValue(forKeyPath:...)` or call `addObserver(_:forKeyPath:...)`. Use `NotificationCenter.default.notifications(named:)` or the `NSKeyValueObservation` token API at the seam only.
- **`DispatchQueue` as a synchronization primitive** (`queue.sync { ... }` serializing mutable state). Queues are fine for event delivery, not for protecting state.
- **Combine for change propagation**: `@Published`, `ObservableObject`, `PassthroughSubject`/`CurrentValueSubject`, `AnyCancellable`.
- **Completion-handler public APIs** (`(Result<T, Error>) -> Void`, `(T?, Error?) -> Void`). Use `async throws -> T`; wrap a legacy callback with `withCheckedContinuation`/`withCheckedThrowingContinuation` confined to that one seam.
- **`DispatchQueue.main.async`**. Annotate the destination `@MainActor` and `await` it.
- **Sleeping as a synchronization substitute**: any sleep used to poll for a condition, let state settle before reading, or race a callback/animation. `DispatchQueue.asyncAfter` is banned outright (not cancellable by structure, not testable).
- **A single-method `actor` used as a mutex.** See below.

## Required shape

Mutable shared state goes to an `actor` with `async` accessors and an
`AsyncStream` for observers. SwiftUI-render-friendly state goes to an
`@Observable @MainActor` view model that subscribes to that stream and projects
snapshots; never read actor state synchronously from view code. Express
cross-process and cross-thread invariants through actor isolation. New public
observable surfaces are `AsyncStream`/`AsyncSequence`.

State with a lifecycle, multiple operations, or observers belongs in an `actor`:
process registry, file watcher state, socket session table, retry/idempotency
state, provider lifecycle state.

When extracting existing code that uses a forbidden primitive, reshape it at the
seam instead of copying it; usually it wants an `actor`. Drain `Process` pipes
concurrently on detached tasks keyed by the raw fd (`Int32` is `Sendable`,
`FileHandle` is not).

## Carve-outs

Each needs a one-line justification comment on the declaration and must hide
behind an `AsyncStream` or `actor` surface so callers never see it.

- `DispatchSource.makeFileSystemObjectSource` for file watching, `makeReadSource`/`makeWriteSource` for low-level socket I/O (no async-native replacement).
- A bounded, cancellable `Clock.sleep` (preferred) or `Task.sleep` for a genuine delay or deadline that is itself the intended behavior (minimum display duration, auto-dismiss, check timeout). Drive it from an injected `Clock` so tests advance virtual time, store the `Task`, and cancel it on the relevant lifecycle transition. Never to poll, settle, or race.
- `DispatchSource.makeTimerSource` (one-shot) only when a genuine deadline must fire outside any async context, in a non-`async` type with no `Task` to host the sleep. Prefer `Clock.sleep` whenever the code is already async or actor-isolated; a raw timer is not cancellation-integrated or testable and has suspend/resume/cancel footguns.
- A lock for a short, non-blocking synchronous compare-and-set called from non-async callbacks (see below). Not for guarding ongoing domain state.
- `NSKeyValueObservation` token when wrapping a Foundation/AppKit type that exposes change only via KVO.

### Lock carve-out vs single-method actor

```swift
actor ResumeGuard {
    func claim() -> Bool { ... }
}
```

An `actor` like this forces synchronous callers (a `Process` termination
handler, a `DispatchSource` event handler, a `withCheckedContinuation` resume
race) through `Task { await guard.claim() }`, adding suspension points, ordering
hops, and reentrancy surface to a fundamentally synchronous compare-and-set.

Use the lock carve-out instead. Canonical case: a process termination handler, a
timeout callback, and a spawn failure callback all race to resume exactly one
`withCheckedContinuation`, guarded by `OSAllocatedUnfairLock(initialState:)` over
a `Bool`. Keep the guard private to the type, non-blocking, and documented on the
declaration.

## Sendability escape hatches

`@unchecked Sendable` and `nonisolated(unsafe)` require a comment explaining the
safety argument, or the diff is rejected. `@unchecked Sendable` on an entire
actor or struct is almost always wrong; prefer `nonisolated(unsafe) let` on the
single non-Sendable property.

```swift
// Wraps DispatchSourceFileSystemObject; every mutation happens on `queue`.
private final class WatcherAttachment: @unchecked Sendable { ... }

// UserDefaults is Apple-documented thread-safe; OK to read nonisolated.
private nonisolated(unsafe) let defaults: UserDefaults
```

## Review reject-list

Reject diffs introducing any of these in new code without a documented carve-out:

- `@Published`, `ObservableObject`
- `DispatchQueue.main.async`, `DispatchQueue.asyncAfter`
- `addObserver(_:forKeyPath:...)`
- queue-as-lock synchronization
- a lock guarding ongoing mutable state
- an `actor` whose only job is guarding a flag
- `Task.sleep` / `Clock.sleep` used to poll, settle, or race
- `@unchecked Sendable` or `nonisolated(unsafe)` without a safety comment
