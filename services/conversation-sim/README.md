# conversation-sim

Fake remote chat service for exercising the cmux conversation transcript under
network pressure. Wire protocol: [PROTOCOL.md](PROTOCOL.md). Bun only, no
dependencies.

```bash
bun run services/conversation-sim/server.ts          # PORT=4870 HOST=0.0.0.0
bun run services/conversation-sim/selftest.ts        # boots its own server on a random port
```

Env: `PORT`, `HOST`, `SEED` (history seed, default 1337), `LOG=verbose` (log
every RPC and media fetch), `EVENT_LOG_CAP` (default 50000),
`GROUP_MESSAGES` / `DIRECT_MESSAGES` (default 20000 / 5000).

Connect a simulator or the DEBUG app to `ws://127.0.0.1:4870/ws?conversation=group`
(or `conversation=direct`). From a physical device use the Mac's LAN or
Tailscale address; attachment URLs are built from the `Host` header the client
connected with, so they resolve from the same network path.

## Knobs

`GET /admin/knobs` reads, `POST /admin/knobs` with a partial JSON object writes.

| knob | default | effect |
| --- | --- | --- |
| `latencyScale` | 1 | multiplies every simulated latency (RPCs, notification delay, status transitions, media) |
| `failRate` | 0.04 | `send` fails with `-32002` |
| `historyFailRate` | 0.07 | `history` fails with `-32001` |
| `duplicateRate` | 0.02 | each `event` notification is sent twice |
| `disconnectEverySeconds` | 240 | each socket is dropped at a jittered 0.5x to 1.5x interval; 0 disables |
| `botIntervalScale` | 1 | multiplies bot pacing (typing, replies, tapbacks); large values silence bots |

## Pressure CLI

`SIM_URL` overrides `http://127.0.0.1:4870`.

```bash
bun services/conversation-sim/pressure.ts burst group 40 [intervalMs]
bun services/conversation-sim/pressure.ts disconnect
bun services/conversation-sim/pressure.ts knobs latencyScale=3 failRate=0.2
bun services/conversation-sim/pressure.ts state
bun services/conversation-sim/pressure.ts client group 5    # second "me" client: sends, retries, reacts, edits, resumes
bun services/conversation-sim/pressure.ts flood direct 30   # 30 concurrent sends from me
```

Extra admin endpoints beyond the protocol: `GET /admin/state` (heads, event-log
window, open sockets) and `intervalMs` on `/admin/burst` (`0` creates all
messages before the response returns).
