# cmux iOS

SwiftUI iOS/iPadOS shell for the CMUXMobileCore production path.

Current phase:

- Stack Auth sign-in gate with Apple, Google, email code, and a debug-only `42` shortcut
- QR/manual pairing surface
- CMUXMobileCore pairing payload and attach-ticket decoding
- injectable `CmxByteTransportFactory` runtime hook
- isolated preview host data when no concrete transport is installed
- workspace list, workspace detail, terminal dropdown, and input bar

No Rust, Iroh, or Zig dependency is linked into this shell. Concrete route implementations should enter through `CMUXMobileRuntime`.

Build and reload the simulator:

```bash
ios/scripts/reload.sh --tag iossh
```

Run package tests:

```bash
swift test --package-path ios/cmuxPackage
```
