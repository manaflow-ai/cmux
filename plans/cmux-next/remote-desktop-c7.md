# cmux-next remote desktop: C7 shared crates, CI and license gates (plan)

Status: plan for the C7 cmux-tui window (coordinator queue slot 9), lane 17, 2026-10-05. Inputs: remote-tab-protocol.md section 7 (C7), the lane note's C1-C8 decisions, coordinator decisions D-RT-RD1 (Swift VideoToolbox decode for stage 1) and D-RT-RD2 (app-linked crates are MIT/Apache only; x264 stays in the host binary), and the OpenH264 rule below.

## 1. Crate split

| Crate | Workspace | License | Contents | Links into |
| --- | --- | --- | --- | --- |
| `cmux-rd-proto` | cmux-tui | MIT | wire formats as today, plus typed control behind a `serde` feature (off by default): `Control` (hello with `service` and `caps`, welcome, start, stop, started, refused, ended, stats, `stream.open`, `bulk.credit`), golden JSON vectors in `tests/` | app (through cmux-app-ffi), host, remote browser |
| `cmux-rd-core` | cmux-tui | MIT | unchanged role (pure: FEC, packetize, reassembly, CC, flow, ladder, input, session table, policy, `service` negotiation) | app, host, remote browser |
| `cmux-rd-engine` (new) | cmux-tui | GPL-3.0-or-later (workspace; license question open) | the shared media engine, sans-I/O (decision 2026-10-05, accepted by the umbrella owner): frame gate, congestion control, packetize with adaptive FEC, 16-frame NACK history (64 resends per feedback), loss measurement, recovery keyframes at most every 250 ms, exactly-once input with acks; inputs are damage, encoded frames and received datagrams with the caller's clock, outputs are encode requests, datagrams to send and input to inject. Each source keeps its own carrier loop, capture and encoder; no X11, no codec, no sockets | host, remote browser host |
| `cmux-encode` (new) | cmux-tui | MIT | `Encoder` backends: VideoToolbox (macOS, objc2-video-toolbox) and OpenH264 (feature `openh264-source`, for tests and the bench decoder only; see section 4) | host, remote browser host |
| `cmux-rd-host` | own workspace | GPL-3.0-or-later | the Linux desktop source (XDamage, XShm, XTest), the `cmux-rd` binary, and x264 (feature `x264`, default on) | the `cmux-rd` binary only |

Rules: the `Control` type has one definition (cmux-rd-proto); cmux-rd-host's `wire.rs` and the Swift copy `RemoteRdControl` follow it (Swift keeps a copy pinned by golden JSON tests, because the app does not parse JSON in Rust). cmux-remote-browser depends on proto, core, engine and encode, never on cmux-rd-host. Cargo.toml and Cargo.lock change (two new workspace members, `serde` and `serde_json` as optional proto deps already in the lock): this is why C7 needs a window.

Order inside the window: (1) proto `serde` feature + golden vectors, host switches to it (red: a host test that parses the proto vectors); (2) cmux-rd-engine with the media logic moved from `stream.rs` (landed sans-I/O: the host's `MediaSession` keeps its I/O loop and delegates to `MediaEngine`); (3) cmux-encode with the VideoToolbox encoder moved from `vt.rs` and the OpenH264 backend (3a source/runtime, 3b VideoToolbox gated on a fleet Mac through cmux-ci, coordinator rule 2026-10-05); (4) the CI and license jobs below. Each step lands red-first with its own gate.

## 2. CI job for the remote desktop crates and Swift tests

Status after 62c2d7a566f: CmuxNext links the pinned `CCmuxAppFFI` release (cmux-tui/crates/cmux-app-ffi, which contains cmux-rd-ffi), so `RemoteRdCoreTests` and `RemoteRdInputTests` now build and run in every package test lane against the pinned release. Two gaps stay:

1. Rust tests of the own-workspace crates. New job `rd-crates` in `.github/workflows/cmux-tui.yml` (lint and test matrix, Linux), path filter `cmux-tui/crates/cmux-rd-*/**` and `cmux-tui/crates/cmux-app-ffi/**`:
   - `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings`, `cargo test --locked` in `cmux-rd-ffi` and `cmux-app-ffi`;
   - in `cmux-rd-host`: install `libx264-dev` (apt, pinned version) and run the same three with default features, plus `cargo test --locked --no-default-features`;
   - in the cmux-tui workspace (after C7): `cargo test -p cmux-rd-proto -p cmux-rd-core -p cmux-rd-engine -p cmux-encode`.
   Expected cost under 3 minutes on the 32 vCPU runner with the shared cache.
2. Swift tests against unreleased FFI sources. When a branch changes the FFI sources, the pinned release is stale until a maintainer publishes the new one (app-ffi-release.yml cannot create the tag while workflow files changed; lane 17 published cmux-app-ffi-455c421e769 by hand on 2026-10-05). New step in `cmux-next.yml`, only when the pin check reports "sources differ": build the xcframework from the branch (`scripts/cmux-next/build-app-ffi.sh`), point SwiftPM at it with a local `binaryTarget` override (`CMUX_NEXT_APP_FFI_LOCAL=1` in Package.swift, never set in release builds), and run `RemoteRdCoreTests`, `RemoteRdInputTests`, `RemoteRdStreamTransportTests` and the sidebar reducer suites. The pin check stays red until the new release is pinned, so nothing merges on the local build alone.

## 3. License gates

1. **x264 never enters an app-linked graph.** New script `scripts/cmux-next/check-app-crate-licenses.sh`, run in cmux-next.yml and in the `rd-crates` job: for every crate that the app links (`cmux-app-ffi` and its dependency closure, from `cargo metadata --locked --format-version 1` in `cmux-tui/crates/cmux-app-ffi`) and for `cmux-remote-browser`'s closure, it fails when any package name or `links` key matches `x264`, `cmux-rd-host`, or a `*-sys` crate that builds x264, and when any crate in those closures has a license that is not on the allowlist below. A red test first: a fixture manifest that adds `cmux-rd-host` as a dependency must make the script fail.
2. **cargo-deny allowlist for app-linked crates.** `cmux-tui/deny-app.toml` (separate from any workspace deny config), checked with `cargo deny --manifest-path cmux-tui/crates/cmux-app-ffi/Cargo.toml check licenses bans` and the same for cmux-remote-browser: `allow = ["MIT", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Unicode-3.0", "Zlib"]`, `[bans] deny = [{ name = "x264" }, { name = "cmux-rd-host" }]`. cargo-deny is pinned by version and checksum in the job (no installer scripts).
3. Today's metadata conflict to fix in the same window: `cmux-rd-ffi` and `cmux-app-ffi` declare `GPL-3.0-or-later` in their Cargo.toml (inherited from the license lane's GPL sweep), although they link no GPL code. The gate above would fail on them. The license lane decides their license field (MIT is what D-RT-RD2 requires for app-linked crates); the window carries that change.

## 4. OpenH264 rule (coordinator decision 2026-10-05)

- Mac encodes and decodes with VideoToolbox. No OpenH264 in the app.
- OpenH264 built from source is allowed only in tests and in the bench decoder (`cmux-encode` feature `openh264-source`, never a default feature, never in a shipped binary). The license gate in section 3 also fails when `openh264-source` is enabled in a shipped binary's feature set (`cmux-rd`, `cmux` release builds).
- A shipped Linux or Windows host that needs software H.264 without x264 uses Cisco's prebuilt OpenH264 binary, downloaded at first use (version pinned, SHA-256 checked, stored per user, loaded with `dlopen`), so Cisco's patent license covers it. `cmux-encode` gets an `openh264-runtime` backend that loads that library and never compiles OpenH264 source.
- cmux-rd-host today links OpenH264 from source as its non-x264 codec (`--codec openh264`). Under this rule that path becomes test and bench only; the window moves it behind `openh264-source` and adds the runtime backend before any host build ships.

## 5. Verification for the window

Red-first per step; Testbox gates (fmt, clippy, tests for every touched crate and the own workspaces); `check-app-ffi-pin.sh` green with a new app FFI release pinned; the license script red on the fixture and green on the tree; the focused cmux-tui.yml run on the landed SHA; the package suites `RemoteRdCoreTests`, `RemoteRdInputTests`, `RemoteRdControlTests`, `RemoteRdStreamTransportTests` on cmux-ci.
