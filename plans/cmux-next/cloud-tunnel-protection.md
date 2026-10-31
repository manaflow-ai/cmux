# Cloud tunnel protection (cmux next vs classic)

Status: implemented in https://github.com/manaflow-ai/cmux/pull/23952 (2026-10-23).
Policy recommendation below is a draft for
https://github.com/manaflow-ai/cmux/issues/13742; it is not posted yet.

## Threat model

A Cloud VM's private address (its VPC, `10.x` / `fd7a::`) is reachable only
through this Mac's WireGuard peer. The VM's own services there (the daemon's
link, noVNC on 6901, a dev server) trust that network. What must not reach
them:

1. Another computer: covered by WireGuard (only this Mac's key is a peer).
2. Another user on this Mac: covered by the socket's `0600` mode, its `0700`
   directory and the hub's peer-uid check.
3. Another program of the same user (a browser page through a local port, a
   rogue npm script, any tool that finds the socket): this is the gap.
4. Malware with the user's full privileges that can read the app's memory or
   debug it: out of scope for both apps (hardened runtime blocks
   `task_for_pid` on the app; it can still read files the user owns).

## Classic and next before this change

| | cmux classic | cmux next (before) |
|---|---|---|
| App panes reach VMs through | userspace `cmux-tui wg hub` (SOCKS5 on a Unix socket) | same hub |
| Browser to a VM's localhost | per-machine authenticated CONNECT proxy | `RemoteLocalhostProxy` (peer-checked: only the app and its helpers) to the hub |
| Hub clients allowed | any process of the user (uid check, no auth) | same |
| WireGuard key at rest | `~/.cmuxterm/wireguard/`, plaintext, `0600` | `cloud-next/`, plaintext, `0600` |
| Full config on disk | yes, `0600` | yes, `wireguard.conf`, `0600` |
| System-wide VPN | opt-in `cmux vpn up`: `NEPacketTunnelProvider` system extension, VPC CIDRs only | none (REWRITE.md decision X2) |

The Network Extension is not what protects classic's panes: classic's panes
use the same userspace hub. It is an opt-in way to give every program on the
Mac the VPC, which widens access rather than narrowing it.

## What changed

- `wg hub --client-token-stdin` takes a client token as stdin's first line
  and serves only SOCKS5 clients that send it (RFC 1929 username/password,
  constant-time compare). The app makes one 32-byte random token per app
  launch and keeps it only in memory, so a hub that restarts still accepts
  the links that already hold it. A same-user program that finds the socket
  gets method `0xFF` or an auth failure and reaches nothing (gap 3).
- 2026-10-27, with feat-cmux-next's `cmux cloud enroll-machine` (ssh through the hub with the
  `cmux wg dial --hub` ProxyCommand, a separate process with no token): a client without the
  token reaches port 22 only (`OPEN_PORTS` in `wireguard_hub.rs`), on any address inside the
  tunnel's routes. ssh authenticates both ends itself (this Mac's key in the machine's
  `authorized_keys`, the host key pinned at enrollment), and every other port (noVNC, the
  desktop hosts, dev servers, the daemon link) still needs the token. What the lane gives
  back: a same-user program that can use this Mac's ssh key (the key file or the agent)
  can `ssh -L` through an enrolled machine's sshd to that machine's loopback services, which
  the token alone would have kept from it. Still narrower than before the token (no gate at
  all). Narrowing it further (the open lane only for enrolled addresses, or `restrict`
  options on the enrolled `authorized_keys` line) is a policy question for 13742.
- `wg hub --config -` reads the wg-quick config from stdin. The app no longer
  writes `wireguard.conf` and deletes an earlier build's copy.
- `remote connect --wireguard-hub-token-stdin`: the app hands each link
  sidecar the token on stdin; it never appears in argv, the environment or a
  file.
- Open Desktop's `HubLoopbackOpener` presents the token.
- `remote-probe --json` reports `wireguard-hub-token`.

Tests: `cmux-remote` `wireguard_hub_e2e` (a tokenless and a forged client are
refused at the real hub, the real dialer with the token gets through),
`socks` unit tests, `cmux-tui` flag and stdin tests, and Swift
`CloudHubLoopbackTests` and `CloudLinkReconnectingTests` (config and token on
stdin, nothing on disk).

## What is left

- 2026-10-25: the WireGuard key is now per app launch and only in memory
  (`CloudTunnelHub.key`); each start enrolls its public key, and the server
  rotates the device's peer to it, so an old key file stops working. This
  stops reuse of a copied key; it does not stop a same-user program that holds
  the person's Cloud sign-in from enrolling its own key for this device (the
  device id is not a secret), which rotates the app's peer off until the app
  starts its hub again. Re-enrolling when the hub loses its handshake, and
  honouring `409 vm_access_grant_busy`'s retry, are follow-ups. Found
  live: a Chief subagent had read `cloud-next/wireguard.private.key`, started a
  second hub on it and a `127.0.0.1:16901` bridge; the two hubs knocked each
  other's session off and the desktop's mouse froze. The Keychain is no
  longer needed for this.
- A same-user program without the token can still hold the hub's 256
  connection slots open for the 10-second handshake deadline and so delay the
  app's own dials (denial of service, not access). A program that can do that
  can also signal the app; not addressed here.
- `wg hub --control` (datagram ports) is not used by next and is not
  token-gated; gate it before anything uses it.
- `cmux vpn up` parity (the Network Extension) is a product decision, not a
  protection gap. It needs NE and system-extension entitlements, an App
  Group, `.tunnel` App IDs and profiles, release-workflow embedding, and
  lifting the guard in `scripts/sign-cmux-bundle.sh`.

## Draft recommendation for 13742

Recommend: require the per-launch client token for every app-started hub
(shipped here), keep the hub the only way into a VM for app panes, and do
not add a system-wide VPN to next until there is a user need for VM access
from programs outside cmux. If that need comes, ship it as the classic
opt-in `cmux vpn up` routing only the account's VPC CIDRs. Keep the WireGuard
key per launch and in memory only (shipped here), so no program on the Mac
can reuse it.
