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
  WireGuard through an in-process TURN server: relay only settles on `turn`,
  and a Mac whose OS refuses UDP to the phone's LAN address settles on the
  phone's relayed address without the path flapping.
- `cnx-link` `link::tests`: a ping overtakes 4 MiB of queued data on a slow
  stream, and the keepalive counts any inbound frame as life. During an
  8 MiB flood on a 1.6 MB/s stream, an input-lane echo and another bulk
  channel's echo return in about 45 ms on the same stream (round robin and
  input priority) and at once on an attached lane; writes are split into
  16 KiB frames; the `open` frame names the lane only for input.
- `cnx-link/tests/loopback.rs` (input lane): over WebRTC and WireGuard an
  input channel rides its own data channel or TCP stream, and with a Mac
  without the lane it rides the main stream and still works.
- `cnx-link` `send_queue::tests`: on a backed-up signaling socket a signal,
  the reachability marker and a keystroke datagram queued behind 2000 bulk
  relay frames leave first, in that order; relay classes stay within their
  byte bounds and keep their newest frames.
- `cnx-link/tests/loopback.rs`: the fake backend keeps one socket per
  device (a reconnect closes the old one with 4000 `replaced`).
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
// LinkHandle also has:
//   func openInputChannel(service: String, argsJson: String) async throws -> ChannelHandle
//   func hasInputLane() -> Bool
func connect(baseUrl: String, token: String, teamId: String, deviceId: String,
             macDeviceId: String, transport: Transport,
             observer: LinkObserver?) async throws -> LinkHandle   // throws CnxError
func connectWithOptions(baseUrl: String, token: String, teamId: String, deviceId: String,
             macDeviceId: String, transport: Transport, options: ConnectOptions,
             observer: LinkObserver?) async throws -> LinkHandle
func cnxVersion() -> String
func prewarm(baseUrl: String, token: String, teamId: String, deviceId: String) async -> [TimingMark]
func resetWarmState() async      // sign-out: close warm sockets, forget cached ICE servers

struct ConnectOptions { var relayOnly: Bool = false }   // ConnectOptions() is a plain dial

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
    func close()                                 // the signaling socket stays warm
    func timings() -> [TimingMark]               // dial steps, ms since connect
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

`connect` reuses the warm signaling socket of `prewarm` or an earlier dial
(same service, team and device), fetches `/v1/ice` in parallel and caches
it for half its TTL (PROTOCOL.md "Connection setup").
`deviceId` is the phone's Keychain UUID; `macDeviceId` comes from
`GET /v1/teams/:teamId/macs`. `connect` fetches `GET /v1/ice` (8 s budget; on
failure it dials with host candidates only), opens the signaling socket and
dials. The observer is called on a library thread.

`relayOnly` is the app's debug "simulate distant network" mode (Settings →
Developer). It skips every direct path. WebRTC uses ICE transport policy
`relay` with the `/v1/ice` TURN servers, so the path is `turn`; with no TURN
server the dial fails at once (`Transport`). WireGuard never sends plain UDP:
with a TURN server it offers only its relayed address and the path is
`turn`; without one it sends no endpoints, ignores the Mac's, and the path
stays `relay` (the backend relay frames). The Mac side needs no change. Device ids must be UUIDs
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
| `CNX_AGENT_TAB_HOST` | The `agent_session.host` this Mac's app records on its own agent tabs (`install:<id>`). hostd sets it on a phone's `new-conversation-tab`. Unset refuses agent tabs from a phone. |
| `CNX_UPLOADS_DIR` | Where `upload` writes a file that has no `cwd`, one folder per link session. Default `$CNX_STATE_DIR/uploads`. |
| `CNX_UPLOAD_MAX_BYTES` | The largest file one `upload` accepts. Default 100 MiB. |
| `ACPMUX_HOME` | acpmux state dir (default `~/.acpmux`); hostd reads `websocket.listen` and `websocket.token` from its `config.json` at every `acpmux` open. `CNX_ACPMUX_URL` / `CNX_ACPMUX_TOKEN` override. |
| `CNX_INCLUDE_LOOPBACK=1` | Offer loopback candidates (same-host testing). |
| `CNX_PUSH=0` | Do not report agent events for push notifications. By default hostd watches acpmux (`_acpmux/watch`) and reports each new question, permission request and finished turn to `POST /v1/devices/:deviceId/notify` with labels only (kind, agent name, folder name, ids; never prompts, output, tool arguments or paths). See `src/notify.rs`. |
| `CNX_LOG` | tracing filter, default `info`. |

Logs go to stderr.

### Supervised by the cmux-next app (`CNX_CONTROL=stdio`)

The cmux-next Mac app bundles cnx-hostd (`Contents/Resources/bin/cnx-hostd`,
built by `scripts/cmux-next/build-cnx-hostd.sh`) and runs it while
`mobile.allowIPhoneConnections` (Settings > Mobile > Allow iPhone Connections,
or cmux.json) is on and an account is signed in
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
  `CNX_FILE_ROOTS` to the chat roots, and `CNX_AGENT_TAB_HOST` to its agent
  tab host (`install:<id>`). The service is the production Worker
  `https://cnx-ios-api.cmux.dev` for production sign-in and the dev Worker for
  development sign-in (`CMUX_NEXT_CNX_API_URL` overrides it in a Debug build).
- A Mac its owner removes (signaling closes with 4002 `removed`) prints
  `{"type":"removed"}` and exits instead of registering again; the app keeps
  it stopped and forgets its device id until the person allows iPhone
  connections again.

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
- `upload` `{name, size, cwd?}`: writes the next `size` bytes to a new file
  and answers `{"path","size"}`. The file goes into
  `<cwd>/.cmux/attachments/phone-<session>/` when `cwd` is a folder of one of
  the daemon's tabs or inside a root, else into `CNX_UPLOADS_DIR/<session>/`.
  It never overwrites. The name is made safe. A refusal is answered
  `{"error","message"}`. See `../SECURITY.md`.

## Transports

- WebRTC: one ordered reliable data channel `cnx-link`, detached and used as
  a byte stream (writes split at 16 KiB). Trickle ICE through signaling; ICE
  servers from `GET /v1/ice`. The path is `turn` when the selected pair uses a
  relay candidate, otherwise `direct`.
- WireGuard: a fresh Curve25519 key pair and UDP socket per session. Each side
  sends its host and STUN-reflexive endpoints in `wg-init` / `wg-resp`; the
  dialer also allocates a TURN relay (the first `turn:` UDP URL of
  `/v1/ice`, 3 s budget, alongside STUN) and adds the relayed address. Until
  the peer confirms a route, every WireGuard datagram goes through the
  backend relay frames and is also sent to each peer endpoint (plain UDP, and
  through TURN to the peer's public endpoints): the hole punch. Receiving the
  peer's datagrams proves only one direction, so a side leaves the relay
  (path `direct`, or `turn` when the route is the TURN allocation) only after
  the peer confirms with the `0xff` relay marker. Plain UDP is preferred over
  TURN while it keeps arriving. An address the OS refuses UDP to is never the
  route again (no flapping between a refused LAN address and TURN). A
  changed route needs a new confirmation. A refused send, or a route silent
  for 14 s, falls back to `relay` (the peer's marker re-confirms the route
  if it still works). The link is a smoltcp TCP stream to `overlayIP:7420`
  (MTU 1280, 256 KiB socket buffers, Nagle off, CUBIC, WireGuard keepalive
  10 s).
- Link keepalive: a ping every 15 s; pings and pongs go ahead of queued
  channel data, and the link closes only after 20 s with no inbound frame
  at all.
- Input lane (PROTOCOL.md "Lanes"): WebRTC opens a second data channel
  `cnx-input`, WireGuard a second TCP stream to `overlayIP:7420`, when both
  sides list `lanes: ["input"]` in signaling. `Link::open_on(service, args,
  Lane::Input)` (FFI `open_input_channel`) puts a channel on it; without a
  lane it rides the main stream at input priority. Each stream's writer
  sends control, then input, then bulk round robin in 16 KiB frames.
  `DialOptions::input_lane = false` (cnx-dial `--no-input-lane`) turns it
  off, as an older peer would.

## Test binaries (cnx-hostd)

- `cnx-dial`: dials a Mac and prints one JSON line per transport: connect
  time, path, ping RTT (min, median, p95, max), echo throughput, the number of
  TURN URLs `/v1/ice` offered, and `daemon` identify.
  `--transport webrtc|wireguard` (repeatable), `--relay-only` (alias
  `--force-relay`: TURN-only ICE, or WireGuard through TURN only),
  `--no-turn` (drop the TURN servers, so WireGuard relay only measures the
  backend relay frames), `--exclude-cgnat` (never offer or use
  100.64.0.0/10 Tailscale addresses), `--bytes N`, `--daemon`.
- `cnx-stub-tui <dir> [session]`: a stand-in cmux-tui socket that answers
  every line `ok`, for Macs without cmux-tui.
- `cnx-fake-backend <addr>` (`--features fake-backend`): the test fake
  backend (signaling, relay, `/v1/ice` with STUN only, `/v1/devices`);
  bearer tokens are `user:<id>`.

`CNX_EXCLUDE_CGNAT=1` gives cnx-hostd the same Tailscale exclusion.

## Limits (v1)

- One slow channel consumer stalls its stream (per-channel queues of 1024
  frames, then the reader waits). Input-lane channels on their own stream
  are not held by a slow bulk consumer.
- No ICE restart or WireGuard re-dial after a network change; the app redials.
- A backend `error` message without a `sessionId` fails every dial in
  progress on that socket; one naming a session fails only that session's
  dial.
