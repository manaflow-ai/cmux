# iroh Swift FFI spike

Gating-risk spike for making [iroh](https://www.iroh.computer/) the default
cmux iOS-to-Mac transport: prove a Swift process can bind an iroh endpoint,
dial another endpoint by EndpointId through the default n0 relays, and
exchange bytes over one bidirectional QUIC stream (the byte-stream substrate
the existing length-prefixed `CmxByteTransport` mobile protocol rides on).

Result: **green**. See `plans/feat-ios-iroh/DESIGN.md` for the production design.

## Bindings decision: Rust staticlib + minimal C FFI (not iroh-ffi)

The official uniffi bindings repo
[n0-computer/iroh-ffi](https://github.com/n0-computer/iroh-ffi) is **archived**
("provided as a reference example only"); its last release is v0.35.0
(2025-06-23), which tracks pre-1.0 iroh. n0's own guidance for other
languages is to write a small Rust wrapper that exposes only what the app
needs. That is what this spike does: `rust/src/lib.rs` is a ~400-line
staticlib exposing a blocking C API (bind, id, route JSON, online, accept,
connect, recv, send, close) over iroh 1.0.0-rc.1, consumed from Swift via a
plain bridging header (`include/cmux_iroh_ffi.h`).

## Versions

- iroh `1.0.0-rc.1` (n0-error `1.0.0-rc.0`, tokio `1.48`), Rust edition 2024
- rustc/cargo `1.94.0`, targets `aarch64-apple-darwin`, `aarch64-apple-ios-sim`
- Swift harness: `xcrun swiftc -O`, targets `arm64-apple-macos14.0` and
  `arm64-apple-ios17.0-simulator`
- Proof ran on macOS 26.5 host + iPhone 17 simulator (iOS 26.4)

## Build steps

```bash
# once: rustup target add aarch64-apple-darwin aarch64-apple-ios-sim
./build.sh macos      # staticlib + out/swift-harness-macos
./build.sh ios-sim    # staticlib + out/swift-harness-ios-sim
```

Framework links the staticlib needs (found empirically; netdev inside iroh
uses `nw_path_monitor` on iOS and CoreWLAN on macOS):

- macOS: `SystemConfiguration CoreWLAN Security`
- iOS simulator: `SystemConfiguration Security Network`

## Proof

Terminal A (macOS):

```bash
./out/swift-harness-macos listen
# prints endpoint-id + CmxAttachRoute-shaped route JSON, then echoes
```

Terminal B (iOS simulator, booted):

```bash
xcrun simctl spawn booted "$PWD/out/swift-harness-ios-sim" dial <endpoint-id>
```

Observed 2026-06-09 (no relay/addr hints passed to the dialer, pure
dial-by-EndpointId via n0 discovery):

```
mac listener endpoint-id: 8b5505d8915e8389a3bcf1bd2ff1c7ec5f2184da8cf48fd72c2334757ec63c0e
PROOF: dialed by EndpointId, 45 byte(s) echoed in 1.03s connect
echoed 45 byte(s); peer closed stream
ios-sim dial rc=0, mac listener rc=0
```

macOS-to-macOS run of the same proof connected in 0.52s. Home relay assigned
was `usw1-1.relay.n0.iroh-canary.iroh.link` (1.0-rc endpoints currently land
on n0's canary relay fleet; pin/verify before shipping).

## Binary size

- staticlib `libcmux_iroh_ffi.a`: 15 MB per target (`opt-level = "s"`, fat
  LTO, `codegen-units = 1`, debuginfo stripped)
- linked, dead-stripped Swift harness: 7.8 MB (macOS), 7.7 MB (iOS sim);
  a trivial Swift CLI baseline with the same flags is 51 KB, so the
  **real post-link app delta is about +7.7 MB per architecture slice**
- nothing binary is committed; `out/` and `rust/target/` are gitignored

## Known spike-level gaps (deliberate, covered in the design doc)

- fresh `SecretKey::generate()` per bind; production needs Keychain custody
- one global blocking tokio runtime; production wraps calls off-main from
  Swift (the existing `CmxByteTransport` actor pattern already does this)
- no E2E payload encryption beyond iroh QUIC TLS; the Noise-IK / ticket
  authorization story from the existing mobile protocol still applies
