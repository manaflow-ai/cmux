# Concurrency Carve-outs

Examples and review guidance for the Swift 6 concurrency rules in [../SKILL.md](../SKILL.md).

## Actor-owned responsibilities

State with a lifecycle, multiple operations, or observers belongs in an `actor`: process registry, file watcher state, socket session table, retry/idempotency state, provider lifecycle state.

## Single-method actor smell

```swift
actor ResumeGuard {
    func claim() -> Bool { ... }
}
```

A synchronous callback needs an immediate compare-and-set, not a `Task { await ... }` hop. Use the lock carve-out.

## Lock carve-out

Canonical case: a process termination handler, a timeout callback, and a spawn failure callback all race to resume exactly one `withCheckedContinuation`. Keep the guard private to the type, non-blocking, and documented on the declaration. Never for ongoing domain state.

## Sendability escape hatches

```swift
// Wraps DispatchSourceFileSystemObject; every mutation happens on `queue`.
private final class WatcherAttachment: @unchecked Sendable { ... }

// UserDefaults is Apple-documented thread-safe; OK to read nonisolated.
private nonisolated(unsafe) let defaults: UserDefaults
```

Narrow the escape hatch to one property rather than marking an entire actor or value type unchecked.

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
