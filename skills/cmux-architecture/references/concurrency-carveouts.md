# Concurrency Carve-outs

This reference expands the Swift 6 concurrency rules.

## Default shape

Use modern Swift primitives:

- `actor` for mutable shared state
- `async`/`await` for asynchronous APIs
- `AsyncStream` or `AsyncSequence` for observation
- `@Observable @MainActor` for SwiftUI-facing state
- `@MainActor` instead of `DispatchQueue.main.async`

Do not add new `@Published`, `ObservableObject`, completion-handler APIs, KVO observer overrides, or queue-as-lock patterns in new package code or meaningful rewrites.

## Actor, not lock

Ongoing mutable shared state belongs in an actor. If the state has a lifecycle, multiple operations, or can be observed, an actor is almost always the right shape.

Example actor-owned responsibilities:

- process registry
- file watcher state
- socket session table
- retry/idempotency state
- provider lifecycle state

## Single-method actor smell

Do not introduce an actor whose only job is to guard a boolean flag:

```swift
actor ResumeGuard {
    func claim() -> Bool { ... }
}
```

That pattern is usually a lock with extra suspension and reentrancy surface. In synchronous callback races, the callback often needs an immediate compare-and-set, not a `Task { await ... }` hop.

## Lock carve-out

A private lock is acceptable for a short, synchronous compare-and-set called from non-async callbacks where an actor would worsen ordering and reentrancy.

Canonical case:

- process termination handler
- timeout callback
- spawn failure callback
- all race to resume exactly one `withCheckedContinuation`

Use a tiny private guard, document the reason on the declaration, and keep the critical section non-blocking.

This carve-out does not allow locking ongoing domain state.

## DispatchSource carve-outs

These low-level primitives have no async-native replacement and are acceptable behind an async or actor surface:

- `DispatchSource.makeFileSystemObjectSource`
- `DispatchSource.makeReadSource`
- `DispatchSource.makeWriteSource`

Hide the source behind the type. Callers should see an `AsyncStream`, `AsyncSequence`, or actor API, not raw DispatchSource lifecycle.

## Sleep carve-out

`Clock.sleep` or `Task.sleep` is acceptable only for a genuine bounded delay or deadline that is the intended behavior:

- minimum display duration
- auto-dismiss
- check timeout
- deadline for a provider operation

It is not acceptable for polling, settling UI state, or racing an animation/callback.

Prefer an injected `Clock` or duration so tests can advance virtual time. Store and cancel sleeping tasks on lifecycle transitions.

## Timer source carve-out

Use `DispatchSource.makeTimerSource` only when a genuine deadline must fire outside any async context and there is no task to host `Clock.sleep`.

Prefer `Clock.sleep` whenever the code is already async or actor-isolated.

## Sendability escape hatches

`@unchecked Sendable` and `nonisolated(unsafe)` require comments on the declaration explaining why the usage is sound.

Good examples:

```swift
// Wraps DispatchSourceFileSystemObject; every mutation happens on `queue`.
private final class WatcherAttachment: @unchecked Sendable { ... }

// UserDefaults is Apple-documented thread-safe; OK to read nonisolated.
private nonisolated(unsafe) let defaults: UserDefaults
```

Prefer narrowing the escape hatch to one property rather than marking an entire actor or value type unchecked.

## Review checklist

Reject diffs that introduce any of these in new code without a documented carve-out:

- `@Published`
- `ObservableObject`
- `DispatchQueue.main.async`
- `DispatchQueue.asyncAfter`
- `addObserver(_:forKeyPath:...)`
- queue-as-lock synchronization
- lock for ongoing mutable state
- `Task.sleep` or `Clock.sleep` used to poll/settle/race
- `@unchecked Sendable` without a safety comment
- `nonisolated(unsafe)` without a safety comment
