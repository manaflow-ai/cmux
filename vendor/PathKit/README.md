# PathKit (vendored)

Vendored copy of [PathKit](https://github.com/kylef/PathKit), BSD 2-Clause licensed
(see `LICENSE`). cmux does not use it directly; it is a dependency of
[XcodeProj](https://github.com/tuist/XcodeProj), which `Packages/macOS/CMUXProjectModel`
uses for the project panel.

- Upstream: https://github.com/kylef/PathKit
- Upstream commit: `3bfd2737b700b9a36565a8c94f4ad2b050a5e574` (tag `1.0.1`, 2021-09-22, the latest release; `master` is the same commit)

## Why vendored instead of a remote SwiftPM dependency

Upstream's manifest declares `// swift-tools-version:4.2`. Xcode builds Swift 4.2 targets
without explicit modules, and Xcode's compilation cache requires explicit modules
("swift compiler caching requires explicit module build"). PathKit was the only target in
the app build in that state. An uncached PathKit has a module identity that depends on the
DerivedData path, and that propagates through XcodeProj and CMUXProjectModel into the `cmux`
app target, so the app target missed the compilation cache from any DerivedData path other
than the one that populated it (manaflow-ai/cmux#13037).

A local package with the same identity overrides the remote one, so XcodeProj picks this
copy up without any change on its side. Drop this directory and its package reference once
upstream PathKit ships a manifest with tools version 5 or later, or XcodeProj stops
depending on PathKit.

## Local modifications

- `Package.swift`: `swift-tools-version` 4.2 → 5.9. The language mode stays Swift 5.
- `Package.swift`: removed the `PathKitTests` target and its Spectre dependency; `Tests/` is
  not vendored.
- `Sources/PathKit.swift` and `LICENSE` are unmodified.
