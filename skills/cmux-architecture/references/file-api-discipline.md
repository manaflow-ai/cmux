# File and API Discipline

Expands the file organization, DocC, and design-smell rules in [../SKILL.md](../SKILL.md).

## One major type per file

Name the file after the type (`Control.swift`, `LabeledChoice.swift`,
`ListControl.swift`, not one shared `SettingControl.swift`). Applies to all new
code in `Packages/` and all new app-target files.

- Trivial private helpers, nested types, and single-line extensions used only inside the file may stay with the parent type. Anything with a meaningful body gets its own file, including a `private final class` nested in another file's type.
- Conformance-adding extensions for a type defined elsewhere go in `TypeName+Conformance.swift` or `TypeName+Feature.swift`, not bundled into the consuming feature file.
- Type-erased wrappers live next to what they erase: `Foo.swift` and `AnyFoo.swift`.
- God files are what this rule exists to stop; in `Packages/macOS/CmuxNext`, `scripts/cmux-next/check-no-godfiles.sh` enforces it. Splitting one file per type is correct even if it triples the file count. File count is cheap; "find this type" being unanswerable is expensive.

### What gets its own file

Public API types, internal types with meaningful bodies, private nested types that grew past a tiny helper, type-erased wrappers, and conformance extensions for externally owned types.

A helper can stay with its parent while it is private and trivial (a nested enum for local branching, a one-line private extension). Move it the moment it has lifecycle, state, a protocol conformance, or enough logic to test independently.

## Documentation

Every `public` symbol in a new package under `Packages/` gets a Swift-DocC `///`
comment at the time it is written. Docs are part of the API surface, not
follow-up work. Main app target code is not retroactively required to be
documented.

- First line is a one-sentence summary that fits on one line and ends with a period. Blank `///` line before any discussion paragraph. Use `- Parameter name:` / `- Returns:` / `- Throws:` on `init` and `func` symbols that take parameters or throw. Markdown is fine.
- Reference symbols with double backticks (`` ``CmuxSetting`` ``); plain backticks for non-symbol code (`UserDefaults.standard`).
- Document what a type represents and when to use it, the meaning of each enum case, init parameter defaults and their reason, property invariants, method behavior, and which generic `Value`/`Element` shapes are accepted and why.
- Non-trivial APIs get at least one short example in a fenced `swift` block, ideally a real declaration from this codebase.
- `internal` and `private` symbols get a one-line `///` when the intent is non-obvious. The public boundary is the one that needs full coverage.
- Update the doc comment in the same edit that changes behavior or signature. Doc comments describe the contract from outside; inline `//` is reserved for non-obvious *why*.

```swift
/// Stores a typed ``CmuxSetting`` value.
```

```swift
/// Reads from `UserDefaults.standard` only when injected by the caller.
```

## Package design discipline

- **No shared-singleton accessors.** `static let standard` / `shared` / `default` on a package type holding runtime state is a singleton by another name. Construct at the app startup site and inject. `static let` is fine for declarations (identifiers, schema entries, enum cases), not for behavior.
- **No namespace-enums.** `enum Foo { static func bar() }` is a fake namespace with no instances, no DI, and no test seam. Prefer a value-typed struct passed via constructor when the helper might gain configuration. The repository lint enforces this; see the Swift namespace convention in the root `CLAUDE.md`.
- **No parallel hand-maintained registries.** When a list mirrors declared items (`catalog.all` mirroring stored properties), derive it via `Mirror` reflection or a macro. Two sources of truth drift silently.
- **Prefer compile-time invariants to runtime traps.** `guard ... else { assertionFailure(...); return default }` for a "programmer error" case should be encoded in the type system (phantom types, separate concrete flavors). Runtime traps become silent fallbacks in release builds.
- **No free functions.** Top-level `func` declarations, any visibility including file-scope `private func`, are banned; scope functionality to the entity that owns the responsibility. The only sanctioned exception is a `@convention(c)` trampoline a C API forces, with a one-line justification.

```swift
// Fake namespace: no instances, no DI, no test seam.
enum Foo {
    static func bar() { ... }
}
```
