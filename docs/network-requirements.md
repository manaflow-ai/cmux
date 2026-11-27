# Network requirements

<!-- Generated from config/network/allowlist.json by python3 tests/test_network_allowlist.py --write; edit the JSON, not this page. -->

Some firewalls let through only listed hosts and addresses. This page lists every host, port and protocol a cmux NEXT client (the Mac app, its daemon, the iPhone app) reaches for relay and connectivity. `tests/test_network_allowlist.py` fails when the code names a connectivity host this list lacks, so the list is complete for what it covers (ultra-connectivity ledger row 80, RFD 0142 item O7). Every host the app talks to for any reason is in [privacy.md](privacy.md).

Allow outbound connections to the hosts below. Where a host's addresses are not fixed, allow it by name (a proxy or firewall that matches the TLS SNI or DNS name); addresses observed on a date are a hint, not a promise.

## Release builds

| Host | Kind | Ports | Addresses | What for |
| --- | --- | --- | --- | --- |
| `ape1.relay.cmux.dev` | relay | `tcp/443` HTTPS relay (WebSocket over TLS): carries the session when no direct path works<br>`udp/7842` QUIC address discovery (iroh-relay DEFAULT_RELAY_QUIC_PORT); optional, the relay works without it | not fixed: allow the host name (2026-11-24 DNS: `34.80.126.70`) | cmux managed iroh relay, Asia Pacific East: Mac and iPhone sessions when no direct path works |
| `apne1.relay.cmux.dev` | relay | `tcp/443` HTTPS relay (WebSocket over TLS): carries the session when no direct path works<br>`udp/7842` QUIC address discovery (iroh-relay DEFAULT_RELAY_QUIC_PORT); optional, the relay works without it | not fixed: allow the host name (2026-11-24 DNS: `35.221.102.234`) | cmux managed iroh relay, Asia Pacific Northeast: Mac and iPhone sessions when no direct path works |
| `apse1.relay.cmux.dev` | relay | `tcp/443` HTTPS relay (WebSocket over TLS): carries the session when no direct path works<br>`udp/7842` QUIC address discovery (iroh-relay DEFAULT_RELAY_QUIC_PORT); optional, the relay works without it | not fixed: allow the host name (2026-11-24 DNS: `34.21.149.250`) | cmux managed iroh relay, Asia Pacific Southeast: Mac and iPhone sessions when no direct path works |
| `euw4.relay.cmux.dev` | relay | `tcp/443` HTTPS relay (WebSocket over TLS): carries the session when no direct path works<br>`udp/7842` QUIC address discovery (iroh-relay DEFAULT_RELAY_QUIC_PORT); optional, the relay works without it | not fixed: allow the host name (2026-11-24 DNS: `34.12.9.64`) | cmux managed iroh relay, Europe West: Mac and iPhone sessions when no direct path works |
| `usc1.relay.cmux.dev` | relay | `tcp/443` HTTPS relay (WebSocket over TLS): carries the session when no direct path works<br>`udp/7842` QUIC address discovery (iroh-relay DEFAULT_RELAY_QUIC_PORT); optional, the relay works without it | not fixed: allow the host name (2026-11-24 DNS: `34.69.75.178`) | cmux managed iroh relay, US Central: Mac and iPhone sessions when no direct path works |
| `use4.relay.cmux.dev` | relay | `tcp/443` HTTPS relay (WebSocket over TLS): carries the session when no direct path works<br>`udp/7842` QUIC address discovery (iroh-relay DEFAULT_RELAY_QUIC_PORT); optional, the relay works without it | not fixed: allow the host name (2026-11-24 DNS: `35.243.40.255`) | cmux managed iroh relay, US East: Mac and iPhone sessions when no direct path works |
| `usw1.relay.cmux.dev` | relay | `tcp/443` HTTPS relay (WebSocket over TLS): carries the session when no direct path works<br>`udp/7842` QUIC address discovery (iroh-relay DEFAULT_RELAY_QUIC_PORT); optional, the relay works without it | not fixed: allow the host name (2026-11-24 DNS: `35.247.2.121`) | cmux managed iroh relay, US West: Mac and iPhone sessions when no direct path works |
| `turn.cloudflare.com` | turn | `udp/3478` TURN over UDP<br>`tcp/3478` TURN over TCP<br>`tcp/80` TURN over TCP<br>`tcp/5349` TURN over TLS<br>`tcp/443` TURN over TLS: the one that passes a firewall allowing only HTTPS | Cloudflare's ranges (below) | Cloudflare Realtime TURN: the phone link and screen sharing relay when no direct path works; named in the ICE answer from mobile-api.cmux.dev /v1/ice, not in client code |
| `stun.cloudflare.com` | stun | `udp/3478` STUN: learns the device's public address | Cloudflare's ranges (below) | STUN for the phone link and remote desktop; always in the /v1/ice answer |
| `stun.l.google.com` | stun | `udp/19302` STUN: second fallback for remote desktop | not fixed: allow the host name (2026-11-24 DNS: `74.125.250.129`, `2001:4860:4864:5:8000::1`) | fallback STUN for the remote-desktop link when the ticket names none |
| `cmux-device-hub.debussy.workers.dev` | signaling | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | device hub: pairing and screen sharing between your devices |
| `cmux-vnc-signal.debussy.workers.dev` | signaling | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | screen sharing signaling between your devices |
| `mobile-api.cmux.dev` | signaling | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | iPhone pairing API and signaling WebSocket; hands out the ICE (STUN and TURN) list |
| `api.chatmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | chat relay API for chatmux sessions |
| `chatmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | chat relay API for chatmux sessions |
| `cloud-api.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux Cloud API: machines, accounts, sign-in |
| `cmux-platform-production.debussy.workers.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux Cloud platform API |
| `cmux.com` | backend | `tcp/443` HTTPS and WSS (TLS) | not fixed: allow the host name (2026-11-24 DNS: `216.150.1.1`) | cmux website and API: sign-in callback, downloads fallback, connectivity reports |
| `cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | not fixed: allow the host name (2026-11-24 DNS: `216.150.1.1`) | cmux Cloud host name; machine and preview URLs under it |
| `preview.chatmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | not fixed: allow the host name | preview pages of a chatmux session (no DNS answer on 2026-11-24) |
| `share.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | shared workspace links |
| `vm.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux Cloud machine API |
| `www.cmux.com` | backend | `tcp/443` HTTPS and WSS (TLS) | not fixed: allow the host name (2026-11-24 DNS: `216.150.1.193`, `216.150.16.193`) | the same site as cmux.com: deep links and sign-in |
| `api.stack-auth.com` | auth | `tcp/443` HTTPS and WSS (TLS) | not fixed: allow the host name (2026-11-24 DNS: `34.107.252.126`) | sign-in tokens; every signaling and relay call carries one |
| `files-next.cmux.com` | updates | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | nightly NEXT update host (Cloudflare R2 bucket cmux-nightly-next): appcast and release notes |
| `files.cmux.com` | updates | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | update and download host (Cloudflare R2 custom domain): appcasts, app archives, web UI updates, cmux-tui for remote machines, art |
| `presence.cmux.dev` | updates | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | update channel push: tells the app a new build is out |

## Development and staging builds only

| Host | Kind | Ports | Addresses | What for |
| --- | --- | --- | --- | --- |
| `cmux-device-hub-dev.debussy.workers.dev` | signaling | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | device hub in development builds |
| `cmux-mobile-api-dev.debussy.workers.dev` | signaling | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | iPhone pairing API and signaling in development builds |
| `*.*.wdev.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | not fixed: allow the host name | a cmux developer's preview stack, only when the iPhone app's backend override names one |
| `api-staging.chatmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | chat relay API on staging |
| `api.*.wdev.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | not fixed: allow the host name | the API of a cmux developer's preview stack, only when the iPhone app's backend override names one |
| `cloud-api-staging.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux Cloud API on staging |
| `cmux-api-development.debussy.workers.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux API in development builds |
| `cmux-api-preview-*.debussy.workers.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux API of one pull request's preview |
| `cmux-api-staging.debussy.workers.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux API on staging |
| `cmux-platform-development.debussy.workers.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux Cloud platform API in development builds |
| `cmux-platform-staging.debussy.workers.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux Cloud platform API on staging |
| `share-dev.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | shared workspace links in development builds |
| `share-staging.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | shared workspace links on staging |
| `vm-staging.cmux.dev` | backend | `tcp/443` HTTPS and WSS (TLS) | Cloudflare's ranges (below) | cmux Cloud machine API on staging |

## Direct paths between your devices

A direct path between your own devices (iroh, WebRTC) goes to the other device's address on a UDP port chosen at run time, so no host or port can be listed for it. Where outbound UDP is blocked, the same session goes through a relay above (tcp/443) instead: slower, never broken.

## Cloudflare's ranges

Cloudflare's published ranges. Every host with ips "cloudflare" answered inside them on the fetch date (Workers custom domains, workers.dev, R2 custom domains, Cloudflare Realtime TURN and STUN). Cloudflare changes them rarely and says so on that page. Source: https://www.cloudflare.com/ips-v4, https://www.cloudflare.com/ips-v6 (fetched 2026-11-24).

IPv4: `173.245.48.0/20`, `103.21.244.0/22`, `103.22.200.0/22`, `103.31.4.0/22`, `141.101.64.0/18`, `108.162.192.0/18`, `190.93.240.0/20`, `188.114.96.0/20`, `197.234.240.0/22`, `198.41.128.0/17`, `162.158.0.0/15`, `104.16.0.0/13`, `104.24.0.0/14`, `172.64.0.0/13`, `131.0.72.0/22`

IPv6: `2400:cb00::/32`, `2606:4700::/32`, `2803:f800::/32`, `2405:b500::/32`, `2405:8100::/32`, `2a06:98c0::/29`, `2c0f:f248::/32`

## cmux's own points of presence

Status: not bought. Slot: RFD 0166 step 3 boxes, filled when bought. No addresses yet; this section lists them, with their hosts, once the boxes exist.
