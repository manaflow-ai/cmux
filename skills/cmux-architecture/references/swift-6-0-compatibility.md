# Toolchain and macOS 14 compatibility

## Swift version

The Swift 6.0 / Xcode 16.2 syntax rule (no trailing commas in parameter lists,
no type-level `nonisolated`) is a classic-app (`main`) rule. It does not apply to
cmux-next: `Packages/macOS/CmuxNext/Package.swift` declares
`swift-tools-version: 6.2`, so the app needs Xcode 26.

Xcode releases still differ. The nightly compiles Release with the Xcode pinned
for the macOS 26 pool in `scripts/ci/xcode-pins.txt`, and a newer local Xcode
accepts code that it rejects (for example `isolated deinit` on a class isolated
only by `.defaultIsolation(MainActor.self)`). Xcode 26 releases also differ from
each other: Xcode 26.3 rejects `Bundle.module` in nonisolated code that 26.6
accepts. Before relying on such code, run:

```bash
scripts/cmux-next/check-release-compile.sh
```

## macOS 14 at runtime

The app deploys to macOS 14.0 (`MACOSX_DEPLOYMENT_TARGET` in
`cmux.xcodeproj`, `.macOS(.v14)` in the package). macOS 26-only APIs stay behind
their `@available` / `#available` checks.

On macOS 14 the back-deployed `TaskLocal.withValue` built by Xcode 26 can abort
with "freed pointer was not the last allocation" when an async binding's payload
size is only known at run time, which includes any struct holding a Foundation
`UUID`, `Date` or `URL`. Stdlib scalars, `String` and arrays of them are
fixed-size and safe. Box such a payload behind a reference, or bind it inside a
task as `ActionRunScope` does, and test the binding on macOS 14.
