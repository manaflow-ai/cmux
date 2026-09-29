# Package Boundaries

Expands the package extraction and layering rules in [../SKILL.md](../SKILL.md).

## Domain names vs slice names

Good (a domain): `CmuxSettings`, `CmuxSettingsUI`, `CmuxAppearance`, `CmuxControlSocket`.

Weak (a slice): `CmuxAppearanceMath`, `CmuxWorkspaceModel`, `CmuxFooFormatting`, `CmuxFooLogic`, `CmuxFooState`. Slices force callers to depend on several sibling packages any time they touch the real domain.

## Extract leaf-first

Extracting the package with no internal dependencies first keeps the migration incremental: fewer dependency edges, fewer project-file entries, simpler tests, a clearer rollback path. It also avoids needing several downstream packages to exist before one package compiles.

## Composition root

The executable app target names concrete services and repositories and injects them. No global containers, no runtime-state singletons, no `static let shared`, no service lookups from package internals. SwiftUI `Environment` carries already-constructed observable models down a view tree, never service wiring.

## Executable target boundary

A lower package cannot extend a higher-owned type without inverting the dependency direction, so `AppDelegate+*` extensions do not move down. Extract the behavior into a Coordinator/Service/Repository, inject it into the god object or composition root, and reduce the original extension to a one-line forward.

## pbxproj wiring

A new module inside `Packages/macOS/CmuxNext` is a target in its `Package.swift`
and needs no project edit. `cmux.xcodeproj` lists directly linked packages
explicitly. Linking `Packages/<Group>/CmuxFoo` into an Xcode target (`cmux-next`,
`cmux-cli`, `cmuxCLITests`) means mirroring an existing package's entries:

- one `XCLocalSwiftPackageReference` in the project's `packageReferences`
- one `XCSwiftPackageProductDependency`
- one `PBXBuildFile` linked in the Frameworks phase of every target that imports it

Link it into `cmuxCLITests` as well when those tests import it. Copy an existing
entry for the exact shape, then run:

```bash
scripts/normalize-pbxproj.py
scripts/check-pbxproj.sh
```
