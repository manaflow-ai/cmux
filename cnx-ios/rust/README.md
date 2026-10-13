# cnx-ios Rust core

The portable connectivity core of the cnx-ios app. [`../PROTOCOL.md`](../PROTOCOL.md)
is the contract; these crates implement its client side, the Mac side, and the
Swift bindings.

| Crate | What |
| --- | --- |
| `crates/cnx-link` | `Link` (framing, channel mux, ping, open/close), the signaling WebSocket client, the HTTP API client, and the two dialers behind one `Dialer` trait: `webrtc` (webrtc-rs data channel `cnx-link`) and `wireguard` (cmux-wg userspace tunnel). `TransportKind` selects one. The `testing` feature adds an in-process fake signaling server. |
| `crates/cnx-hostd` | The Mac bridge binary: registers the Mac, holds the signaling socket, admits dials from the owner's own phones, answers both transports, serves the link services. |
| `crates/cnx-ffi` | uniffi 0.31.1 bindings for Swift, plus `scripts/build-xcframework.sh`. |

`cmux-wg` and `cmux-transport` are used by path from `../../cmux-tui/crates`.

## Build and test

```bash
cd cnx-ios/rust
cargo test -j 6
cargo clippy -j 6 --all-targets -- -D warnings
cargo fmt --check
```

The tests need no network: they start a fake signaling server on loopback.

- `cnx-link/tests/loopback.rs`: the same `Link` over WebRTC, WireGuard direct
  and WireGuard through the relay frames (endpoints stripped), 200 KB echo,
  `unknown_service` refusal, ping; dialing another user's Mac is refused.
- `cnx-hostd/tests/host.rs`: hostd over all three paths with every service
  (`echo`, `daemon` against a fake cmux-tui socket with allowed and denied
  lines, `file` inside and outside the roots, `acpmux` against a fake
  loopback WebSocket with bearer auth, an unknown service), and admission
  refusal when the backend does not stamp `fromUserId`.
- `cnx-ffi/tests/ffi.rs`: the exported API (connect, observer events,
  open/send/recv/close, ping) over both transports.
- `cnx-hostd` `policy::tests::mirrors_the_swift_allowlist` fails when
  `DaemonLanePolicy.swift`'s allowlist and the Rust copy drift.

## iOS xcframework

```bash
cnx-ios/rust/scripts/build-xcframework.sh
```

Produces `cnx-ios/CnxKit/Frameworks/CnxFFI.xcframework` (slices `ios-arm64`
and `ios-arm64-simulator`, each a static `CnxFFIFFI.framework`) and the Swift
bindings `cnx-ios/CnxKit/Sources/CnxFFI/CnxFFI.swift` (module `CnxFFI`). It
installs missing rustup targets, uses
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the selected
command line tools have no iOS SDK; `xcode-select` is left alone), and then
typechecks the bindings and links a test program for the simulator.
Each slice's archive is about 60 MB (all of std and every dependency); an
app links only what it uses.
`JOBS` (default 6) bounds cargo. The xcframework is not committed
(`.gitignore`); the generated Swift is, so the API is reviewable.

`Package.swift`:

```swift
.binaryTarget(name: "CnxFFIFFI", path: "Frameworks/CnxFFI.xcframework"),
.target(name: "CnxFFI", dependencies: ["CnxFFIFFI"], path: "Sources/CnxFFI",
        linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]),
```

webrtc-util depends on nix 0.26, which names libc items current libc no longer
exports for iOS. The script builds the iOS slices against a patched copy of
nix (it defines those Darwin constants itself) through `--config patch`, and
restores `Cargo.lock` afterwards. Host builds use stock nix.

### Swift API (module `CnxFFI`)

```swift
func connect(baseUrl: String, token: String, teamId: String, deviceId: String,
             macDeviceId: String, transport: Transport,
             observer: LinkObserver?) async throws -> LinkHandle   // throws CnxError
func cnxVersion() -> String

enum Transport { case webRtc, wireGuard }
enum LinkPath { case direct, relay, turn }
enum LinkEvent {
    case connecting(transport: Transport)
    case connected(transport: Transport, path: LinkPath)
    case pathChanged(path: LinkPath)
    case rtt(millis: UInt32)
    case disconnected(reason: String)
}
protocol LinkObserver: AnyObject, Sendable { func onEvent(event: LinkEvent) }

class LinkHandle {
    func openChannel(service: String, argsJson: String) async throws -> ChannelHandle
    func ping() async throws -> UInt32          // milliseconds
    func transport() -> Transport
    func path() -> LinkPath
    func isClosed() -> Bool
    func close()
}
class ChannelHandle {
    func id() -> UInt32
    func send(data: Data) async throws
    func recv() async -> ChannelMessage         // .data(bytes:) or .closed(code:reason:)
    func close(code: String, reason: String) async
}
enum CnxError: Error {   // uniffi keeps the Rust variant case for errors
    case InvalidArgument(message: String), Signaling(message: String)
    case Refused(code: String, message: String), Timeout
    case Transport(message: String), Closed(message: String)
}
```

`deviceId` is the phone's Keychain UUID; `macDeviceId` comes from
`GET /v1/teams/:teamId/macs`. `connect` fetches `GET /v1/ice` (8 s budget; on
failure it dials with host candidates only), opens the signaling socket and
dials. The observer is called on a library thread. Device ids must be UUIDs
(WireGuard relay frames carry them as 16 bytes).

## cnx-hostd

```bash
cargo build --release -p cnx-hostd
CNX_BASE_URL=https://cnx-ios-api-dev.<account>.workers.dev \
CNX_TEAM_ID=<stack team id> \
CNX_REFRESH_TOKEN_FILE=~/.config/cnx/refresh-token \
target/release/cnx-hostd
```

| Variable | Meaning |
| --- | --- |
| `CNX_BASE_URL` | Backend base URL (required). |
| `CNX_TEAM_ID` | Team whose signaling hub to join (required). |
| `CNX_REFRESH_TOKEN` / `CNX_REFRESH_TOKEN_FILE` | Stack refresh token; hostd mints access tokens at `POST <CNX_STACK_API>/api/v1/auth/sessions/current/refresh` (`x-stack-access-type: client`). Preferred. |
| `CNX_ACCESS_TOKEN` / `CNX_ACCESS_TOKEN_FILE` | A fixed Stack access token instead (expires; for short runs). |
| `CNX_STACK_PROJECT_ID` | Default the dev project `454ecd03-1db2-4050-845e-4ce5b0cd9895`. |
| `CNX_STACK_PUBLISHABLE_KEY` | Optional publishable client key. |
| `CNX_STACK_API` | Default `https://api.stack-auth.com`. |
| `CNX_DEVICE_ID` | Mac device id; default a UUID persisted in `$CNX_STATE_DIR/device-id` (`~/Library/Application Support/cnx-hostd`). `cnx-hostd --print-device-id` prints it. |
| `CNX_DEVICE_NAME` | Default the host name. |
| `CNX_OWNER_USER_ID` | Admitted Stack user; default the access token's `sub`. |
| `CNX_TUI_SOCKET_DIR`, `CNX_TUI_SESSION` | cmux-tui sockets, default `$TMPDIR/cmux-tui-<uid>` and `main`. |
| `CNX_TUI_SOCKET` | The default session's socket when it is not `<dir>/<session>.sock` (the cmux-next app passes its own daemon's socket). |
| `CNX_CONTROL=stdio` | Supervised mode (below): tokens and the acpmux endpoint come from stdin, events go to stdout. |
| `CNX_FILE_ROOTS` | Colon-separated workspace roots for the `file` service. Unset denies every read. |
| `ACPMUX_HOME` | acpmux state dir (default `~/.acpmux`); hostd reads `websocket.listen` and `websocket.token` from its `config.json` at every `acpmux` open. `CNX_ACPMUX_URL` / `CNX_ACPMUX_TOKEN` override. |
| `CNX_INCLUDE_LOOPBACK=1` | Offer loopback candidates (same-host testing). |
| `CNX_LOG` | tracing filter, default `info`. |

Logs go to stderr.

### Supervised by the cmux-next app (`CNX_CONTROL=stdio`)

The cmux-next Mac app bundles cnx-hostd (`Contents/Resources/bin/cnx-hostd`,
built by `scripts/cmux-next/build-cnx-hostd.sh`) and runs it while Settings >
Accounts > iPhone > Allow iPhone Connections is on and an account is signed in
(`CnxHostSupervisor` in `Packages/macOS/CmuxNext/Sources/CmuxNextMobile/CnxHost`).
The app keeps the Stack session; hostd never sees a refresh token.

- stdin, one JSON object per line: `{"type":"token","token":…}` (sent at
  start and whenever hostd asks) and `{"type":"acpmux","url":"ws://127.0.0.1:<port>/","token":…}`.
  End of stdin exits hostd, so it never outlives the app.
- stdout, one JSON event per line: `connecting`, `online {device_id, team_id}`,
  `waiting {reason, retry_in_seconds}`, `need_token` (no token yet, under a
  minute left, or refused), `need_acpmux` (an `acpmux` open failed; hostd
  waits 15 s for a new endpoint and retries once), `phone_up {session_id,
  phone_device_id, transport, path}`, `phone_path {session_id, path}`,
  `phone_down {session_id, reason}`.
- The app sets `CNX_TUI_SOCKET` to its own daemon socket, `CNX_DEVICE_ID` to a
  UUID kept in its Application Support folder, `CNX_DEVICE_NAME` to the
  computer name, `CNX_TEAM_ID` to the selected team or `personal-<userId>`,
  and `CNX_FILE_ROOTS` to the chat roots. The service is the dev Worker
  (`CMUX_NEXT_CNX_API_URL` overrides it in a Debug build).

Startup: refresh the access token, `POST /v1/devices {kind:"mac"}`, open the
signaling socket, answer. On any failure it reconnects with backoff (1 s to
60 s).

Admission: a session starts only from a `webrtc-offer` or `wg-init` whose
backend-stamped `fromUserId` equals the Mac's user. Anything else gets
`bye {reason:"not_admitted"}`.

Services (default deny, `unknown_service` otherwise):

- `echo`: echoes bytes.
- `daemon` `{session?}`: splices to `<socket dir>/<session>.sock`. Every
  phone request line goes through `policy.rs`, a mirror of
  `Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift`
  (command allowlist, creation commands limited to size and placement fields
  so `argv`, `command`, `cwd`, `env` are refused, projections limited to
  `ios-device:<phone deviceId>`). Refusals are answered locally as v12 error
  lines. Responses reach the phone as whole lines.
- `acpmux`: splices to the acpmux loopback WebSocket with its bearer token
  (refused unless the listener is on loopback). One data frame per message.
  acpmux treats this as a remote-origin (`Web`) connection.
- `file` `{path}`: an absolute path, canonicalized (symlinks resolved) and
  required to stay inside a `CNX_FILE_ROOTS` root; streams the regular file,
  then closes with `eof`.

## Transports

- WebRTC: one ordered reliable data channel `cnx-link`, detached and used as
  a byte stream (writes split at 16 KiB). Trickle ICE through signaling; ICE
  servers from `GET /v1/ice`. The path is `turn` when the selected pair uses a
  relay candidate, otherwise `direct`.
- WireGuard: a fresh Curve25519 key pair and UDP socket per session. Each side
  sends its host and STUN-reflexive endpoints in `wg-init` / `wg-resp`. Until
  a UDP datagram from the peer authenticates, every WireGuard datagram goes
  through the backend relay frames and is also sent to each peer endpoint
  (the hole punch). Receiving the peer's UDP proves only one direction, so a
  side goes UDP-only (path `direct`) only after the peer confirms, with the
  `0xff` relay marker, that our UDP reaches it. A refused UDP send, or a
  direct path silent for 25 s while relay datagrams arrive, falls back to
  `relay`. The link is a smoltcp TCP stream to `overlayIP:7420`
  (MTU 1280, keepalive 10 s).

## Test binaries (cnx-hostd)

- `cnx-dial`: dials a Mac and prints one JSON line per transport: connect
  time, path, ping RTT, echo throughput, `daemon` identify.
  `--transport webrtc|wireguard` (repeatable), `--force-relay` (TURN-only
  ICE, or WireGuard relay frames only), `--exclude-cgnat` (never offer or use
  100.64.0.0/10 Tailscale addresses), `--bytes N`, `--daemon`.
- `cnx-stub-tui <dir> [session]`: a stand-in cmux-tui socket that answers
  every line `ok`, for Macs without cmux-tui.
- `cnx-fake-backend <addr>` (`--features fake-backend`): the test fake
  backend (signaling, relay, `/v1/ice` with STUN only, `/v1/devices`);
  bearer tokens are `user:<id>`.

`CNX_EXCLUDE_CGNAT=1` gives cnx-hostd the same Tailscale exclusion.

## Limits (v1)

- One slow channel consumer stalls the whole link (per-channel queues of 1024
  frames, then the reader waits).
- No ICE restart or WireGuard re-dial after a network change; the app redials.
- A backend `error` message during a dial fails every dial in progress on that
  socket (errors carry no session id).
