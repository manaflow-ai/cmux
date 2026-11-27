# File and API Discipline

Expands the file organization, DocC, and design-smell rules in [../SKILL.md](../SKILL.md).

## What gets its own file

Public API types, internal types with meaningful bodies, private nested types that grew past a tiny helper, type-erased wrappers, and conformance extensions for externally owned types.

A helper can stay with its parent while it is private and trivial (a nested enum for local branching, a one-line private extension). Move it the moment it has lifecycle, state, a protocol conformance, or enough logic to test independently.

## DocC quick examples

```swift
/// Stores a typed ``CmuxSetting`` value.
```

```swift
/// Reads from `UserDefaults.standard` only when injected by the caller.
```

Double backticks reference symbols; plain backticks are non-symbol code.

## Design smells

```swift
// Fake namespace: no instances, no DI, no test seam.
enum Foo {
    static func bar() { ... }
}
```

Runtime-state singletons (`static let shared` / `standard` / `default`) are constructed at app startup and injected instead. `static let` stays legal for identifiers, schema entries, and enum cases.

A `guard` plus `assertionFailure` plus a fallback usually means the type model is too weak. Encode the invariant in the type system.

A hand-maintained list that mirrors declared items drifts silently. Derive it via reflection or a macro where practical.
