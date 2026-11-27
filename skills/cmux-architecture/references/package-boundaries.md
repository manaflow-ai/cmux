# Package Boundaries

Expands the package rules in [../SKILL.md](../SKILL.md): what a package is,
where it lives, how it is wired, and how lockfiles and feature flags work.

## What a package must be

cmux is migrating from a single app target into Swift Packages under `Packages/`. Every new package must be:

- **Ergonomic.** Default to internal access; `public` only what downstream consumers actually use.
- **Acyclic.** Packages form a strict DAG. Share a type by lifting it to a lower package or defining a protocol seam in the consumer. Every new dependency edge requires re-checking that the graph stays acyclic.
- **Whole-domain.** One package (or CmuxNext module) owns a full domain (settings, appearance, workspace, terminal, browser, command palette). Math, theme and settings helpers for appearance are folders inside one appearance module, not three modules. A boundary exists because more than one consumer needs the contents, or a build/test seam must exist.

Existing packages under `Packages/` predate this policy; do not use them as design references.

## Domain names vs slice names

Good (a domain): CmuxNext modules such as `CmuxNextSettings`, `CmuxNextControl`, `CmuxNextBrowser` and `CmuxNextSidebar`.

Weak (a slice): `CmuxAppearanceMath`, `CmuxWorkspaceModel`, `CmuxFooFormatting`, `CmuxFooLogic`, `CmuxFooState`. Slices force callers to depend on several sibling packages any time they touch the real domain.

## Extract leaf-first

Extract the package with no internal dependencies first. It keeps the migration incremental: fewer dependency edges, fewer project-file entries, simpler tests, a clearer rollback path. It also avoids needing several downstream packages to exist before one package compiles.

## Group folders

Every package lives physically under exactly one group directory:
`Packages/Shared/<pkg>` (both apps), `Packages/iOS/<pkg>` (iOS only), or
`Packages/macOS/<pkg>` (macOS only). `cmux.xcworkspace/contents.xcworkspacedata`
mirrors that folder shape, with three groups whose container locations are those
folders and every package directory as a FileRef under its folder's group.

The folder is the source of truth. To move a package, `git mv` the directory,
then run:

```bash
python3 scripts/check-workspace-package-groups.py --write
```

Cross-group `.package(path:)` deps use `../../<Group>/<Name>`. Never hand-edit
workspace group membership. CI runs `python3 scripts/check-workspace-package-groups.py --check`
and fails on drift.

## Lockfiles

Do not gitignore cmux-owned `Package.resolved` files; SwiftPM resolution changes
must be visible in PR diffs. Track the root Xcode lockfile and every cmux-owned
package-local `Package.resolved` produced by standalone `swift package resolve` /
`swift build` / `swift test`. A package-local lockfile is the source of truth for
that package's standalone resolution and is not replaced by
`cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Vendored third-party directories may keep their upstream ignore policy. CI runs
`python3 scripts/check-package-resolved-policy.py`.

## Feature flags

A feature flag means a remote PostHog runtime flag. Unless the user explicitly
asks for a compile-time flag, local setting, or environment variable, declare it
with a `FLAG(key: …)` comment in Swift (or in `web/app/lib/feature-flags.ts` for
web) with an owner, a `reviewBy` date and `defaultWhenUnavailable`, evaluate it
in one place, give it live update behavior, and add focused tests.
`scripts/lint-feature-flags.py` enforces the naming, ownership, review-date,
default and single-evaluation rules, and keys in
`scripts/retired-feature-flags.txt` may never return. A local override may
support dogfood but must not be the production control plane.

## pbxproj wiring

The macOS app lives in `Packages/macOS/CmuxNext`, one module per feature. The
only Xcode target, `cmux-next`, links one local package (`Packages/macOS/CmuxNext`)
and its `CmuxNextApp` product. A new module is a target in that `Package.swift`
and needs no project edit; a new package is a dependency in that
`Package.swift`, not a new project reference.

If a change does touch `cmux.xcodeproj`, run:

```bash
scripts/normalize-pbxproj.py
scripts/check-pbxproj.sh
```
