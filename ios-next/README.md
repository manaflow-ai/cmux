# cmux-next mobile (minimal iOS app)

Two iOS app shells over one shared package, a Mac host and a backend.

| Path | What | Language |
| --- | --- | --- |
| `PROTOCOL.md` | Wire contract for every side. Change it first. | |
| `App/` | XcodeGen project: `Drawer` (ChatGPT-style sidebar) and `Tabs` (native tab bar). | Swift |
| `Packages/CmuxNextMobile/` | Shared modules (`CN*`), see `Package.swift`. | Swift |
| `host/` | `cmux-next-host`: runs on the Mac, answers WebRTC links, serves terminals, ACP agents, Chief and browser tabs. | TypeScript (Node) |
| `backend/` | Cloudflare Worker + Durable Object signaling + PlanetScale. | TypeScript |
| `scripts/remote-ios.sh` | Build, run and screenshot on a headless remote simulator. | bash |
| `reference/` | iMessage and Safari capture notes (frames live outside git). | |

Module owners in `Packages/CmuxNextMobile/Sources/`: `CNCore` (protocol models),
`CNTransport` (link, lanes, RPC, loopback), `CNTransportWebRTC`, `CNBackend`,
`CNDesign`, `CNAuthUI`, `CNConversationsUI`, `CNAgentUI`, `CNTerminalUI`,
`CNBrowserUI`, `CNSettingsUI`, `CNMockHost`, `CNAppShell`.
