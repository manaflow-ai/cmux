# cmux next: remote localhost for browser tabs

User request (2026-09-30): "chrome tabs need to be able to directly access
localhost from the workspace cmux tui computer associated with it (tab badge
to indicate), kinda like ssh tunnel thing ... implemented in secure way ...
incrementally adoptable way for cmux tui."

Status (2026-09-30): stages 1 to 3 are built; stage 4 (WebKit) is not. Section
9 lists what is verified and what is not.

## 1. Which machine a tab uses

A browser tab's **machine** is the session (data-model.md 1.1) whose
localhost the tab sees:

- the tab's workspace's home session;
- in a mixed workspace, a tab that references another session uses that
  session (today only remote-terminal tabs reference other sessions, so a
  browser tab uses the home session).

The machine is identified by the daemon's `registry_id` (`DaemonStore.registryID`),
never by the Cloud machine id: a Cloud VM can be re-provisioned, and SSH
sessions have no Cloud id. When the machine is this Mac (the home session of
this app), nothing changes: localhost is this Mac.

A page cannot choose its machine. The App decides it from daemon state when it
creates the engine tab; no URL, header, or script can change it.

## 2. Which destinations go to the machine

Only loopback destinations, decided from the literal host with no DNS:

| Host | Goes to |
| --- | --- |
| `localhost`, `localhost.`, `*.localhost` | the machine (`localhost` tries 127.0.0.1, then ::1) |
| `127.0.0.0/8`, `::1`, `[::1]`, `::ffff:127.x.y.z` | the machine |
| everything else (public names, private LAN IPs, `127.0.0.1.nip.io`) | direct from this Mac |

Why literal names only: a DNS answer is controlled by whoever owns the name, so
routing by resolved address would let a public name (DNS rebinding) reach the
remote machine's loopback. The daemon applies the same rule again and refuses
anything else (section 4).

A second rule protects this Mac: in a remote-localhost tab, a public name that
resolves to this Mac's loopback (for example `127.0.0.1.nip.io`) is refused.
Such a page would otherwise reach this Mac's local services from a page served
by the remote machine. The in-process proxy (section 5) connects direct
destinations itself and refuses a connection whose peer is a loopback or
unspecified address.

## 3. Storage

The browser profile stays the only storage key (data-model.md 5), with one
exception. A tab whose machine is remote and whose main-frame URL is a loopback
origin uses a **derived store**: browser profile x machine `registry_id`.

- Chromium: a separate request context in `Profile-<profile uuid>-m-<16 hex of
  sha256(registry_id)>` (a direct child of the Chromium root, which Chrome style
  requires), with the proxy configuration of section 5.
- WebKit: `WKWebsiteDataStore(forIdentifier:)` with a UUID derived from the same
  pair (stage 4).

So `localhost:3000` cookies, localStorage and service workers of build-box
never mix with those of this Mac or of another machine, and a github.com login
stays shared by every tab of the profile.

A navigation that crosses the boundary (a typed URL or a link from
`localhost:5173` to github.com, or the reverse in a remote workspace) cannot
stay in the same engine tab, because an engine tab has one store. The shim
cancels such a main-frame navigation (`cmux_shim_set_navigation_guard`) and the
App re-creates the engine tab in the other store with the target URL. Back and
forward history does not cross the boundary. Subresources do not switch: a
localhost page's requests to public hosts go direct (through the guard of
section 2), and a public page's requests to localhost in a remote workspace are
refused rather than sent to this Mac.

## 4. Transport: `loopback-forward-v1` (cmux-tui, stage 1, landed)

The existing authenticated control connection gains multiplexed TCP streams
(spec: `cmux-tui/spec/commands.md` "Loopback forwarding"). It rides every
transport the app already uses (local socket, SSH stdio, the Cloud link), so
there is no new listening socket on the remote, no new credential, and no SSH
port forward.

- **Off unless asked.** Advertised in `identify`; a connection gets it only
  after a Unix client echoes it in `set-client-info` (WebSocket clients never
  do). `server.loopback_forward` in cmux-tui.json is `true`, `false`, or
  `{enabled, allow_ports, deny_ports}`; deny wins, an invalid value turns it
  off, and the daemon's own WebSocket control port is always denied.
- **Loopback only.** The daemon classifies the host with the rule of section 2,
  never resolves DNS, and checks the connected peer again, so a buggy or
  malicious client cannot reach another host.
- **Streams.** `loopback-open {stream, host, port, window}` then base64
  `loopback-data`, `loopback-credit`, `loopback-shutdown` (half close),
  `loopback-close`; events `loopback-data`, `loopback-credit`, `loopback-eof`,
  `loopback-closed {error?}`. Data, EOF and close of one stream stay ordered.
- **Flow control.** Credit windows in both directions: the daemon reads the
  target only while the client granted credit, the client sends at most the
  daemon's 256 KiB window before credit returns, and a client that exceeds it
  loses the stream. At most two frames per stream wait in the daemon's writer.
- **Limits.** 128 streams per connection, 512 per daemon, 64 KiB frames, 3 s
  connect timeout. Forwarded bytes skip the surface-operation queue and its
  budget.
- **Audit.** `loopback-status` returns the last 256 finished or refused
  connections; the daemon logs one line per record.
- **Cloud lanes.** Every `loopback-*` line uses the bulk lane in both
  directions (`cmux-remote/src/mux_lanes.rs`), so forwarded bytes stay in order
  and never queue ahead of keystrokes.

Why not the existing protocol-5 `tcp-tunnel` routes: they exist only inside a
`cmux-tui remote` secure session. The app reaches Cloud machines through the
link's local v12 socket and local daemons through the plain Unix socket, so a
v12 channel is the one path every session already has. Base64 in JSON costs
about 35 % on the wire; the carrier (Unix socket or the Cloud link) is not the
bottleneck for dev-server traffic.

## 5. App transport (stage 2)

Chromium's network service runs in a helper process, so bytes must leave it
through a proxy. Chromium has no Unix-socket proxy on macOS, so the proxy is a
**127.0.0.1 listener on a random port inside the app process**, with a
**per-launch secret**:

- One listener; each derived store gets its own random user name (the route to
  one machine) and the launch secret as password. The shim answers Chromium's
  proxy authentication (`GetAuthCredentials`, `isProxy`) with them, only for
  the app's own proxy host and port. Other local users and processes get
  `407`. A page cannot set `Proxy-Authorization` (a forbidden header).
- The derived request context sets `proxy = {mode: fixed_servers, server:
  http://127.0.0.1:<port>, bypass_list: "<-loopback>"}`, so Chromium sends
  loopback destinations to the proxy too (it bypasses them by default) and
  every other destination as well, which is what lets the proxy apply the
  section 2 guard. QUIC is off for proxied traffic.
- The proxy handles `CONNECT` (HTTPS, WebSocket, HTTP/2 over TLS) as a byte
  tunnel and absolute-form HTTP/1.1 (plain `http://localhost` pages) by
  rewriting the request line to origin form with `Connection: close`, then a
  byte tunnel. WebSockets, SSE, Vite and Next HMR, and large uploads are plain
  byte streams to it. Many parallel connections are many streams.
- Loopback targets open a `loopback-forward-v1` stream on a dedicated daemon
  connection per machine (`LoopbackForwardClient`), so forwarded bytes never
  delay terminal traffic on the control connection.
- A dropped daemon connection fails every open stream: the browser connection
  closes and new requests get a `502` page that names the machine and the
  reason. There is never a fallback to this Mac's localhost. The next request
  reconnects.

A CEF fork hook (a network interceptor or a custom URLLoaderFactory for these
hosts) would remove the listener. It is not needed for correctness with the
secret and the guard, costs a fork patch per Chromium upgrade, and is recorded
as a follow-up for the fork owner.

## 6. UI (stage 3)

- A tab whose machine is remote shows the machine name as a subtle gray chip
  in the tab strip and in the omnibar, only while the page is a loopback
  origin. The chip tooltip says "localhost is build-box".
- When the machine's daemon lacks `loopback-forward-v1`, the chip says
  "localhost = this Mac" and the tooltip asks to update that machine
  (`DaemonService.missingCapabilityMessage`). Nothing else changes.
- Settings in cmux.json: `browser.remoteLocalhost` (`true` by default; `false`
  turns the feature off everywhere, and localhost is this Mac again, shown by
  the chip) and `browser.remoteLocalhostWorkspaces` (per-workspace override by
  qualified workspace key, `true` or `false`). The override moves to personal
  state later (data-model.md, owned by the profiles work).

## 7. WebKit (stage 4)

macOS 14 added `WKWebsiteDataStore.proxyConfigurations`
(`Network.ProxyConfiguration`, HTTP CONNECT relay with credentials). A WebKit
tab can use the same proxy: CONNECT for every destination, the derived data
store, and `decidePolicyFor` for the store boundary. Until that is built,
WebKit tabs whose machine is remote show "localhost = this Mac (WebKit)" and
never pretend otherwise.

## 8. Security analysis (relay rules, skills/cmux-socket-policy)

The direction is app to daemon: the app opens streams on a daemon it already
controls. The remote side can never open a stream toward this Mac.

- **Local command or content execution.** No command runs anywhere. The daemon
  only connects TCP sockets to its own loopback. On this Mac the only effect is
  that a browser page renders bytes served by the remote machine's loopback, in
  a store isolated per machine; it cannot reach this Mac's loopback (section 2
  guard) or this Mac's cookies for other machines.
- **Access to unowned objects.** Streams are connection-scoped: a stream id is
  looked up per (connection, stream) and ends with the connection. A client
  already holds full daemon authority (remote-daemon.md, authority boundary),
  and forwarding adds no new authority on the daemon, but it stays off until
  the client opts in and can be turned off per machine.
- **Local-state exposure.** The remote learns only what a browser sends to a
  localhost origin in the derived store: no cookies of other stores, no app
  state, no proxy secret (the proxy strips `Proxy-Authorization`). The proxy
  secret never leaves the app process and the CEF network helper.
- **Buggy client.** The daemon refuses non-loopback targets, DNS names other
  than `localhost`, denied ports, oversized frames and window violations,
  whatever the client sends.
- **Malicious page.** It cannot choose the machine (section 1), cannot set proxy
  credentials, cannot use DNS rebinding to reach either loopback, and cannot
  read another machine's localhost storage.
- **Tabs of different machines** use different stores and different proxy
  routes; a route user name maps to exactly one machine.

## 9. Code, verification and open items

| Piece | Where |
| --- | --- |
| Daemon channel | `cmux-tui/crates/cmux-tui-core/src/server/loopback_forward.rs` (+ `_tests.rs`), lanes in `cmux-remote/src/mux_lanes.rs`, config in `cmux-tui/src/config.rs` |
| Daemon client | `CmuxNextDaemon/Loopback/` (`LoopbackForwardClient`, `LoopbackStream`) |
| Proxy | `CmuxNextRemoteLocalhost` (`RemoteLocalhostProxy`, `ProxyConnection`, `LoopbackHost`) |
| Chromium | shim `CEFShim/src/shim_proxy.mm` (context proxy, `GetAuthCredentials`, navigation guard), `BrowserMachineStore`, `CEFProfileStorage.cachePath(for:machineKey:)` |
| App | `CmuxNextApp/RemoteLocalhost/` (route, store plan, badges), `TabContentCache.reroute` |
| Settings | `browser.remoteLocalhost`, `browser.remoteLocalhostWorkspaces` (`CmuxNextSettings/RemoteLocalhostSetting.swift`) |

Verification harness: `RemoteLocalhostLiveTests` (skipped unless
`CMUX_RL_LIVE_SOCKET` names a cmux-tui socket) runs a node script through the
proxy: HTTP, SSE, WebSocket over CONNECT, 4 MiB down, 8 MiB up, 48 parallel
requests, refused ports, the rebinding guard, and a daemon restart in the
middle of an open stream. DEBUG builds accept
`CMUX_NEXT_REMOTE_LOCALHOST_DEBUG_SOCKET=<cmux-tui socket>`: tabs of this Mac
then use that daemon's machine, so the Chromium path can be checked with a
second daemon without a Cloud machine.

Open items:
- The first request of a new derived store: the shim sets the proxy
  preference in `OnRequestContextInitialized`, before CEF creates the store's
  first browser. If Chromium ever created the network context before that, the
  first request could go direct; the navigation guard does not cover it. A fork
  hook (proxy config at context creation) would close this for certain.
- Proxy authentication without a browser (a service worker's first request
  before any page authenticated) gets no credentials from `GetAuthCredentials`.
  Chromium reuses the credentials a page already answered for the same store.
- WebKit (section 7).
- Deleting a browser profile must also delete its derived stores.
- Cloud machines get `loopback-forward-v1` only after their image's cmux-tui is
  upgraded (plans/cmux-next/cloud-ios.md, remote compatibility).
- A palette action and CLI verb for the per-workspace override are not built;
  cmux.json is the only switch.
