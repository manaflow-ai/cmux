# Weft: the cmux mesh (design)

Status: design and v1 build, 2026-10-22. Code: `cmux-tui/crates/cmux-weft`. Fly apps (org
`manaflow`): `cmux-weft-coord-staging`, `cmux-weft-relay-staging`, then `cmux-weft-coord`,
`cmux-weft-relay` for production.

Weft is cmux's own Tailscale-shaped network: a coordination service that knows every device
and the policy, a WireGuard data plane that runs inside the cmux process (no root, no kernel
extension, no system VPN prompt), and relays on Fly so two devices always reach each other.
The name: in weaving, the weft is the thread that crosses the warp and binds the cloth.

## 0. What exists today (inventory, 2026-10-22)

Weft does not start from zero. It reuses the parts that are already proven and replaces the
parts that tie cmux to a vendor.

| Piece | Where | What it is | Vendor tie |
| --- | --- | --- | --- |
| `cmux-wg` | `cmux-tui/crates/cmux-wg` | In-process WireGuard (boringtun) plus smoltcp TCP. `WgMesh` = one key, one UDP socket, many peers, crypto-key routing, roaming, gateways, multipath, watchdog. Authors: Lawrence (59 commits), Aziz (5), Austin (3). | None. Weft's data plane. |
| cmux VM mesh M1-M4 | `workers/cmux-vm/mesh/` (DESIGN.md, agent, validation) | Meshes, devices, enrollment codes, ACL compiled to **Freestyle** firewall rules, Freestyle tunnels per device, Stack membership revoke webhook. Cloudflare Worker + PlanetScale. | **Freestyle** (VPC, tunnels, firewall). Freestyle does not forward tunnel to tunnel, has one region (SF), and all tenants share one account and its 200-rule limit. |
| Cloud terminal hub | `docs/cloud-userspace-wireguard.md`, `cmux-tui/src/remote_wg_hub.rs` | App-owned userspace WireGuard peer into the Freestyle private network for Cloud VMs. | **Freestyle** tunnel endpoint. |
| iPhone link (Aziz) | `cmux-next-ios/rust/crates/cmux-mobile-link`, PROTOCOL.md; PRs #20322, #23829, #18426 | Phone to Mac: WireGuard over UDP with STUN candidates, WebRTC media, **Cloudflare TURN** as the relay, signaling on a Cloudflare Worker + Durable Object. | **Cloudflare** (TURN, Workers). Not Freestyle. |
| Native enrollment (Leo) | PRs #22066, #21928, #22081, #22074 (open) | Mac and server device enrollment with per-account/team/mesh WireGuard keys, wired into server pairing and the Cloud hub. | Builds on the cmux VM mesh, so **Freestyle** underneath. |
| `cmux-relay` | `cmux-tui/crates/cmux-relay` | Opaque WebSocket circuit relay for remote sessions (tickets, admission). | None. Pattern reused by the Weft relay. |
| iroh v2 | `workers/iroh-v2`, `iroh` dep in cmux-tui | iroh endpoint ownership and directory on Cloudflare DO. | iroh relays (n0) unless self-hosted. |
| Tailscale | hq `tsadmin`, ACL hq#2604, acpmux `tailnet.rs`, `cmux host serve` tcp 7319 | How the fleet and Cloud Chief reach each other today. | **Tailscale** (coordination, DERP, ACL). |

Fact-check of the user's claim: "Aziz's work relies on Freestyle" is **partly wrong**. Aziz's
link (phone to Mac) uses Cloudflare (TURN and the Worker), not Freestyle. The work that does
rely on Freestyle is the cmux VM mesh (Lawrence) and Leo's enrollment PRs built on it.

## 1. Goals and non-goals

Goals (v1):
- G1. Any two enrolled devices of one tailnet reach each other over WireGuard, behind any NAT,
  with no root and no system VPN, from the cmux process or the `weft` CLI.
- G2. Identity is the cmux account (Stack Auth). Servers and VMs join with tagged auth keys.
- G3. A Tailscale-shaped ACL policy (groups, tags, tag owners, `src -> dst:ports`) is the only
  source of permission. Default deny. Enforced at the receiver, and peers you may not reach are
  not even in your netmap.
- G4. Relays in several Fly regions. The relay cannot read traffic and cannot be used by a
  device outside the tailnet.
- G5. Coexists with Tailscale: no addresses on the host, no routes, no DNS changes.

Non-goals (v1): system-wide VPN (other apps), exit nodes, subnet routers, MagicDNS, a web admin
UI, direct UDP hole punching (M2, section 6).

## 2. Architecture

```text
            +----------------------------+
            |  weft-coord (Fly, sjc)     |   HTTPS JSON, device requests signed
            |  SQLite on a Fly volume    |   with the device's Ed25519 machine key
            |  policy, nodes, audit      |
            +-------------+--------------+
                          | netmap long-poll (peers, filter, relay map, relay ticket)
         +----------------+-----------------+
         |                                  |
   +-----v------+   WireGuard (boringtun)   +-----v------+
   | device A   |<=========================>| device B   |
   | cmux-wg    |   rides a relay or UDP    | cmux-wg    |
   +-----+------+                           +-----+------+
         |  wss://relay  (opaque WG datagrams,    |
         +---->  weft-relay (Fly: sjc iad fra nrt) <----+
```

Three binaries in one crate (`cmux-weft`): `weft-coord`, `weft-relay`, `weft` (client). The
client is also a library (`cmux_weft::client::WeftNode`) for cmux-tui and acpmux to embed.

### 2.1 Keys

Each device holds two keys, generated on the device, private halves never leave it:

| Key | Type | Use | Rotation |
| --- | --- | --- | --- |
| machine key | Ed25519 | Signs every control request. Identifies the device to the coordinator. | Rare; re-enroll. |
| node key | X25519 | The WireGuard static key; what peers see. | `weft rotate` (signed by the machine key); expires after 90 days by default. |

The coordinator holds one Ed25519 relay-ticket signing key (Fly secret). Relays hold only its
public half. The state file on the device is mode 0600 and the keys are zeroized in memory.

### 2.2 Control protocol (v1, JSON over HTTPS)

Device requests carry headers `weft-node`, `weft-ts` (unix ms), `weft-nonce` (16 random bytes,
hex) and `weft-sig` = Ed25519 over `"weft-v1\n" + method + "\n" + path + "\n" + ts + "\n" + nonce
+ "\n" + sha256(body)`. The coordinator rejects a timestamp more than 60 s off, a nonce it has
seen in the last 120 s, and a signature that does not verify against the stored machine key.
TLS (Fly edge) protects confidentiality; the signature makes a stolen bearer token useless and
binds every request to the device.

| Route | Auth | Purpose |
| --- | --- | --- |
| `POST /v1/tailnets` | admin token or Stack user | Create a tailnet (the creator becomes owner). |
| `POST /v1/tailnets/{t}/authkeys` | owner/admin | Mint an auth key: tags, reusable, preapproved, expiry. Only its SHA-256 is stored. |
| `POST /v1/register` | auth key or Stack user, plus proof of the machine key | Enroll a device; returns node id, addresses, state `approved` or `pending`. |
| `POST /v1/tailnets/{t}/nodes/{id}/approve` | owner/admin | Approve a pending device (the Tailscale device-approval flow). |
| `DELETE /v1/tailnets/{t}/nodes/{id}` | owner/admin | Revoke a device; peers drop it on their next netmap. |
| `PUT /v1/tailnets/{t}/policy` | owner/admin, `if-version` | Replace the ACL policy (validated, compare-and-swap, audited). |
| `GET /v1/netmap?since=v` | device signature | Long-poll (25 s): self, peers, inbound filter, relay map, relay ticket. |
| `POST /v1/endpoints` | device signature | Report UDP endpoint candidates and home relay. |
| `POST /v1/rotate` | device signature | Replace the node key. |
| `GET /v1/tailnets/{t}/audit` | owner/admin | Audit log. |

Identity backends: Stack Auth access tokens (ES256 JWT, verified against the project JWKS;
the subject is the cmux user id, team membership decides tailnet membership), the bootstrap
admin token (Fly secret, for operators), and auth keys.

### 2.3 ACL policy

JSON (comments allowed), Tailscale-compatible in shape so people already know it:

```json
{
  "groups": { "group:eng": ["user:lawrence", "user:austin"] },
  "tagOwners": { "tag:fleet": ["group:eng"], "tag:vm": ["group:eng"] },
  "acls": [
    { "action": "accept", "src": ["group:eng"], "dst": ["tag:fleet:22,7319", "tag:vm:*"] },
    { "action": "accept", "src": ["tag:vm"], "dst": ["tag:fleet:7319"] }
  ]
}
```

Selectors: `*`, `user:<id>`, `group:<name>`, `tag:<name>`, `node:<id>`. Ports: `*`, a number, a
range `a-b`, or a comma list. A device tagged at enrollment is owned by its tags, not by a user
(as in Tailscale). Only an owner of a tag may mint an auth key with that tag.

Compilation for device X: `filter(X)` = for each rule, every node matched by `src` may open TCP
to X on the rule's ports if `dst` matches X. `peers(X)` = nodes that X may reach plus nodes that
may reach X (replies need the session). A policy change bumps the tailnet version and wakes every
long-poll. Default deny: an empty policy gives an empty netmap.

Enforcement: (1) the netmap omits nodes that have no rule in either direction, so no WireGuard
session exists; (2) the receiving device checks every accepted connection's peer key and port
against its filter and closes it if not allowed, before a byte is read. The key comes from the
WireGuard session that carried the SYN (`WgMeshListener::accept`), never from the source address.

### 2.4 Addresses

Per tailnet a ULA /64 `fd7c:6d78:7766:<tailnet>::/64` (the existing cmux prefix `fd7c:6d78::/32`
plus `wf`); each node gets a /128. The addresses exist only inside the userspace stacks, so they
never conflict with Tailscale (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) or local networks.

### 2.5 Relays

`weft-relay` is a DERP-shaped relay over WebSocket (`wss://.../v1/relay`), so it works through
Fly's shared anycast IPs and any firewall that allows HTTPS. The first frame is the device's relay
ticket: `{tailnet, node_key, exp}` signed by the coordinator. After that a frame is
`[32-byte peer node key][WireGuard datagram]`; the relay forwards it as `[32-byte sender
key][datagram]` to that peer if the peer is connected to this relay with a ticket of the same
tailnet. The relay never sees plaintext (WireGuard end to end), keeps no state on disk, drops
frames over 2 KiB, and applies a per-connection token bucket.

Each device picks a home relay (lowest WebSocket RTT among the relay map) and reports it. To
send to a peer, the device uses the peer's home relay (it opens a second connection if the peer's
home differs). In the client, each peer gets a loopback UDP socket that stands in for the peer:
`WgMesh` sends the peer's datagrams there and the shim moves them over the relay, so `cmux-wg`
is used unchanged.

Fly regions for v1: `sjc`, `iad`, `fra`, `nrt` (one shared-cpu-1x machine each, about $2/month
each).

## 3. Enrollment flows

- Server or VM: `weft up --coord URL --authkey tskey...` (key minted with tags, preapproved). For
  Cloud VMs the VM API mints a one-use key per VM.
- Person's Mac: `weft up --coord URL` with the cmux login token (the app already has it). If the
  tailnet requires approval, the device shows `pending` and an owner runs `weft approve <node>` or
  uses the Settings page (later). Same as Tailscale "device approval".
- Add-devices UX (future, in the app): "Add a device" shows a one-use auth key and a QR code plus
  a one-line install command; the device appears pending and the owner taps Approve.

## 4. Threat model

| Threat | Mitigation |
| --- | --- |
| Relay operator or Fly reads or changes traffic | WireGuard end to end; the relay sees only node keys, sizes and timing. |
| Device outside the tailnet uses the relay | Signed relay ticket bound to tailnet and node key, 10 minute expiry; forwarding only inside one tailnet. |
| Stolen auth key | Hash-only storage, expiry, single-use by default, tags limited by tag owners, preapproval off by default for user keys; every use audited. |
| Stolen bearer/session token replays control calls | Every device call is signed by the machine key over method, path, time, nonce and body hash; 60 s window and nonce cache. |
| Compromised coordinator | Can add a rogue peer to netmaps (same as Tailscale without Tailnet Lock). M3: tailnet lock, nodes sign each other's keys. Audit log records every netmap-affecting change. |
| Revoked device keeps talking | Revocation removes it from every netmap on the next long-poll (seconds); peers remove the WireGuard peer, so its sessions die at once. Relay tickets expire in 10 minutes. |
| Policy mistake opens too much | Default deny; validation rejects unknown groups/tags; compare-and-swap version; audit with the full before/after. |
| Resource exhaustion on coord/relay | Body size limits, long-poll cap per node, token buckets, bounded queues that drop. |
| Spoofed source inside the mesh | WireGuard crypto-key routing drops packets outside the sender's allowed IPs; filter keyed by session key. |
| Malformed control input | Strict parsers with size limits; property tests and a fuzz target for policy and frame parsing. |

## 5. Migration path next to Tailscale

1. v1: Weft runs beside Tailscale. acpmux and cmux-tui use a Weft address when the peer is in the
   Weft netmap, otherwise the Tailscale path as today.
2. Mirror the tsadmin ACL (hq#2604) into a Weft policy with the same tags, compare with a
   dry-run tool, then move one fleet group (for example the minis' `cmux host serve` port 7319).
3. Replace Freestyle tunnels for device-to-VM traffic with Weft on the VM (the VM API mints the
   auth key). Freestyle VPC remains only for VM-to-VM inside the datacenter, if at all.
4. Retire Tailscale for agent traffic once Weft has direct paths (M2) and a month of no incidents.

## 6. Milestones

- v1 (this change): coord + ACL + audit, relay, client CLI and library, relay data path,
  staging on Fly in four regions, two real machines (a fleet Mac mini and a Freestyle VM)
  passing traffic under the ACL, latency against Tailscale.
- M2: direct paths. Endpoint candidates (local interfaces, STUN on the relay over UDP with a Fly
  dedicated IPv4), disco pings through the relay, and upgrade with `cmux-wg` `Multipath`, which
  already runs several paths to one peer.
- M3: tailnet lock, key expiry UI, SSO-backed device posture, MagicDNS names in cmux.
- M4: system-wide mode through the existing NetworkExtension work (#11967) for other apps.

## 7. Operations

- Staging first: every deploy goes to `*-staging` and runs `weft-smoke` (two ephemeral nodes,
  allow and deny checks, relay round trip in each region) before production.
- Coordinator state: SQLite in WAL mode on a Fly volume, snapshotted daily to the volume's Fly
  snapshots; one primary machine (v1). Postgres (PlanetScale) is the M3 path for multiple
  coordinators.
- Secrets (Fly): `WEFT_ADMIN_TOKEN`, `WEFT_TICKET_KEY` (coord), `WEFT_TICKET_PUBKEY` (relay).

## 8. Staging evidence (2026-10-22)

Deployed from `cmux-tui/crates/cmux-weft/deploy/` (org `manaflow`):

| App | URL | Machines |
| --- | --- | --- |
| `cmux-weft-coord-staging` | https://cmux-weft-coord-staging.fly.dev | 1 (sjc, 1 GB volume `weft_data`) |
| `cmux-weft-relay-staging` | https://cmux-weft-relay-staging.fly.dev | 4 (sjc, iad, fra, nrt); `/v1/relay/<region>` and `/healthz/<region>` reach that region through `fly-replay` (checked: each answers with its own region) |

Secrets live in Fly and in `~/.secrets/weft-staging.env` (mode 600) on the operator Mac.

Live run, tailnet `cmux-staging`, policy `tag:fleet -> tag:vm:7, tag:fleet:7`:

| Check | Result |
| --- | --- |
| Fleet Mac mini (cmux-lawrence-2, Santa Clara) to Freestyle VM (Ubuntu 24.04, egress 443/53 only, no inbound), echo port 7, 300 x 64 B | first reachable 342 ms after start; connect 12.2 ms; RTT min 10.5, p50 12.6, p90 18.2, p99 31.4, max 236 ms; both homed on relay sjc |
| Freestyle VM (`tag:vm`) to the mini's port 7 | refused by the mini's inbound filter (not reachable within 15 s) |
| Mac mini to Mac mini (cmux-lawrence-2 to cmux-lawrence, same LAN) over Weft via relay sjc | p50 14.2, p90 16.4, p99 21.0 ms |
| Same pair over Tailscale | direct LAN path: ICMP avg 1.2 ms (min 0.6); Tailscale's nearest DERP (sfo) is 12.2 ms one way from cmux-lawrence-2 |
| Mac mini to Fly relay (sjc) | ICMP avg 8.3 ms |

Reading: Weft v1 always relays, so it costs about the two legs to the nearest Fly region. That is
close to a DERP-relayed Tailscale path, and about 12 times a direct LAN path. Direct UDP paths
(M2) are the next milestone and are what closes that gap. After the run the VM was deleted
(Freestyle 404) and the five test nodes were revoked (audit `node.revoke`).

Tests (`cargo test -p cmux-weft`, 23 tests): policy compile and validation, signature binding,
replay, clock window, tickets, frames, 6 property-fuzz targets (2000 cases each), and a loopback
tailnet with two relays that checks allow, receiver-side deny, policy removal, revocation,
approval and rotation. A mutation check (receiver filter disabled) fails the e2e test.

Known v1 gaps: identity is the admin token plus auth keys (Stack Auth JWT sign-in is M2);
an existing connection keeps running after its port leaves the filter until it closes (new
connections are refused at once, and revocation removes the WireGuard peer); one coordinator
machine (SQLite); no production apps yet.
