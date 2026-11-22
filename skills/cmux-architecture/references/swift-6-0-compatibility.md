# Swift 6.0 compatibility for app-linked code

The macOS app also builds on Intel Macs running macOS 14.5 or later with Xcode 16.2
(Swift 6.0.3), including tagged `./scripts/reload.sh` dev builds.
`GhosttyKit.xcframework` already ships fat x86_64+arm64 slices targeting macOS 13.
Xcode 26 stays the pinned toolchain (`.xcode-version`) for CI, releases and the
iOS app; this pathway is best effort and changes nothing for Xcode 26.

## What stays within Swift 6.0

Code linked into the macOS app (`App/`, `CLI/`, and the packages they depend
on) stays within Swift 6.0 syntax:

- No trailing commas in parameter or argument lists (SE-0439, Swift 6.1).
- No `nonisolated` on struct, enum, class or protocol declarations (SE-0449,
  Swift 6.1). Member-level `nonisolated` is fine.
- Keep the existing `#if compiler(>=6.2)` / `#else @Sendable` split for
  `@concurrent`. SE-0461 is Swift 6.2; the Swift 6.0 compiler does not implement
  it and only warns that the attribute was renamed, so it must not be relied on
  for the 6.2 semantics.

macOS 26-only APIs stay behind their `@available` / `#available` checks and are
unavailable at runtime on macOS 14.

## Outside the pathway

`cmuxCLITests/` and `Packages/iOS/` may use newer Swift.
