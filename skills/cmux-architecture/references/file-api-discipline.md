# File and API Discipline

This reference expands file organization, documentation, and design-smell rules.

## One major type per file

Each meaningful `struct`, `class`, `enum`, `actor`, or `protocol` lives in its own file named after the type.

This applies to:

- public API types
- internal types with meaningful bodies
- private nested types that have grown beyond a tiny helper
- type-erased wrappers
- conformance extensions for externally owned types

File count is cheap. Not knowing where a type lives is expensive.

## Allowed small helpers

Small, closely-bound helpers can stay with the parent type when they are private and trivial:

- a tiny nested enum used only for local branching
- a one-line private extension
- a local helper that does not have independent behavior

Move the helper once it has meaningful lifecycle, state, protocol conformance, or enough logic to test independently.

## Extension files

Conformance-adding extensions for a type defined elsewhere go in files such as:

- `TypeName+Conformance.swift`
- `TypeName+Feature.swift`

Do not hide important conformances inside unrelated feature files.

## DocC for public package APIs

Every public symbol in new Swift packages under `Packages/` needs a `///` DocC comment at the time it is written.

Document:

- what a type represents
- when to use it
- enum case meaning
- property invariants
- init parameters and defaults
- method parameters, returns, and throws
- generic constraints

Use double-backtick symbol references for symbols:

```swift
/// Stores a typed ``CmuxSetting`` value.
```

Use plain backticks for non-symbol code:

```swift
/// Reads from `UserDefaults.standard` only when injected by the caller.
```

## Design smells

Avoid runtime state singletons:

- `static let shared`
- `static let standard`
- `static let default`

Static declarations are fine for identifiers, schema entries, and enum cases. Runtime behavior should be constructed at app startup and injected.

Avoid namespace enums:

```swift
enum Foo {
    static func bar() { ... }
}
```

If behavior may need configuration or a test seam, use a value type or service. If it is a pure local helper, keep it private near its caller.

Avoid parallel hand-maintained registries. If a list mirrors declared items, derive it via reflection or a macro where practical.

Prefer compile-time invariants to runtime traps. A `guard` plus `assertionFailure` plus fallback often means the type model is too weak.
