# Swift 6.0 compatibility for app-linked code

The macOS app also builds on Intel Macs running macOS 14.5 or later with Xcode 16.2
(Swift 6.0.3), including tagged `./scripts/reload.sh` dev builds.
`GhosttyKit.xcframework` already ships fat x86_64+arm64 slices targeting macOS 13.
Xcode 26 stays the pinned toolchain (`.xcode-version`) for CI, releases and the
iOS app; this pathway is best effort and changes nothing for Xcode 26.

## What stays within Swift 6.0

Code linked into the macOS app (`Sources/`, `CLI/`, `TunnelExtension/`, and the
packages it depends on) stays within Swift 6.0 syntax:

- No trailing commas in parameter or argument lists (SE-0439, Swift 6.1).
- No `nonisolated` on struct, enum, class or protocol declarations (SE-0449,
  Swift 6.1). Member-level `nonisolated` is fine.
- Keep the existing `#if compiler(>=6.2)` / `#else @Sendable` split for
  `@concurrent`. SE-0461 is Swift 6.2; the Swift 6.0 compiler does not implement
  it and only warns that the attribute was renamed, so it must not be relied on
  for the 6.2 semantics.

macOS 26-only APIs stay behind their `@available` / `#available` checks and are
unavailable at runtime on macOS 14.

An async `@TaskLocal` binding stores its payload behind `TaskLocalReference`
(`CmuxFoundation`) and binds it with `withReferencedValue`. On macOS 14 the
back-deployed `TaskLocal.withValue` built by Xcode 26 aborts with "freed pointer
was not the last allocation" when the payload's size is only known at run time,
which includes any struct holding a Foundation `UUID`, `Date` or `URL`.
Stdlib scalars, `String` and arrays of them are fixed-size and may stay unboxed.

## Outside the pathway

`cmuxTests/`, `cmuxUITests/` and `Packages/iOS/` may use newer Swift.
