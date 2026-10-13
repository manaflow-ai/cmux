# cnx link connectivity (2026-10-12)

Client: `cnx-dial` (release) on Aziz's MacBook (macOS 27.0.1).
Mac: `cnx-hostd` (release) on `mini-cmuxs-mac-mini-2` (macOS 27.0.1), built
from `feat-cnx-ios-rust` under `~/cnx-ios-e2e`, started over SSH as `cmux`.
Both runs used `--exclude-cgnat` / `CNX_EXCLUDE_CGNAT=1`, so neither side
offered or used a Tailscale (100.64.0.0/10) address.

## Live backend run: blocked on a team

The dev Worker is up (`/v1/health` reports `0.2.0`). A Stack dev-project
token now works without 1Password: password sign-in with the DEBUG dev
credential checked into `CmuxAuthRuntime` (`AuthCoordinator.swift`)
succeeds. The tokens went to 0600 files and were never printed. Two
problems remain:

- The account belongs to no team, and `POST /api/v1/teams` with its access
  token returns 403 "Client team creation is disabled for this project". The
  Worker admits devices and signaling only for team members, so
  `POST /v1/devices` returns 403 and no dial is possible.
- `GET /v1/ice` returns only `stun:stun.cloudflare.com:3478`, with no TURN
  servers (the TURN secrets are empty).

Any one of these unblocks it:

- Add the dev account to a dev-project team in the Stack dashboard.
- Enable client team creation on the dev project.
- Provide `STACK_SECRET_SERVER_KEY` (server-side team creation).

### Distant run (Freestyle VM): not attempted

Freestyle VMs are IPv6-only, and the mini has no global IPv6 (only ULA
`fd06::/64`; `curl -6` fails). No direct UDP path, WebRTC or WireGuard, can
exist between them. The only possible path is the real Worker's WireGuard
relay frames, or a dual-stack TURN server. Both are blocked as above, so I
did not lease a VM. Once a team exists: WireGuard from the VM should connect
over the relay (`cnx-dial` sends no endpoints when STUN over IPv4 fails).
WebRTC from the VM needs TURN.

To run it once a token exists (a 0600 file, never printed):

```bash
# Mac (over ssh; token piped on stdin into ~/cnx-ios-e2e/token, mode 0600)
CNX_BASE_URL=https://cnx-ios-api-dev.debussy.workers.dev CNX_TEAM_ID=<team> \
CNX_ACCESS_TOKEN_FILE=~/cnx-ios-e2e/token CNX_EXCLUDE_CGNAT=1 \
CNX_TUI_SOCKET_DIR=~/cnx-ios-e2e/sock ~/cnx-ios-e2e/target/release/cnx-hostd
# client
cnx-dial --base-url https://cnx-ios-api-dev.debussy.workers.dev --token-file <token> \
  --team <team> --mac <mac device id> --exclude-cgnat --daemon [--force-relay]
```

## Fake backend run (real network, no Stack credentials)

Signaling and relay frames went through `cnx-fake-backend` on this Mac,
reached by the mini over Tailscale (signaling only). STUN was Cloudflare's.
The `daemon` service ran against `cnx-stub-tui`. The mini has no cmux-tui
binary or session; its `~/.local/bin/cmux` is the macOS app CLI.

**The network turned out not to be distant.** Both machines sit behind the same
NAT (same public IP 104.184.154.177, same gateway 172.20.20.1). The mini's
`cnx-hostd`, started from sshd, gets `EHOSTUNREACH` sending UDP to this
Mac's LAN address. macOS Local Network privacy is the likely cause. So UDP
works in one direction only: phone to Mac.

| Transport | Path | Connect | RTT min/median | 10 MiB echo | daemon |
| --- | --- | --- | --- | --- | --- |
| WebRTC | none (ICE timed out after 25 s) | n/a | n/a | n/a | n/a |
| WireGuard | relay (Mac→phone), UDP (phone→Mac) | 65 ms | 0.7 / 0.9 ms | 0.65 s, 129 Mbit/s each way | `identify` ok; `run` refused `forbidden` |
| WireGuard, forced relay | relay | 13 ms | 0.5 / 0.5 ms | 0.62 s, 135 Mbit/s each way | same |

RTTs are sub-millisecond because the relay here is this Mac's fake backend
on the same LAN, not the Cloudflare Durable Object.

- **WebRTC:** ICE needs connectivity checks in both directions. With
  Mac→phone UDP refused, no hairpin NAT, and no TURN from the fake backend's
  `/v1/ice`, there is no usable pair. The real backend's TURN servers should
  fix this. Not yet measured.
- **WireGuard, first attempt:** it failed. The Mac received the phone's UDP,
  switched to UDP-only replies it could not deliver, and the handshake never
  finished. The fix is commits `84f5e39f122` (red test) and `e2c06295cc7`
  plus the follow-up marker commit. A side now goes UDP-only only after the
  peer's `0xff` relay marker confirms its UDP arrives (PROTOCOL.md). The rerun
  above held the link on the relay.
