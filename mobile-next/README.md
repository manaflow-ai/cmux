# cmux-next mobile (native)

A native iOS client for cmux-next, the Mac host it talks to, and the backend
that introduces them. The phone reaches a Mac directly over WebRTC, or through
Cloudflare TURN when it has to; the backend never sees terminal or agent data.

| Path | What |
| --- | --- |
| `ios/` | The iOS app (SwiftUI, XcodeGen project `ios/project.yml`, bundle `dev.cmux.next.native`). |
| `Packages/CNMKit/` | Shared Swift: wire protocol, transport-agnostic peer layer, WebRTC transport, the Mac host, the `cnm-host` CLI and the `cmux Host` menu bar app. |
| `backend/` | Cloudflare Worker on PlanetScale MySQL: accounts, pairing, signaling, TURN credentials. See [backend/README.md](backend/README.md). |
| `docs/` | [API](docs/API.md), [status](docs/STATUS.md), reference specs and verification notes. |
| `scripts/` | Build, sign and recorded-test scripts. |
| `tools/` | Animation tracking and the iMessage capture project. |

## How it fits together

```
iPhone app ──HTTPS──▶ Worker (/v1/auth, /v1/hosts, /v1/pairing, /v1/ice)
     │  └──WebSocket──▶ SignalRoom (one Durable Object per user) ◀──WebSocket── Mac host
     └────────────── WebRTC data channels (direct or TURN) ─────────────────────┘
```

- **Transport-agnostic.** `CNMTransport.PeerLink` is a connection with two
  ordered lanes: `control` (JSON-RPC-shaped `Envelope`s) and `bulk` (binary
  terminal frames). `RPCPeer`, the host services and the app only see lanes.
  WebRTC (`CNMWebRTC`) is the first implementation; `LoopbackLink` is used in
  tests. Large control messages are fragmented by the transport.
- **Host services** (`CNMHost`): PTY terminals with replay history, ACP agents
  (Claude Code via `claude-agent-acp`, Codex via `codex-acp`, others) with a
  persisted event log and `session/load` resume, and Chief conversations backed
  by a Claude ACP session.
- **iOS app**: Apple sign-in, a ChatGPT-style drawer, a Messages-style Home for
  Chief, AI-app-style agent chats, and Ghostty terminals (libghostty in MANUAL
  IO mode, fed by the Mac's PTY bytes).

## Running the Mac host

Menu bar app: open `cmux Host.app`. On first launch a window shows a pairing
code. On the phone, open the menu → Macs → Add a Mac and enter it, then click
**Pair** on the Mac to approve that account. Nothing is paired without that
approval.

CLI (same runtime):

```bash
cnm-host serve                 # pair (asks y/N to approve), then accept phones
cnm-host pair | status | unpair
cnm-host serve --relay-only    # force TURN, for testing the relay path
```

State lives in `~/Library/Application Support/cmux-next-mobile-host/`
(identity, agent logs, Chief conversations). A paired account can open shells
and run agents as the Mac's user; that is the trust model.

## Building

Builds run on a build mini, never on this laptop. `scripts/remote.sh <cmd>`
rsyncs `mobile-next/` (and the shared packages it uses) to
`mini-cmux8s-mac-mini:~/cnm/src` (override with `CNM_HOST`) and runs `<cmd>`
there.

```bash
./scripts/remote.sh scripts/build-ios-sim.sh        # simulator app
./scripts/remote.sh scripts/build-ios-device.sh     # unsigned device app
./scripts/sign-ios.sh ~/cnm-builds/latest           # sign locally (team identity + profile)
./scripts/remote.sh scripts/build-host-app.sh       # cmux Host.app + cnm-host
./scripts/remote.sh 'cd Packages/CNMKit && swift test'
```

Signing material never leaves this Mac: the device app is built unsigned on
the mini and signed here with the development profile in `~/cnm-signing/`.

## Recorded UI tests

`scripts/sim-flow.sh <sim> <out-dir> <Test>...` builds once, then runs each
`FlowTests` method on an isolated simulator while recording the screen; the
mp4 and named screenshots land in `<out-dir>`. The tests run against the live
backend and a real, distant Mac host (test account; see `docs/STATUS.md`).

```bash
CNM_TEST_EMAIL=... CNM_TEST_CODE=... ./scripts/remote.sh \
  "scripts/sim-flow.sh cnm-app-1 ~/cnm/runs/rN testChiefConversation testTerminal"
```

Flows: welcome, sign-up and pairing, Chief conversation, Messages parity
(send, tapback, timestamps, swipes), drawer and its animation, agent chat
(approvals with diffs, photos, slash commands, modes, Plan mode, Stop, Codex),
terminals (rotation, pinch zoom), relay-only connection, two Macs, host restart
recovery (terminal and agent resume), background/resume, search, settings and
sign-out. `testReconnectAfterHostRestart` and `testAgentResumeAfterHostRestart`
expect the host to be restarted from outside mid-test.

Animation checks: `tools/anim/track_marker.py` and `track_bubble.py` read the
recordings frame by frame; results are in
[docs/ANIMATION-VERIFY.md](docs/ANIMATION-VERIFY.md).
