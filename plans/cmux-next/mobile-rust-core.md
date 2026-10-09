# Mobile Rust core (proposal, cmuxterm-hq-39, 2026-10-09)

Status: PROPOSAL for the chief. Not a decision until recorded in the spec.

Input: Lawrence 2026-10-09 "move as much into rust as possible; we will have swift + android app, for mobile stuff". Lawrence + Leo 2026-10-09: Swift paper cuts move to Rust; the daemon or core owns state. Existing records: OPTCHAT O1 (one Rust core, no TypeScript twin), SIDEBAR-FFI-PREBUILT (prebuilt xcframework binaryTarget), spec/computer-use.md:33 (no Swift session logic), plans/cmux-next/cloud-ios.md 3.3 (L3 first, L1 later) and R4 (two Iroh stacks), plans/feat-ios-iroh/DESIGN.md:22 (uniffi fork).

## Today (origin/feat-cmux-next 8ac72b3ef43)

- Rust shared with Swift: hand-written C ABIs (cmux-rd-ffi 4.7k lines, cmux-layout-reducer-ffi), combined into one Mac staticlib cmux-app-ffi (scripts/cmux-next/build-app-ffi.sh, macOS only); cmux-terminal-client (4.3k, C ABI, iOS xcframework via cmux-terminal-client-xcframework.yml); manaflow-ai/iroh-ffi fork 1.2.0-cmux.1.ios17 (uniffi 0.31.1 + tokio, has Kotlin output).
- Reusable pure Rust: cmux-link, cmux-wg, cmux-transport, cmux-remote-protocol, cmux-pane-protocol, cmux-conversation (reducer), cmux-server-core::install_key, cmux-host/src/cloud (HTTP behind a trait), first-party-apps/cloud/server, cmux-tui-core sizing_policy.rs.
- Platform-neutral Swift on the phone path: about 107k lines in Packages/ (CmuxIrohTransport 30.4k, CMUXMobileCore 20.0k, CmuxIrxTransport 13.6k, CmuxMobileShellModel 9.6k, CmuxMobileRPC 8.4k, CmuxAuthRuntime 8.1k, CmuxHomeCore 5.3k, CmuxSyncStore 1.7k, CmuxTerminalSizing 511, CmuxInstallAuthCore 353, CmuxTerminalStream 329, CmuxFeedPushCore 281). No Swift client is generated from backend/catalog/cloud-operations.json (174 ops); only TypeScript is.
- Android: no cmux crate targets Android yet.

## Proposal

1. Binding tool: uniffi 0.31 (the version the iroh-ffi fork already uses). One interface definition gives Swift and Kotlin. Hand-written C ABIs stay for the existing Mac libraries until they move.
2. Crate split (all under cmux-tui/crates):
   - cmux-mobile-core: sans-I/O. Catalog wire client types + envelope + error enum, Home mirror and intent log, terminal frame codecs, sizing. Bytes and events in, effects out (the cmux-rd-ffi rule). Tests run on Linux with no device.
   - cmux-mobile-net: tokio. cmux-link, cmux-wg, Iroh, the HTTP effect runner.
   - cmux-mobile-ffi: the ONE uniffi staticlib per platform. The Iroh fork folds into it (no second Rust staticlib: two copies of std and tokio, two runtimes).
3. Async model: one tokio runtime owned by the core. uniffi async maps to Swift async and Kotlin coroutines. Native work comes in through callback interfaces: HttpTransport (URLSession / OkHttp), Signer (Secure Enclave / Android Keystore; the private key never enters Rust), KeyValueStore, PathMonitor. State goes out as snapshot + delta streams; the UI renders and reduces nothing.
4. Codegen: a new emitter next to backend/packages/protocol export-client.ts writes the Rust wire types from cloud-operations.json; backend/catalog/cloud-vectors.json gates it in CI (the same vectors the TS client and cmux-cloud use). Swift and Kotlin get the types through uniffi, never hand-written.
5. Build pipeline: extend cmux-terminal-client-xcframework.yml into cmux-mobile-ffi: xcframework (ios arm64, sim arm64 + x86_64) as a url+checksum binaryTarget (SIDEBAR-FFI-PREBUILT), and cargo-ndk (arm64-v8a, x86_64) + uniffi Kotlin into an AAR on GitHub Packages (manaflow-ai, private). App builds never need a Rust toolchain.
6. Stays native: SwiftUI / Compose UI, CmuxHomeRender, the Ghostty view, APNs / FCM and the notification service extension (memory cap: no Rust there at first), Keychain / Keystore key storage and signing, App Attest / Play Integrity, Stack sign-in web auth, background tasks, the Local Network permission, NWPathMonitor / ConnectivityManager events.

## Order

- Slice 0 (pipeline proof, about 1 day): cmux-mobile-ffi skeleton exposing sizing_policy.rs; both platforms run schemas/terminal-sizing/fixtures.json (Swift XCTest on the xcframework, Kotlin JUnit on the AAR in CI). No product change; it proves build, publish, async and callbacks.
- Slice 1 (first product slice): the catalog wire client + install key requests (Signer callback) + CmuxFeedPushCore. Deletes CmuxInstallAuthCore and CmuxFeedPushCore Swift in the same change; the iOS app then calls generated ops.
- Slice 2: Home mirror and intent log (CmuxHomeCore, CmuxSyncStore) on cmux-conversation.
- Slice 3: terminal frames and render grid (CMUXMobileCore, CmuxTerminalStream) on cmux-terminal-client.
- Slice 4: transport, when cloud-ios.md L1 starts: cmux-link + cmux-wg replace CmuxIrohTransport + CmuxIrxTransport (about 44k Swift lines). Until then the phone stays on irx through the Mac (L3).
- Each slice deletes its Swift in the same change (no twin).

## Decisions I propose (the chief records them)

- MOBILE-RUST-1: shared mobile logic is Rust (cmux-mobile-core/net/ffi); Swift and Kotlin hold UI and platform APIs only.
- MOBILE-RUST-2: uniffi 0.31, one staticlib per platform, Iroh folded in.
- MOBILE-RUST-3: wire types generated from cloud-operations.json and gated by cloud-vectors.json.
- MOBILE-RUST-4: phone transport stays L3 until L1; transport moves last.
- MOBILE-RUST-5: AAR on GitHub Packages (manaflow-ai); Maven Central only if a public SDK is wanted.

## Risks

Binary size (Iroh about +7.7 MB per architecture), uniffi async cancellation, crash symbolication across the FFI (ship dSYMs / native symbols with each artifact), the notification extension memory cap, two Iroh versions on the wire during the move (R4).

Strongest objection: "an FFI core adds build and debug cost and the Swift works today". Answer: Android needs the same logic, so the choice is one Rust copy or a Swift copy plus a Kotlin copy. The cost stays bounded: move only code with a wire contract or test vectors, keep cores sans-I/O, ship one prebuilt library, delete the Swift in the same change.
