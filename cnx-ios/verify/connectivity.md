# cnx link connectivity (2026-10-12)

Client: `cnx-dial` (release) on Aziz's MacBook (macOS 27.0.1).
Mac: `cnx-hostd` (release) on `mini-cmuxs-mac-mini-2` (macOS 27.0.1), built
from `feat-cnx-ios-rust` under `~/cnx-ios-e2e`, started over SSH as `cmux`.
Both runs used `--exclude-cgnat` / `CNX_EXCLUDE_CGNAT=1`, so neither side
offered or used a Tailscale (100.64.0.0/10) address.

## Live backend run (Worker v0.3.0, personal space)

Credentials: password sign-in with the DEBUG dev credential from
`CmuxAuthRuntime`. Tokens were kept in 0600 files and never printed; the
mini got the refresh token over ssh stdin, and every token file was deleted
afterwards. Team `personal-<sub>`. `cnx-hostd` registered the mini and
`cnx-dial` registered a phone device in that space. `/v1/ice` returns STUN
only (the TURN secrets are empty). Both sides used Tailscale exclusion.
`daemon` ran against `cnx-stub-tui`: `identify` was answered and `run`
refused (`forbidden`) on every successful link.

| Transport | Path | Signaling | Connect (total) | RTT min/median/max | 10 MiB echo |
| --- | --- | --- | --- | --- | --- |
| WebRTC (STUN only) | none: ICE timed out (25 s) | n/a | n/a | n/a | n/a |
| WireGuard | relay through the Worker | 377 ms | 568 ms | 21 / 27 / 124 ms | 13.1 s, 6.4 Mbit/s each way |
| WireGuard, forced relay | relay through the Worker | 350 ms | 545 ms | 21 / 26 / 72 ms | 11.8 s, 7.1 Mbit/s each way |

Why no direct path: both hosts share one NAT, and the mini's sshd-launched
`cnx-hostd` cannot send UDP to the LAN, so UDP works only from the phone to
the Mac. WireGuard detects this (no `0xff` marker comes back) and stays on
the relay. WebRTC has no TURN to fall back on.

## Distant run: not done

- No Freestyle API key on this Mac: `~/.secrets/freestyle-beta.env` is
  missing, and no other `.env` holds one.
- The Blacksmith CLI is not installed.
- Every reachable fallback host shares the same public IP (104.184.154.177):
  Aziz's other MacBook and all `mini-cmux*` hosts.
- AWS Macs (via `cmux-lawrence`) are on another network but were not
  approved for this, so I did not use them.

Expected once a VM exists: WireGuard over the Worker relay works from an
IPv6-only VM, since `cnx-dial` then sends no endpoints. WebRTC needs TURN,
because the mini has no global IPv6.

To rerun (tokens in 0600 files, never printed; the team is `personal-<sub>` or a Stack team):

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
