# WireGuardKit (vendored)

Vendored copy of the `WireGuardKit` Swift package from
[wireguard-apple](https://git.zx2c4.com/wireguard-apple/), MIT licensed
(see `COPYING`). It is the WireGuard engine inside the cmux Cloud tunnel
system extension (`TunnelExtension/`).

- Upstream: https://git.zx2c4.com/wireguard-apple (mirror: https://github.com/WireGuard/wireguard-apple)
- Upstream commit: `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1` (tag `1.0.16-27`, 2023-02-15)
- wireguard-go pin: `golang.zx2c4.com/wireguard v0.0.0-20230209153558-1e2c3e5a3c14` (`Sources/WireGuardKitGo/go.mod`)

## Why vendored instead of a remote SwiftPM dependency

The Go half of the kit (`Sources/WireGuardKitGo`) is not built by SwiftPM. The
upstream integration expects the consuming Xcode target to run `make` inside the
SwiftPM checkout directory, whose location depends on `-clonedSourcePackagesDirPath`
and DerivedData layout. Keeping the sources in-tree gives the build phase
(`scripts/build-wireguard-go.sh`) a fixed path and pins the Go module set and the
Swift adapter to one reviewed snapshot.

## Local modifications

- `Sources/WireGuardKit/TunnelConfiguration+WgQuickConfig.swift` and
  `Sources/WireGuardKit/String+ArrayConversion.swift` were moved here from the
  upstream `Sources/Shared/Model` (part of the WireGuard app target, not the
  kit) so the extension can parse the wg-quick config the cmux app writes. The
  parser's `init(fromWgQuickConfig:called:)`, `asWgQuickConfig()`, and
  `ParseError` are `public`; nothing else changed.
- `Sources/WireGuardKitGo/Makefile` and `goruntime-boottime-over-monotonic.diff`
  are not vendored. `scripts/build-wireguard-go.sh` replaces the Makefile and
  builds with the stock Go toolchain. The runtime patch makes Go timers count
  time spent asleep, which matters for iOS background wake-ups; the cmux
  extension is macOS-only and re-handshakes through the adapter's network path
  monitor after wake, so it is intentionally skipped.
- `Sources/WireGuardKitC/WireGuardKitC.h` gains `#include <sys/types.h>`: the header
  uses `u_int32_t`/`u_char` without declaring where they come from, which Xcode 26's
  strict clang module import rejects ("declaration of 'u_int32_t' must be imported
  from module ... before it is required").
- `Package.swift` excludes only the Go sources that exist in this copy.

## Updating

1. Fetch the new upstream commit and copy `Sources/WireGuardKit`,
   `Sources/WireGuardKitC`, `Sources/WireGuardKitGo` (minus the Makefile and
   runtime patch) and `Sources/Shared/Model/{TunnelConfiguration+WgQuickConfig,String+ArrayConversion}.swift`.
2. Re-apply the `public` modifiers listed above.
3. Update the commit and wireguard-go pin in this file and in
   `THIRD_PARTY_LICENSES.md`.
4. Build a tagged Debug app so `scripts/build-wireguard-go.sh` exercises the new
   `go.mod`/`go.sum`.
