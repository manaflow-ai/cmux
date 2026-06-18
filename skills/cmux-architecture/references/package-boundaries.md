# Package Boundaries

This reference expands cmux package extraction and refactor architecture rules.

## Why package boundaries exist

A package boundary should exist because more than one consumer needs the domain, because a build/test seam is useful, or because the package isolates a cohesive external capability. It should not exist just to make a file list look smaller.

Good package names describe a domain:

- `CmuxSettings`
- `CmuxSettingsUI`
- `CmuxAppearance`
- `CmuxWorkspace`
- `CmuxBrowser`
- `CmuxSocketControl`

Weak package names describe a slice:

- `CmuxAppearanceMath`
- `CmuxWorkspaceModel`
- `CmuxFooFormatting`
- `CmuxFooLogic`
- `CmuxFooState`

Slices force callers to depend on several sibling packages any time they touch the real domain.

## Dependency graph

Packages form a strict downward-only DAG:

1. Core: pure `Sendable` values, IDs, DTOs, errors, and protocol seams. No AppKit, SwiftUI, or I/O.
2. Services/infrastructure: actors implementing core protocols against external systems.
3. Domain/state: `@MainActor @Observable` models and Coordinators.
4. UI: SwiftUI/AppKit views that depend on domain packages and Core, not services directly.
5. Executable: `cmuxApp` and `AppDelegate` as the composition root.

If two domains need a shared type, lift the type to a lower package or define a protocol seam. Do not make sibling packages reach sideways.

## Extract leaf-first

When uncertain, extract the package that has no internal dependencies first. This keeps the migration incremental and avoids needing several downstream packages to exist before one package can compile.

Leaf-first extraction also makes review easier:

- fewer dependency edges
- fewer project-file entries
- simpler tests
- clearer rollback path

## Composition root

The executable app target is the single composition root. Concrete services and repositories are named there and injected into coordinators/models.

Do not introduce:

- global containers
- runtime state singletons
- `static let shared`
- service lookups from package internals

SwiftUI `Environment` may carry already-constructed observable models down a view tree. It should not become the source of truth for service wiring.

## Executable target boundary

`@main` `cmuxApp` and `AppDelegate` stay in the executable target. Do not move extensions of executable-owned types down into lower packages. A lower package cannot extend a higher-owned type without creating the wrong dependency direction.

Instead:

1. Extract behavior into a Coordinator, Service, or Repository in the appropriate package.
2. Inject it into the god object or app composition root.
3. Reduce the original extension to a one-line forward if it must remain.

## pbxproj wiring

`cmux.xcodeproj` lists package dependencies explicitly. Adding `Packages/CmuxFoo` means mirroring existing package entries:

- one `XCLocalSwiftPackageReference`
- one `XCSwiftPackageProductDependency`
- one `PBXBuildFile` linked in the Frameworks phase of every target that imports it

App-target packages link into both `cmux` and `cmux-unit`, so tests can import and inject them. A package linked by the app but not `cmux-unit` can make the app build pass while the test target fails.

After editing the project file, run:

```bash
scripts/normalize-pbxproj.py
scripts/check-pbxproj.sh
```
