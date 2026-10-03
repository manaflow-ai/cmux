# cmux-next iOS over WebRTC (from-scratch app, full capability parity)

Status: in progress, 2026-10-02. Branch `feat-cmux-next-ios-rtc` (base `feat-cmux-next`). Owner: Aziz.
Independent of lane 14 (`ios/CmuxiOS`, CmuxHomeCore/CmuxHomeRender): no code from it is read or
reused. Decisions taken by Aziz on 2026-10-02: base is feat-cmux-next; every Mac link is WebRTC,
with Cloudflare STUN/TURN. This differs from transport.md (WireGuard overlay) and remote-desktop.md
RD4 (no WebRTC); that conflict is for the coordinator, and nothing here changes lane 12 code.

## 1. Goal and rules

- A new iOS app, written from scratch, that loses no *capability* of the shipping app (origin/main).
  A capability is a thing a user can do; UX and technical design are free. The inventory with
  source proof is `ios-rtc-capabilities.md` (156 entries); section 9 is the parity checklist.
- The only thing kept whole is the login screen (`SignInView` and its helpers, copied from
  origin/main `CmuxMobileShellUI`, plus the auth composition from `cmuxFeature`).
- Delete aggressively: this branch removes `ios/CmuxiOS` and repoints the `cmux-ios` scheme.

## 2. Topology

```
iPhone (cmux.app, CmuxRTCApp)                       Mac (cmux-next, CmuxNextRTC)
  Stack sign-in ─┐                                 ┌─ Stack sign-in (CloudAuth)
                 ├─ wss /v1/wire/user  rtc.* ──────┤   (UserDO relays signaling, same user only)
                 ├─ GET /v1/rtc/ice-servers         │
  RTCPeerConnection (offerer, polite) ═══ DTLS/SCTP/SRTP via host|srflx|Cloudflare TURN ═══ RTCPeerConnection (answerer)
     data channel "daemon"  ── JSON lines v12 ──────────► DaemonLanePolicy ► cmux-tui Unix socket
     data channel "host"    ── JSON lines host RPC ─────► CmuxNextRTC host services (files, git, ...)
     data channel "bulk:<id>"  ── raw bytes ────────────► uploads / file fetch
     video track "view:<id>" ◄──────────────────────────── ScreenCaptureKit (browser tab, Simulator)
```

The phone is a cmux-tui v12 client: workspaces, tabs, terminals, notifications, browser tab
records and topology all come from the daemon through the existing `DaemonLanePolicy` allowlist.
Everything the daemon does not own (files, git changes, directory search, keep-awake, uploads,
video views, push keys) is a small host RPC served by the Mac app.

## 3. Shared package `Packages/Shared/CmuxRTC` (iOS 17, macOS 14)

- `CmuxRTCSignal` (Foundation only): frame types, `SignalingClient` (one `URLSessionWebSocketTask`
  to `/v1/wire/user`, subprotocols `cmux.wire.v1, bearer.<token>`; reconnect with capped
  exponential backoff, 30 s ceiling), `IceServerClient`.
- `CmuxRTCLink` (stasel/WebRTC 154.0.0, BSD): `RTCLinkPeer` (one peer connection, perfect
  negotiation: phone polite, Mac impolite; trickle ICE; `restartIce` on network change),
  `RTCByteChannel` (an ordered reliable data channel as a byte stream: 16 KiB messages, sender
  pauses above 1 MiB buffered and resumes on `didChangeBufferedAmount`, async reads, close
  propagates), `RTCLineChannel` (JSON lines on a byte channel, 64 MiB line cap).
- Tests: two in-process peers wired by an in-memory signaling pair exchange 32 MiB in both
  directions, interleaved small writes stay ordered, close tears down both ends.

## 4. Signaling and TURN (backend, landed in 91d153e4a5b)

Frames on the user's `/v1/wire/user` socket, never committed:

| Frame | Direction | Fields |
| --- | --- | --- |
| `rtc.hello` | both | `role` host/client, `peer` (stable id), `name`, `tag`, `platform`, `app_version` |
| `rtc.welcome` | server | `peer` |
| `rtc.hosts` | client asks / server pushes | `hosts[]` {peer, name, tag, platform, app_version, since} |
| `rtc.signal` | both | `to`, `session`, `kind` offer/answer/candidate/bye, `sdp`, `candidate`, `sdp_mid`, `sdp_mline_index`; relay adds `from`, `from_role` |
| `rtc.error` | server | `code` (`rtc.peer_offline`, `rtc.no_hello`, `rtc.too_large`, `validation.invalid`) |

The relay stamps `from` from the socket, forwards only between roles and only inside one user.
SDP carries the DTLS fingerprints, so the authenticated signaling path binds the media session to
the two signed-in installs (the standard WebRTC trust model). `GET /v1/rtc/ice-servers` returns
`{ice_servers, ttl, turn}` minted from Cloudflare Realtime TURN (`CF_TURN_KEY_ID`,
`CF_TURN_API_TOKEN`), STUN only when unset. Build isolation: a DEV phone shows only hosts whose
`tag` equals its own unless granted (capability 2.22); release tags see release hosts.

## 5. Mac module `CmuxNextRTC` (Packages/macOS/CmuxNext)

- `RTCHostService`: starts after Cloud sign-in, stops on sign-out/user change (same contract as
  `MobileHostService`). Peer id `host-<uuid>` persisted per tag in Application Support. Holds
  the signaling socket, answers offers, one `RTCLinkPeer` per phone session.
- Channel `daemon` → `UnixSocketLane` + `DaemonLaneSplice` + `DaemonLanePolicy(deviceID: <phone peer>)`
  from CmuxNextMobile (existing security boundary, unchanged).
- Channel `host` → `RTCHostRPC` (section 6).
- Video views: `RTCViewCapture` captures one window (or a window region) with ScreenCaptureKit
  into an `RTCVideoSource`; input comes back as host RPC (`view.pointer`, `view.key`, `view.text`).
- Debug socket verbs for dogfood: `debug.rtc.status`, `debug.rtc.peers`.

## 6. Host RPC (`host` channel)

JSON lines. Request `{"id":n,"method":"…","params":{…}}`, reply `{"id":n,"ok":true,"result":…}` or
`{"id":n,"ok":false,"error":{"code","message"}}`, event `{"event":"…","payload":{…}}`.

| Method | Purpose (capability ids from section 9) |
| --- | --- |
| `host.info` | name, app version, tag, daemon socket ok, capabilities[] |
| `fs.stat` / `fs.list` / `fs.read` (offset, length ≤ 1 MiB) / `fs.thumbnail` | file paths in terminals, folder browse, artifact viewer (6.x) |
| `fs.scan` {surface} | files referenced or created in a terminal (6.2) |
| `git.summary` / `git.files` / `git.diff` / `git.blob` {cwd} | Changes (7.x) |
| `dir.search` / `dir.list` | task composer directory picker (11.4) |
| `upload.begin` / `upload.chunk` / `upload.finish` → Mac path | attachments, image paste (5.10-5.12, 11.5) |
| `keepawake.get` / `keepawake.set` + event `keepawake.changed` | caffeinate (14.1) |
| `models.list` | task composer model list (11.3) |
| `view.list` / `view.start` {kind browser/simulator, id} / `view.stop` / `view.pointer` / `view.scroll` / `view.key` / `view.text` / `view.button` | streamed browser and Simulator (8.x, 9.x) |
| `push.register` {apns token, env} / `push.unregister` / `push.test` | push alerts from this Mac (10.8-10.15) |
| `feedback.submit` | privileged feedback (17.2) |

## 7. iOS app `ios/CmuxRTCApp` (SwiftPM package; `cmux-ios` scheme links product `CmuxRTCApp`)

| Module | Owns |
| --- | --- |
| `RTCAppAuth` | the kept login screen + `AuthComposition` (Stack config, Keychain token store, DEBUG auto sign-in) |
| `RTCAppCore` | `MacConnection` (signaling → peer → channels, reconnect on foreground/network), `DaemonClient` (v12 over a line channel), `HostClient`, `@Observable` stores (hosts, workspace tree, notifications), settings |
| `RTCAppTerminal` | GhosttyKit iOS surface in manual-mirror mode fed by `attach-surface` bytes, input (keyboard, hardware keys, accessory bar, composer, dictation, attachments), sizing |
| `RTCAppViewer` | file viewer (text/code/markdown/image/pdf/media), Changes, video view player |
| `RTCAppUI` | screens: Computers, Workspaces, Workspace detail, Feed, Task composer, SSH, Settings, onboarding |
| `RTCAppSSH` | direct SSH computers (swift-nio-ssh), SFTP |

## 8. Build, test, dogfood

- Backend: `cd backend && bun run typecheck && bun run lint:size`, `cd apps/api && bunx vitest run test/rtc.test.ts`.
- Shared/Mac Swift: `swift build --build-tests` and `swift test --filter` in the package (local is
  allowed; never `xcodebuild` locally).
- iOS: fleet only, `cmux-ci build ios --ref <sha> --tag <tag>`; Mac: `cmux-ci build cmux --ref <sha> --tag <tag>`.
- Dogfood: same tag on Mac and phone; both signed into the same account; phone reaches the Mac
  through the staging backend or a PR preview Worker (override `CMUXRTCAPIBaseURL`).

## 9. Parity checklist

Status per capability area of `ios-rtc-capabilities.md`: `todo`, `wip`, `done` (built + verified),
`n/a` (capability does not exist on the cmux-next Mac and has no user-visible equivalent; must be
justified). Updated as work lands.

| Area | Status | Notes |
| --- | --- | --- |
| 1 Account and authentication | todo | login kept whole; sign out, delete account, team switch, erase data |
| 2 Computers, discovery, connection | todo | discovery = `rtc.hosts`; QR/manual pairing replaced by same-account discovery (capability: connect to your Mac) |
| 3 Workspaces | todo | daemon v12 topology commands |
| 4 Terminal output and sizing | todo | |
| 5 Terminal input | todo | |
| 6 Files and artifact viewer | todo | host RPC fs.* |
| 7 Git changes | todo | host RPC git.* |
| 8 Browser | todo | video view + loopback forwarding |
| 9 Simulator streaming | todo | video view |
| 10 Feed, notifications, push | todo | daemon notifications + FeedDO |
| 11 Task composer | todo | |
| 12 Direct SSH | todo | |
| 13 Cloud VMs, billing, VPN | todo | |
| 14 Keep-awake | todo | |
| 15 Onboarding, What's New | todo | |
| 16 Settings | todo | |
| 17 Feedback, diagnostics | todo | |
| 18 Localization, accessibility | todo | |
