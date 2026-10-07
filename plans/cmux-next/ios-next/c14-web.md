# C14 `web`: in-app browser over Mac and SSH tunnels, simulator streaming

Status: lane C14 of [PLAN.md](PLAN.md), 2026-10-06, branch `feat-cmux-next-ios-c14-web` off
`feat-cmux-next-ios`. Binding: OWNERSHIP-PRINCIPLES.md, a0-rpc.md, a3-link.md, b5-mac-host.md (policy,
`MobileChannelHandler`), c2-browser-stream.md (rd video path, `BrowserStreamViewController`), c9-ssh.md
(SSH connections; port forwarding deferred here), remote-localhost.md (the Mac's loopback rules),
transport.md 12a (loopback forwards are bulk streams on the link). Parity: a1-shell.md 1.20 items 5 and 6.

## 1. What the user gets

- Open a Mac's dev server (`http://localhost:5173`) in a native WKWebView on the phone, from the list of
  ports the Mac advertises for its workspaces. The page runs on the phone (scroll, text, zoom are local);
  only TCP bytes cross the link.
- The same browser over an SSH host (C9): `localhost:<port>` as seen from the SSH server, through
  `direct-tcpip`.
- Stream one of the Mac's booted iOS simulators (video plus touch), reusing C2's rd video path and
  screen.

The Mac browser tab streaming of C2 stays the way to see a page that runs on the Mac. C14 is for pages
that should run on the phone (a dev server being tested on a phone-sized viewport).

## 2. Ownership

| Fact | Owner | Phone holds |
| --- | --- | --- |
| Which Mac ports may be forwarded | the Mac (`MobileTunnelPortDirectory`: detected workspace listeners plus the user's Mac-side allowlist) | the last `tunnel.ports` read, for the list only; every open is re-checked on the Mac |
| The TCP connection to `127.0.0.1:<port>` | the Mac's `TcpForwardHandler`, one per channel | nothing |
| SSH connection and its channels | the phone (C9 connection chain), one per SSH route | it is the owner |
| Page runtime, cookies, storage | the phone's WKWebView, one non-persistent data store per route (Mac or SSH host) | it is the owner; nothing syncs |
| Booted simulators, their frames and touch | the Mac (`SimulatorCaptureHost`) | view state only |

Nothing new is stored on the phone across launches: routes, tokens and data stores die with the process
(parity behavior of the shipping app's per-computer route).

## 3. Mac loopback tunnel: `tcp.forward`

### 3.1 Wire (A0 family `tunnel`, stream plane, owner `mac-host`)

- Channel kind `tcp.forward`, class `bulk` (transport.md 12a: loopback forwards ride the bulk class and
  never delay keystrokes). `channel.open.params = {port}`; the phone cannot name a host.
  `channel.opened.params = {port, source}` with `source` `detected` or `allowed`.
- Records: binary payload = raw TCP bytes (`tcp.data`). The `fin` flag on a record means the sender
  will send no more bytes (half close); an empty record with `fin` is a bare EOF. Both directions ended
  -> the host sends `channel.closed` and closes. A socket error -> `channel.closed {code: tunnel.reset}`.
- Read `tunnel.ports` on the `rpc` channel -> `{ports: [{port, source, workspace?, process?}]}`.
- Errors: `tunnel.port_not_allowed`, `tunnel.connect_refused` (retryable), `tunnel.limit` (retryable).
- Flow control is the link's: the host reads the socket only after the previous record went out
  (link credit), and reads the next phone record only after the socket write finished. One stalled side
  holds at most one channel budget (1 MiB) per stream.

### 3.2 Policy (relay rules, skills/cmux-socket-policy)

Default deny. `TcpForwardHandler` admits a channel only when all hold:

1. The session gate is open (paired, unrevoked device; B5).
2. `port` is 1024..65535 (never a privileged port) and not in the configuration's `deniedPorts` (the
   app adds its daemon WebSocket control port and its own listeners).
3. `port` is in the Mac's directory **at open time**: a listener owned by a process of the user's
   workspaces (`DetectedTunnelPorts`: workspace process pids from the app, listening TCP sockets of
   those pids from libproc, wildcard or loopback binds only), or a port the user allowed on the Mac
   (`MobileAllowedPorts`, a Mac setting). The phone's own list is never trusted.
4. Per-device and per-host caps: 32 concurrent streams per install, 128 per host (`tunnel.limit`).
5. The Mac connects only to the literal `127.0.0.1`, then `::1` on refusal, with the connection
   required on the loopback interface. No DNS, no other host, so a buggy or malicious phone cannot reach
   the LAN or another machine. 3 s connect timeout on the injected clock.

Every received record re-checks the gate; a revoked device's streams stop at once (B5 then closes the
channels). Analysis: no command runs anywhere; the only effect on the Mac is a TCP connection from the
app process to a loopback port the user's own workspace serves or the user allowed; the phone reaches no
object it could not already see (dev servers of its own account's Mac, B5 admits only same-account
devices); local-state exposure is limited to what that dev server returns. Ports of other users'
processes are not detected (pids come from the user's workspaces).

### 3.3 Detection

`DetectedTunnelPorts` combines three seams the app fills: `MobileWorkspaceProcesses` (pids of
processes under the user's workspace terminals, with workspace id and name, from the daemon's process
tree), `ListeningPortScanner` (`LibprocListeningPortScanner`: `proc_pidinfo(PROC_PIDLISTFDS)` then
`proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` for TCP sockets in `LISTEN`; macOS only), and
`MobileAllowedPorts`. Results are deduplicated by port, `allowed` wins over `detected` only when no
workspace process listens. The read is evaluated on demand (no scan loop).

## 4. Phone browser: why a loopback proxy

WKWebView cannot use a custom socket. Options considered:

| Mechanism | Verdict |
| --- | --- |
| `WKURLSchemeHandler` | WebKit refuses handlers for `http`/`https`; a custom scheme changes the origin (cookies, CORS, OAuth redirects, absolute `localhost` URLs break) and has no WebSocket, so HMR dies |
| `WKWebsiteDataStore.proxyConfigurations` (SOCKS/HTTP CONNECT on the phone) | Network.framework never sends loopback destinations to a per-store proxy (measured on macOS for remote-localhost.md 7; the shipping iOS app works around it the same way) |
| **Per-port listener on the phone's `127.0.0.1` that forwards over the tunnel** | chosen |

Decision: a `LoopbackProxy` per (route, remote port) bound to `127.0.0.1`. It first tries the same port
number as the Mac (`localhost:5173` on the phone), so the page's origin, absolute URLs, cookies, OAuth
callbacks and dev-server host checks are exactly what they are on the Mac and no rewriting is needed.
If that port is taken on the phone (another route already mirrors it), it binds an ephemeral port and
rewrites the first request's `Host` header to `localhost:<remote port>` (dev servers check it), with
`Connection: close` so every request of that connection is rewritten. Then bytes flow unchanged, so
WebSockets, SSE and large uploads are plain streams.

Other apps on the phone share the loopback interface, so a listener alone would let a background app
reach the Mac's dev server. Each route has a per-launch 256-bit token set as an HttpOnly cookie
(`__cmux_tunnel`, domain `localhost`) in the route's non-persistent data store. The proxy reads the
first request head of every accepted connection, refuses it with `403` unless that cookie matches,
strips the cookie, then tunnels. Requests that send no cookies (`credentials: "omit"`) and HTTPS dev
servers (no readable head) are refused; recorded as a limitation. Listeners exist only while a browser
screen of that route is open, and stop when it closes.

`localhost` resolution: listeners bind `127.0.0.1` and, best effort, `::1` on the same port.

### 4.1 Pieces

- FeatureKit `TunnelStream` / `TunnelDialer` / `SSHDirectTCPIPOpener` (seams, Foundation only).
- `CmuxMobileTunnel` generic SOCKS route: `MobileTunnelSocksBackend` adapts a route's
  `TunnelDialer` to the bounded relay; loopback targets use the paired Mac/SSH path, while
  non-loopback targets are denied unless the composition explicitly supplies a direct backend.
  `WebRoute.startSocks` creates a per-launch RFC 1929 credential and returns a `WebSocksEndpoint`;
  credentials are required before a channel can open and are discarded when the route stops.
- `CmuxiOSWebCore` (no UIKit; tests on macOS): `LinkTunnelDialer` (A0 `tcp.forward` over the per-Mac
  `MobileLinkClient`), `SSHTunnelDialer` (direct-tcpip to `127.0.0.1:<port>` on the SSH server through
  an opener), `LoopbackProxy` + `ProxyRequestHead` (head parse, token, Host rewrite), `WebRoute`
  (token, mirrored ports, proxies by port, ref-counted local port registry shared by routes),
  `LinkWebPortSource` (`tunnel.ports`), `WebAddress` (typed input to a loopback URL).
- `CmuxiOSSSHCore`: `NIOSSHTunnelOpener` (connects the C9 hop chain once, opens direct-tcpip streams,
  reconnects on the next dial after a drop) over the new `SSHConnection.openDirectStream` in
  `CmuxMobileSSH`.
- `CmuxiOSWeb` (UIKit): `WebPortsViewController` (dev servers and simulators of a Mac, enter a port),
  `WebBrowserViewController` (WKWebView, address field, back/forward/reload, navigations to another
  loopback port open that port's proxy first; non-loopback navigations open in the system browser so the
  tunnel store never mixes origins).

## 5. SSH port forwarding

`SSHTunnelDialer(opener:)` maps `dial(port)` to `direct-tcpip` `127.0.0.1:<port>` on the SSH server
(the last hop of the chain). The SSH user already has a shell there, so any port 1..65535 is allowed;
the target host is fixed to loopback. The SSH connection is the phone's (C9 trust and credentials);
`NIOSSHTunnelOpener` reuses one connection chain per route and opens one channel per proxied TCP
connection. The proxy and data store are the same as for a Mac route, keyed by the SSH host id.

## 6. Simulator streaming

- Wire: A0 family `simulator` (stream, owner `mac-simulator-host`): channel kind `simulator`
  (interactive) whose records are exactly the `browser` channel's (`RdStreamFrame`: rb control JSON and rd
  datagrams, optional datagram lane), opened with `{udid, service: "rb/1", screen, codecs?,
  datagram_lane?}`; read `simulator.list` -> `{simulators: [{udid, name, runtime, state}]}`. Errors
  `simulator.not_found`, `simulator.unavailable`.
- Mac: `SimulatorChannelHandler` adapts a `SimulatorCaptureHost` (list booted devices, attach -> video
  source plus touch, button and text injection) to C2's `BrowserPageAttachment` and runs the same
  `BrowserChannelSession`: same encoder, packetizer, lane switch, recovery and bitrate control.
  Navigation is refused (`BrowserNavigationPolicy.none`). Pointer events with `pointer_type: touch` map
  to touch began/moved/ended in device points; `ime_commit` and keys map to text and HID keys. The real
  capture (ScreenCaptureKit on the Simulator window, SimulatorKit HID) is app wiring; listing has a pure
  `SimctlSimulatorList` parser for `xcrun simctl list devices -j` (the app runs the command).
- Phone: `BrowserChannelParams(simulator:)` targets the new kind; `LinkSimulatorStreamSource` (a
  `BrowserStreamSource` whose tabs are the booted simulators) feeds C2's `BrowserStreamViewController`
  in a `device` chrome (no address bar, history or tabs; one-finger pan is a touch drag, not a wheel).

## 7. Tests (Swift Testing)

- `CmuxMobileWireTests`: catalog equality, fixtures for both families, `tcp.data` vector.
- `CmuxMobileHostTests/TunnelPolicyTests`, `TunnelHandlerTests`, `SimulatorChannelTests`: privileged,
  denied, unadvertised and stale ports refused; caps; revocation; bytes both ways over a real loopback
  TCP server; half close; connect refused; libproc scanner finds a listener of this process; simulator
  touch mapping and refusal of navigation.
- `CmuxiOSWebCoreTests` (macOS via a scratch package): head parsing and token, Host rewrite, proxy
  forwarding over a loopback link to a real `MobileHost` with the tunnel handler and a local HTTP
  server, missing token refused, SSH forward through a fake direct-tcpip opener.

## 8. Not in this lane / follow-ups

App wiring of `MobileTunnels` (workspace pids from the daemon, the Mac allowlist setting, denied daemon
port) and of `SimulatorCaptureHost` (ScreenCaptureKit plus SimulatorKit HID) in the cmux-next app; the
phone's per-Mac client provider (D1, same slot as C2 and C4); HTTPS dev servers through the proxy;
a realtime `tunnel:<host>` stream instead of the on-demand read; live verification on a tagged pair.

## 9. Status (2026-10-07)

Done on `feat-cmux-next-ios-c14-web`: wire (both families in catalog JSON, Swift, TS, schemas, fixtures,
`tcp.data` vector), Mac `MobileTunnels` and `MobileSimulators` in CmuxMobileHost, phone
`CmuxiOSWebCore`, `CmuxiOSWeb`, `LinkSimulatorStreamSource`, the device chrome of C2's screen,
`SSHConnection.openDirectStream` and `NIOSSHTunnelOpener`, and a Browser swipe action on paired Macs and
SSH hosts in the Hosts tab (`SSHFeature.browsers`, wired in `ShellComposition`).

Verified: CmuxMobileWire 22 tests, vitest `mobile-wire` + `catalog` 56 tests, CmuxMobileHost 110 tests
(14 new: policy, libproc, tcp.forward over a real loopback echo server incl. 600 KB under 16 KiB credit,
caps, refusals, revocation, simulator touches, navigation refusal, simctl parsing), CmuxiOSWebCore 10
tests on macOS through a scratch package (head parsing, token, Host rewrite, mirror and fallback ports,
real `MobileHost` tunnel to a local HTTP server, SSH forward through a fake opener). The CmuxiOS package
(CmuxiOSApp and every target) compiles for `arm64-apple-ios17.0-simulator` with SwiftPM.

Unverified: everything visual and every live path (WKWebView through the proxy, cookie delivery for
`localhost` in a non-persistent store, ATS for `http://localhost` in the app target, SSH direct-tcpip
against a real server, simulator capture and HID on the Mac). No tagged build (no Mac app build, disk).
Mac routes and simulator streams use D1's per-Mac clients (`AppContainer.webClients` over
`AccountLinkDirectory`, the provider C2 and C4 use), available once pairing is configured.

Follow-up on 2026-10-07: direct-address hosts now have an explicit browser screen seam and route through
the same authenticated `tcp.forward` browser path as paired Macs. Saved Tailscale, LAN, and WireGuard
endpoints no longer stop at the Hosts action. `*.localhost` navigation uses the same loopback predicate
as address parsing, so a tunneled subframe is not misclassified as an external link. Focused address and
navigation tests, Swift syntax parsing, package-convention lint, and diff checks pass in
`864c3eddbf`; live direct-host and WKWebView verification remains pending.

Follow-up on 2026-10-07: the generic SOCKS parity seam is now wired into `WebRoute`. `CmuxMobileTunnel`
  is a direct `CmuxiOSWebCore` dependency; the route starts a credentialed SOCKS5 listener, maps
  loopback destinations through its existing `TunnelDialer`, rejects non-loopback destinations by
  default, and accepts an explicit direct backend for Tailscale/LAN/WireGuard routing. Package tests
  cover RFC 1929 success and refusal, backend failures, caps, half-close and bounded relay behavior;
  `ProxyForwardingTests.genericSocksRouteUsesCredentialsAndKeepsNonLoopbackDefaultDeny` covers the
  route adapter and a byte-for-byte SOCKS exchange. Manifest validation, Swift syntax parsing and
  `git diff --check` pass. Tagged WKWebView/SOCKS and live reconnect verification remain pending.

Follow-up lifecycle hardening on 2026-10-07: `SocksProxyLifecycle` now tracks accepted handshake
channels, rejects children after stop, closes handshakes during route shutdown, and checks the stop
token before and after backend connect and before adapter installation. A regression proves a
pre-stop client cannot open a backend after shutdown. Swift 6 library build and the focused lifecycle
test pass; the full test target remains blocked by the local TestingMacros plugin environment.
