# cmux next: one remote desktop for Mac and Linux (replaces noVNC and websockify)

Status: proposal, 2026-10-20. Author: the Chief subagent "Unified VNC design", at the user's
request: "aziz was working a bunch on vnc stuff for macs, we need to make cohesive design for that
with the linux version, that replace novnc/websockify etc".

This file joins three lines of work that grew apart. It does not reopen what Lawrence already
decided:

- [remote-desktop.md](remote-desktop.md) (lane 17, 2026-10-02): the product rules. Hosts off by
  default, consent, indicator with Stop, agents never control, audit, ownership, settings. These
  still bind.
- `remote-desktop-v2.md` (decided by Lawrence, 2026-10-18; on branch
  [feat-cmux-next-tailnet-media](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next-tailnet-media),
  not yet on feat-cmux-next): media is WebRTC through Aziz's `cmux-screen`, signaling goes over
  the tailnet, and the Cloudflare room and TURN are only the fallback. This replaced decision RD4
  (`cmux.rd/1` as the media protocol).
- Aziz's Mac work (below), which is the code base for v2.

What this file adds: the Linux side under the same host and protocol, the web viewer that
replaces the noVNC page, one tab kind for every remote screen, one admission model for the
tailnet, cmux-wg and the web, a migration plan off TigerVNC + noVNC + websockify, and what
retires.

## 1. What exists today

### 1.1 Aziz's work (Abdulaziz Albahar, 2026-10-12 to 2026-10-20, not on feat-cmux-next)

| Piece | Where | What it does | State |
| --- | --- | --- | --- |
| `CmuxVNC` | `Packages/Shared/CmuxVNC` | Swift RFB 3.8 client: Raw, CopyRect, ZRLE, Tight, Apple's auth for macOS Screen Sharing; loopback demo server; hardened against hostile servers | Tests; [#20179](https://github.com/manaflow-ai/cmux/pull/20179) (open) also puts it in the remote view pane as "VNC compatibility hosts" |
| `CmuxVNCWebRTC` + `cmux-vnc-host` | `Packages/Shared/CmuxVNCWebRTC` | Swift host and viewer: ScreenCaptureKit, NV12 zero copy, hardware H.264 as a WebRTC video track, input on data channels, pairing links, ticket signaling, ICE relay check | Live on fleet minis; latency probes (`MarkerLatencyTests`) |
| `cmux-vnc-signal` | `experiments/cmux-vnc-ios/signal` | Cloudflare Worker room for signaling, mints Cloudflare TURN | Deployed on a personal workers.dev account (v2 section 7: move it) |
| `cmux-screen` | `cmux-screen/` (own Cargo workspace) | Rust host on LiveKit's `libwebrtc` crate: same wire as the Swift host. macOS backend (ScreenCaptureKit, CGEvent) works; `--backend desktop` (libwebrtc's capturer: X11, PipeWire, Windows) builds, untested; Linux and Windows input not written | [#20413](https://github.com/manaflow-ai/cmux/pull/20413) (open) |
| `CmuxScreenKit` | `Packages/Shared/CmuxScreenKit` | The viewer library (`ScreenSession`: connect, reconnect, input, quality, stats) and iOS UI | Branch [feat-cmux-screen-kit](https://github.com/manaflow-ai/cmux/tree/feat-cmux-screen-kit) |
| Mac Screen tabs | `CmuxNextMacScreen` | `cmux://mac-screen` home (paired Macs, Pair a Mac, Share This Mac) and `cmux://mac-screen?mac=<id>` tabs; WebRTC video in `ScreenVideoView`; input through the remote view pane's `RemoteInputSurface`; menu-bar indicator with Disconnect Viewer and Stop Sharing; `tab new-mac-screen` CLI | [#20426](https://github.com/manaflow-ai/cmux/pull/20426) (draft, stacked on screen kit) |
| Device hub | `workers/device-hub`, `CmuxNextDevices`, `docs/device-hub/PROTOCOL.md` | Cloudflare Worker + User DO + Session DO: Stack sign-in, Secure Enclave device keys, signed requests, per-host/viewer permissions (`none/ask/view/full`), sessions, single-use signaling tickets, sealed relay secrets, audit. Replaces pairing links | Branches `feat-cmux-next-device-auth*` (newest commit 2026-10-20, H3 review fixes) |
| iOS demo apps | `experiments/cmux-vnc-ios` | Swift-host app and Rust-host app on `CmuxScreenKit` | Experiments |

Measured by Aziz (cmux-screen README and #20426): connect to picture 0.7 to 2.1 s; glass to glass
under consecutive input, keys at 2/20/50 Hz p50 43/53/40 ms, pointer at 60 Hz p50 63 ms (same Mac);
iOS simulator through the Worker, input to first frame p50 30 ms; viewer CPU 6 to 9 % at 19 to 36 fps.

Known issue (#20426): WebRTC.framework and the Chromium Embedded Framework both define 8 `RTC*`
Objective-C classes. It works, but the clean fix is a WebRTC build with a renamed prefix.

### 1.2 Lawrence's v2 branches (2026-10-18/19, not on feat-cmux-next)

`feat-cmux-next-tailnet-rd`, `-tailnet-media`, `-tailnet-viewer`, `-tailnet-daemon`: `cmux-screen`
imported from #20426 plus `cmux-tailnet` (embedded Tailscale through libtailscale), tailnet
signaling on port 4180 with WhoIs + `Access` before the handshake and a browser-`Origin` refusal,
a TURN-over-TCP relay on tailnet port 4181 for hosts that only have the embedded node, a viewer
signaling endpoint, and a daemon-owned tailnet node in cmux-tui-core. The fleet step
`scripts/ci/cmux-tui-rust-check.sh screen` is already on feat-cmux-next and waits for the
`cmux-screen` directory.

### 1.3 On feat-cmux-next

- **Linux VM desktop** (`web/services/vms/images/devbox`, `desktop.ts`): TigerVNC `Xvnc :1`
  (RFB on loopback 5901, no VNC auth), openbox + tint2, `vncconfig` for the clipboard, and noVNC
  through websockify on 6901. The Mac app opens the noVNC page as a web tab; `desktopWrapper.ts`
  works around WebKit refusing the tokened asset and websocket requests. The private network is
  the only gate (noVNC has no auth of its own).
- **`cmux.rd/1`** (lane 17): `cmux-rd-proto`, `cmux-rd-core` (FEC, packetizer, congestion
  control, input, sessions and access policy), `cmux-rd-engine`, `cmux-rd-host` (Linux X11 host,
  OpenH264 from Cisco by default), `cmux-rd-ffi`, and the `CmuxNextRemoteView` pane (decode,
  Metal/layer presenters, input capture, chrome, state cards). DEBUG only and loopback only,
  because the host trusts the principal claims in `hello` (remote-desktop.md 11.0). v2 replaced
  its media protocol.
- **a302** ("Cloud streamed browser", running): prototypes a cloud browser streamed with
  `cmux-rd` on a Linux VM into the debug `remote_view` pane.

So there are three media stacks (RFB through noVNC, `cmux.rd/1`, WebRTC), two Mac tab kinds
(`cmux://remote-view`, `cmux://mac-screen`), three auth models (private network only, per-launch
token plus trusted claims, pairing secret or device hub tickets), and no Linux input on the
v2 host.

## 2. Decisions

| Id | Decision |
| --- | --- |
| U1 | **One host engine on every OS: `cmux-screen-host`** (Rust, Aziz's code, v2). Backends: macOS (ScreenCaptureKit + CGEvent, done), Linux X11 (capture through libwebrtc's X11 capturer or XDamage + XShm, input through XTest; this file's next slice), Linux Wayland (PipeWire portal + libei, later), Windows (DXGI + SendInput, later). The Swift `cmux-vnc-host` stays a reference and test host only. |
| U2 | **One media protocol: WebRTC** (v2 RD2-2): H.264 (HEVC where both ends decode it) on a video track, input on the ordered data channel, pointer moves on the unordered channel, as `cmux-screen-proto` defines them. RFB is never our host protocol. `cmux.rd/1` media retires (section 7). |
| U3 | **One signaling message set** (`cmux-screen-proto::SignalMessage`) on three carriers, chosen in this order: (1) the tailnet WebSocket on port 4180 (v2 RD2-4) for user devices; (2) the same WebSocket on the machine's private address through the owner's cmux-wg tunnel for Cloud VMs (v2 RD2-6: VMs stay on cmux-wg); (3) a device hub Session DO with a single-use ticket for viewers with no tailnet or tunnel: phones away from home, and every web browser. The Cloudflare room (`cmux-vnc-signal`, pairing links) retires once the device hub ships, because the hub's tickets replace the room secret. |
| U4 | **Admission is one ordered check per carrier, then the same session rules.** Tailnet: Tailscale ACL, tailnet-only listener, WhoIs + `Access` (owner, allow list, deny list), no browser `Origin`. cmux-wg: the VM's private address is reachable only through its owner's tunnel (the gate noVNC has today), plus a per-open ticket the VM service mints at `openPort` (before the switch can default on, M3). Device hub: Stack session + device key + permission scope + single-use ticket. After any carrier: hosting on, consent at the host, indicator with Stop, agents never control, audit (remote-desktop.md 11). The tailnet identity replaces the trusted `hello` claims; that removes the remote-desktop.md 11.0 trust gap for v2 hosts. |
| U5 | **One viewer core per platform, one tab kind.** macOS: the `CmuxNextRemoteView` pane keeps its chrome, input capture, state cards, path badge and settings, and gets a WebRTC stream source (Aziz's `ScreenVideoView`). Mac Screen tabs and VM desktops both become `remote_view` tabs (`cmux://remote-view?host=…&target=display:N&mode=view|control&via=screen`). `cmux://mac-screen` stays as the device list and Share This Mac page. iOS: `CmuxScreenKit`. Web: section 5. RFB (`CmuxVNC`) is a second stream source in the same pane, labeled "compatibility", for Macs that run only macOS Screen Sharing (remote-desktop.md RD9). |
| U6 | **The web viewer is the browser's own WebRTC.** A small page in the cmux web app (`/vm/desktop/[id]` today) opens an `RTCPeerConnection`, signals through the device hub with a ticket, and draws the track in a `<video>` element; input goes on data channels. No noVNC, no websockify, no RFB in the browser. It is view only until consent and input containment exist on the web (remote-desktop.md 1, non-goals). |
| U7 | **Linux VMs run a plain X server and the cmux-screen host as the `desktop` role.** `Xvfb` (or `Xorg` with the dummy driver when a GPU is present) replaces `Xvnc`; openbox, tint2, the session env file, the accessibility bus and computer-use stay. The host attaches to `:1`, so a person can watch an agent's GUI session and take over (remote-desktop.md 4.2). Clipboard moves from `vncconfig` to the host's control channel. |
| U8 | **One default-off switch for the move:** `CMUX_VM_DESKTOP_TRANSPORT` = `novnc` (default) or `screen` (landed with this file, section 9). Clients keep opening port 6901 until the switch defaults on. |

Why WebRTC and not `cmux.rd/1` (Lawrence's call on 2026-10-18, restated so the trade-off stays
visible): `cmux.rd/1` measured lower latency on Linux (marker G2G p50 9.4 ms in a VPC with x264;
remote-desktop.md 15.7) than libwebrtc on macOS (40 to 63 ms). WebRTC wins on what we would have
to build and keep: congestion control, FEC/NACK, hardware encoders on three OSes, NAT traversal and
TURN, and native clients in every browser and on iOS. The cost is about 30 ms of jitter buffer and
pacing. Section 4 sets targets that close part of it.

## 3. Architecture

```
 viewers                                       carriers (signaling)               host (any OS)
 ┌──────────────────────────────┐   tailnet WS :4180 (WhoIs+Access)   ┌────────────────────────────────┐
 │ cmux-next remote_view pane   │◀──────────────────────────────────▶│ cmux-screen-host               │
 │  (WebRTC source | RFB compat)│   cmux-wg tunnel → private :4180    │  signaling listeners (3)       │
 │ iOS CmuxScreenKit            │◀──────────────────────────────────▶│  admission (U4) + consent      │
 │ web page (browser WebRTC)    │   device hub Session DO + ticket    │  libwebrtc: track + channels   │
 └──────────────────────────────┘◀──────────────────────────────────▶│  backends: macOS | X11 |       │
              ▲                                                       │   Wayland | Windows            │
              └──── media: WebRTC (direct ICE, OS tailnet, tailnet    └────────────────────────────────┘
                    TURN-over-TCP :4181, or Cloudflare TURN) ─────────────────────▲
```

- Media paths, best first: a direct LAN pair; the OS tailnet interface (100.x / fd7a:);
  the cmux-wg tunnel to a VM's private address; the host's tailnet TURN-over-TCP relay on 4181
  (v2 RD2-7); Cloudflare TURN (device hub relays, sealed per device). The pane's path badge shows
  `direct`, `tailnet`, `tunnel`, `tailnet relay` or `relayed`.
- Ownership: the session record, consent and grants belong to the host engine; on a hub path the
  User DO mirrors sessions and audit (device hub PROTOCOL.md). Pane view state belongs to the
  client. The `remote_view` tab record belongs to the workspace store.

## 4. Targets

Glass to glass (G2G) by the marker method (remote-desktop.md 15.1), 1920x1080, p50 / p99.

| Path | Host encode | Today | Target | How |
| --- | --- | --- | --- | --- |
| LAN or OS tailnet, Mac host | VideoToolbox | 40 to 63 ms p50 (Aziz, same Mac) | ≤ 35 / ≤ 70 ms | playout delay 0 (`playout-delay` extension), no frame queue in the viewer, present on the next refresh |
| WAN on the tailnet | hardware | not measured | ≤ RTT + 40 ms | as above |
| Cloud VM over cmux-wg, in region | software (OpenH264 / libwebrtc) | noVNC: not measured | ≤ 60 / ≤ 120 ms | baseline noVNC first (M1 bench) |
| Relayed (TURN) | any | 30 ms input to first frame (iOS sim) | ≤ RTT + 50 ms, view only above `remoteDesktop.interactiveMaxRttMs` | relay caps 15 fps, 4 Mbit/s |

| Measure | Target |
| --- | --- |
| Frame rate | 60 fps on LAN with hardware encode; ≥ 30 fps for 1080p text scroll on a 4 vCPU VM; relay cap 15 fps |
| Connect to first frame | ≤ 1.0 s on tailnet and tunnel paths (0.7 to 2.1 s through the room today) |
| Idle | 0 encoded frames and 0 media bytes on a static screen; viewer 0 % CPU (no display link without frames); host ≤ 1 % of a core |
| Viewer CPU | ≤ 10 % of one core at 1080p60 on Apple silicon (6 to 9 % at 19 to 36 fps today) |
| Software encode budget on VMs | ≤ 2 cores per stream (`remoteDesktop.host.maxSoftwareEncodeCores`) |

A CI bench (`cmux-screen` marker test on two fleet hosts, and a Linux VM to fleet Mac row) fails a
change that makes a row more than 20 % worse.

## 5. The web viewer (what replaces the noVNC page)

- Page: `web/app/vm/desktop/[id]`, the same route the noVNC wrapper uses, so the app's link stays.
  It asks the cmux API for a ticket (`POST /api/vm/<id>/desktop/ticket`, Stack session, owner or
  grant only), opens a WebSocket to the device hub Session DO with the ticket, and runs the offer
  and answer with the VM host.
- The VM host keeps one outbound WebSocket to the device hub for its machine (hibernating DO, no
  polling), so a VM needs no public ingress (today's rule stays: no public port).
- Media: ICE gets the hub's Cloudflare TURN for the browser. A browser cannot join cmux-wg or the
  tailnet, so the web path is always TURN unless the browser is on the same network.
- Decode and draw: the browser's own decoder in a `<video>` element; WebRTC's jitter buffer is
  set to minimum (`RTCRtpReceiver.jitterBufferTarget = 0`).
- View only in phase W1. Control on the web needs input containment in a page (no Cmd-W, no
  browser shortcuts), which is phase W2.
- The cmux-next app does not use the web page: its native pane talks to the host on the tunnel or
  tailnet carrier. The web page is for the dashboard and for people without the app.

## 6. Migration plan

| Step | What | Default | Gate to the next step |
| --- | --- | --- | --- |
| M0 | This design. Land Aziz's stack on feat-cmux-next in his order: #20179 (RFB compat) → screen kit → #20426 (Mac Screen) → #20413 (`cmux-screen`) → device hub. Lawrence's v2 branches rebase onto that, not the other way around, so Aziz's PRs do not conflict on `cmux-screen/`. | n/a | Aziz and Lawrence agree on the order (section 10) |
| M1 | **Landed with this file:** `CMUX_VM_DESKTOP_TRANSPORT` (`novnc` default, `screen`). `openPort`, its URLs and the desktop heal follow it. Bench noVNC on a Freestyle VM (marker G2G, fps, CPU) for the baseline row. | `novnc` | Baseline numbers recorded |
| M2 | Linux X11 backend in `cmux-screen-host`: XTest input (keys by USB HID usage → X keycodes, pointer, scroll, text), libwebrtc X11 capture or XDamage + XShm, cursor through XFixes, resize by `xrandr`. Image: `Xvfb :1` beside the session, and the host as the `desktop` role behind the switch; the unit's READY means 4180 is bound. | `novnc` | Fleet and VM tests green; marker bench meets section 4 |
| M3 | The cmux-wg carrier with a per-open ticket (U4); the app opens `remote_view` tabs for VM desktops when the machine reports `desktop.transport = screen`; the a302 cloud browser moves to this host. Web viewer W1 (view only) behind a Cloud flag. | `novnc` | Security review of the ticket and Origin rules; staging soak |
| M4 | Default `screen` for new machines; old images keep noVNC until they are recreated. The CLI's `cloudVMDesktopPort` and `CmuxTuiSnapshotParser.desktopPort` read the machine's reported port instead of the constant 6901. | `screen` | One release with no regressions |
| M5 | Remove TigerVNC, noVNC, websockify, `vncconfig`, `desktopWrapper.ts` and the 5901/6901 contract from the image and the app. Retire `cmux-rd-host` media and the `cmux.rd/1` pane decode path (section 7). | n/a | No machine on an old image |

Mac side, in parallel: Mac Screen tabs become `remote_view` tabs with `via=screen` (M3); Share This
Mac uses the device hub permissions and the remote-desktop.md 11 consent panel; the host moves into
the signed screen agent helper (remote-desktop.md RD10) before Release.

## 7. What retires and what stays

- Retires: TigerVNC `Xvnc`, noVNC, websockify, `vncconfig`, `desktopWrapper.ts` (M5); the
  `cmux-vnc-signal` room and pairing links (after the device hub); `cmux.rd/1` media, FEC and
  congestion control in `cmux-rd-core`, `cmux-rd-host`, the `cmux-rd-ffi` viewer and the pane's
  VideoToolbox decode and presenters (M5).
- Stays: `cmux-rd-core::policy` (grants, consent rules, the agents-never-control rule) until the
  same rules live in `cmux-screen-host`; the `CmuxNextRemoteView` chrome, input capture, keyboard
  policy, state cards and settings; `CmuxVNC` as the compatibility source; `cmux-encode`'s Cisco
  OpenH264 download and verify step (the license rule of remote-desktop.md applies to any software
  H.264 encoder on Linux hosts, including libwebrtc's).

## 8. Security notes

- No host listens on a public or LAN interface. Tailnet listeners bind tailnet addresses only;
  VM listeners bind the private network only (as noVNC does today).
- Browser `Origin` is refused on 4180 (v2 rule) on every carrier, so a web page the owner opens
  cannot reach a host as the owner. The web viewer reaches hosts only through the device hub.
- The `screen` switch must not default on before the cmux-wg ticket (M3): until then the private
  network is the only gate, the same as noVNC, and no better.
- Software H.264: libwebrtc's bundled OpenH264 is built from source. Cisco's patent license covers
  only Cisco's downloaded binary (remote-desktop.md, cmux-rd-host README). Before M2 ships to users,
  the Linux host must load Cisco's binary through `cmux-encode` or use a hardware encoder. This is a
  legal decision for Lawrence (D-RD1).

## 9. The first shared slice (landed with this file)

`web/services/vms/images/desktopTransport.ts`: `resolveDesktopTransport`, `desktopListenPort`,
`desktopEndpoint` and `desktopReadyProbe`. The Freestyle driver reads `CMUX_VM_DESKTOP_TRANSPORT`
once (or takes `desktopTransport` from its dependencies in tests). With `screen`, `openPort(4180)`
heals the desktop unit, probes 4180 and returns `ws://<private address>:4180/` plus a
`cmux://remote-view?…&via=screen` tab URL, and 6901 is an ordinary port. With the default, every
output is the same as before (the existing contract tests still pass unchanged). Tests:
`web/tests/vm-desktop-transport.test.ts` and a case in `web/tests/vm-freestyle-provider.test.ts`,
red first.

## 10. Coordination and open decisions

- **Aziz:** this design builds on his stack and asks for his merge order (M0). Nothing here edits
  his branches.
- **Lawrence (hq session cmuxterm-hq-53, v2 owner):** rebase the tailnet branches onto Aziz's
  landed `cmux-screen` instead of landing a second import.
- **a302 (cloud streamed browser):** build the prototype on `cmux-screen-host --backend desktop`
  on Xvfb, not on `cmux-rd-host`, so it is not thrown away at M5.
- **a183 (Mac VM pause/resume):** a Mac VM desktop uses the macOS backend and the tailnet carrier.
  Pausing a VM must end its sessions with an `ended: host paused` reason, not a silent drop.
- Open: the `RTC*` class conflict between WebRTC.framework and CEF (needs a prefixed WebRTC build);
  Wayland portal consent UX; whether the web viewer may ever control; software H.264 licensing
  (D-RD1).
