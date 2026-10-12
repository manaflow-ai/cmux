# cmux-next mobile (native)

A native iOS client for cmux-next and the Mac-side host it talks to.

| Path | What |
| --- | --- |
| `backend/` | Cloudflare Worker (accounts, pairing, signaling, TURN credentials) on PlanetScale MySQL. |
| `Packages/CNMKit/` | Shared Swift: wire protocol, transport-agnostic peer layer, WebRTC transport. |
| `host/` | macOS host: pairs with an account, accepts phone peers, serves terminals, agents and Chief. |
| `ios/` | The iOS app (XcodeGen project). |
| `docs/` | API, protocol, design and verification notes. |

The phone and the Mac never depend on a specific transport. `CNMTransport`
defines peers, channels and signaling; WebRTC (Cloudflare STUN/TURN) is the
first implementation.
