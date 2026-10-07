# cmux next: transport (WireGuard overlay with Durable Object rendezvous and relay)

Status: proposal, 2026-10-02 (lane 12, transport lead). Replaces iroh everywhere in cmux-next; shipping main keeps iroh until each path is replaced. Applies decisions T1, T2, D37, D38 and the identity rules (spec/identity-and-permissions.md). Builds on spec/sync-and-transport.md section 6 (overlay), spec/network-policy.md (policy, Freestyle facts), spec/team-vm.md (SSH paths), plans/cmux-next/data-model.md (sessions), plans/cmux-next/remote-localhost.md (loopback streams ride the link). Spec owner: the coordinator. Measured numbers are in section 13; each one names its method, its sample count and its two ends. Code: `cmux-tui/crates/cmux-transport` (pure core, section 15).

## 0. Decisions in this proposal

1. One overlay. Every cmux endpoint (the `cmux link` process on a Mac, Mac mini or Linux machine, the cmux server, every Cloud VM and team VM daemon, and the iOS app) runs one userspace WireGuard endpoint with one WireGuard key. A remote link between two endpoints is one end-to-end WireGuard session between them. Relays, Freestyle and Cloudflare carry ciphertext only.
2. Paths are underlays. A session's datagrams travel on the best working path. The session, its overlay addresses and its TCP streams survive every path change. Which paths exist depends on the target:
   - to a machine in the team VPC (Cloud VM, team VM, a cmux server hosted there): `direct_wan` over IPv6 when the device has IPv6 (the VM's public IPv6, opened by a firewall rule for the device's current /128), then `via_cloud_region` (the device's Freestyle tunnel), then `do_relay`;
   - to a Mac, Mac mini or a cmux server outside the VPC: `direct_lan`, then `direct_wan` (a punched IPv4 mapping or IPv6), then `do_relay`.
   Freestyle does not forward between two tunnels (measured, section 13.2), so there is no Mac-to-Mac path through the VPC. This is D38 as decided: same-LAN direct, else the Durable Object relay.
3. Connect fast, then improve. A dial sends the handshake on every available path at once; the first answer wins; probes then measure each path and the selector moves to the best one (direct first) without a reconnect.
4. Durable Objects do rendezvous, relay and fallback. The target host's `HostDO` exchanges candidates, relays datagrams while nothing better answers (about 40 % of NAT pairs never get a direct path, section 13.3), and is the only path for web clients. The cmux VM API Worker owns the network policy, devices, tunnels and firewall rules; `TeamDO` pushes the compiled peer map to hosts (amended 2026-10-07). We run no relay or STUN servers.
5. Freestyle is the cloud region path and its ACL. One Freestyle tunnel and one WireGuard key per (device, team mesh), created with our public key (`clientPublicKey`) and attached to that team's VPC only (amended 2026-10-07, section 7). The reconciler in the cmux VM API Worker compiles the team policy into Freestyle firewall rules (imperative create and delete; measured effect within 0.25 s) and into each host's peer map.
6. The private key never leaves the device. The WireGuard private key is made on the device and stays in the Keychain (`ThisDeviceOnly`, not synced) or a 0600 file. Freestyle, the cmux VM API Worker and `TeamDO` see only the public key (verified: Freestyle never minted a key when given `clientPublicKey`).
7. The network never grants application authority. Every link starts with `hello {token}` (a short-lived ES256 token from `UserDO`); the owner checks the principal and grant. WireGuard keys and firewall rules decide reachability only.
8. iOS runs WireGuard inside the app process (no Network Extension, no VPN prompt, no VPN slot). A packet tunnel is a later, optional mode for system-wide access.
9. T2: the app's own session is the local Unix socket (no network). Opening a window or workspace on another session dials that session's host through the overlay and hands the app a local socket, as `remote connect` does today.
10. The in-process WireGuard stack must be fixed before it carries cmux-next traffic: today it cannot upload more than about 1 MiB through the Freestyle tunnel (section 13.2, section 16).

## 1. What the network must carry

| Class | Examples | Size and rate | What matters |
| --- | --- | --- | --- |
| Interactive | keystrokes, terminal output, presence, focus | 10 to 500 B; bursts of a few KB | RTT, jitter, no head-of-line stalls behind bulk |
| Redraw | attach snapshot, scroll back, resize replay | 10 KB to a few MB at once | time to the first full frame |
| Bulk | file transfer, image paste, artifacts, remote-localhost streams, remote view frames | MB to GB | throughput; must not hurt interactive |
| Control | ops, events, directory, peer map, rendezvous | small | reliable, ordered per stream (sync-and-transport.md) |

Control for cloud-owned streams (`UserDO`, `TeamDO`, `DocDO` and the other DOs) stays on the client's WebSocket to `UserDO` (sync-and-transport.md section 5). This document covers everything that reaches a machine: terminals, session host, a device-homed workspace store, acpmux, browser host, CUA host, loopback streams, SSH to VMs.

### 1.1 Targets

| Metric | Target | Basis |
| --- | --- | --- |
| Keystroke echo, direct or VPC path | p50 <= network RTT + 3 ms | measured overlay overhead: tunnel 2.18 ms p50 vs about 1 ms raw in one metro |
| Keystroke echo through the DO relay, same metro | p50 <= 10 ms, p99 <= 20 ms | measured 7.8 ms p50 / 14.2 ms p99 with the object in the host's colo |
| Path badge | shown on interactive surfaces above 50 ms RTT and on every relayed path | sync-and-transport.md 6.5 |
| First full frame after attach (200x60 terminal) | <= 1 RTT + 20 ms | snapshot is about 30 to 80 KB |
| Bulk throughput | >= 200 Mbit/s direct or VPC, >= 40 Mbit/s DO relay; bulk never raises interactive p99 by more than 10 ms | measured 228 Mbit/s VPC download (userspace), 5 MB/s relay unbatched, 21 MB/s batched |
| Cold dial (peer map cached) to first byte | p50 <= 150 ms on the VPC path; <= 300 ms when only the relay works | measured 142 ms tunnel cold start; relay socket open 66 ms warm, 261 ms cold object |
| Path upgrade relay to direct | <= 2 s after the dial | punch measured at about 1 RTT after candidates arrive |
| Network change (Wi-Fi to cellular) | traffic flows on the relay <= 500 ms after the new interface is up; direct path back <= 1 s | relay reconnect 74 ms p50; re-STUN 8 ms + rendezvous 17 ms + punch 6 ms (section 13.3) |
| Wake from sleep | <= 1 s to first byte | one handshake; today's stack takes 5.15 s after a 190 s sleep (a defect, section 16) |
| Revocation | no new or existing traffic <= 1 s after the revoke op commits | measured Freestyle rule and tunnel delete: blocked within 0.25 s, open connections included |
| Idle cost | 0 wakeups on an idle device; a host keeps one hibernating WebSocket | measured $0.0000002 per host-day hibernated |

## 2. First principles

- A link needs reachability, confidentiality and identity. The principal (user, agent, grant) is an application fact and belongs in the link `hello`. Machine identity and confidentiality belong to one session between the two machines. Reachability is a path problem and must not change the session.
- If the session is end-to-end, every path can be dumb. Then the DO relay, the Freestyle gateway and the direct UDP path carry the same datagrams, and the selector can move between them freely. This is why the overlay runs end-to-end WireGuard even through the Freestyle VPC: WireGuard inside WireGuard on that path costs 80 bytes of MTU and a second ChaCha20 pass, which is small next to the RTT, and it gives VMs the same session as every other host (so a VM link can move to the DO relay when the tunnel fails).
- One UDP socket per endpoint carries everything: end-to-end sessions, the Freestyle tunnel session and STUN. NAT mappings learned for one are valid for all.
- The control plane already exists: the cmux VM API Worker knows every device, tunnel and policy, `TeamDO` knows every install and host and pushes peer maps; each host keeps one hibernating WebSocket to its `HostDO`. Rendezvous and relay are two more frame kinds on sockets we already need.
- What we do not build: relay servers, STUN servers, a system VPN, a kernel interface, port prediction for hard NATs. Durable Objects, Cloudflare STUN, the in-process stack and the relay replace each.

## 3. Components

| Component | Where | Owns |
| --- | --- | --- |
| Overlay endpoint (`cmux-transport` core plus the `cmux-wg` engine) | Rust, in the `cmux link` process on Macs and Linux, in the daemon on Cloud VMs and team VMs, in the iOS app through the client xcframework | the WireGuard key handle, one UDP socket, one WireGuard session per peer (boringtun), the Freestyle gateway session, the in-process TCP/IP stack (smoltcp), the path selector, STUN, the relay client |
| cmux VM API Worker | `workers/cmux-vm` (amended 2026-10-07) | the network policy versions (spec/network-policy.md), meshes, devices with their WireGuard public keys, Freestyle tunnel and rule records, the compiled reachability per host; one `MeshDO` per mesh is the single writer of compile and apply (workers/cmux-vm/mesh/DESIGN.md) |
| `TeamDO` | API Worker | the peer map push to hosts: install id, host id, WireGuard public key, overlay address, VPC address, tags and compiled reachability, read from the cmux VM API; no policy, tunnel or rule records |
| `UserDO` | API Worker | install keys and revocation; link tokens; relay tickets |
| `HostDO` | API Worker, one per host | the host's hibernating link socket; rendezvous (candidates of the host and of dialing clients); the datagram relay for that host; host presence (online, offline, paused) |
| Reconciler | `MeshDO` in the cmux VM API Worker | Freestyle tunnels, attachments and firewall rules; each step has an idempotency key and a recorded result |
| Freestyle | platform | team VPCs, one tunnel gateway (San Francisco today), firewall enforcement for the VPC path |

On a Mac the `cmux link` process (launchd, one per user) owns the endpoint, because one WireGuard key supports one live session with the Freestyle gateway: the app, the CLI and every `remote connect` sidecar dial through it (the existing `wg hub` SOCKS-over-Unix pattern, extended to overlay peers). The daemon stays free of network code (OWNERSHIP-PRINCIPLES: the session host owns PTYs, not transport).

### 3.1 Overlay addressing

Each install and host gets one overlay IPv6 address: `fd7c:6d78::/32` plus 96 bits of SHA-256 of its install or host id. It is stable across key rotation, unique without allocation, and exists only inside our userspace stacks. A link is TCP to `[overlay address]:4100`; probes use overlay UDP 4102. Loopback forwards (remote-localhost.md) stay streams inside the link. The inner MTU is 1200 when the session rides the Freestyle tunnel (tunnel MTU 1280, measured) and 1380 otherwise; the engine uses the smaller value for a session that may use both.

## 4. Paths and selection

| Path | Exists when | Carrier | Label |
| --- | --- | --- | --- |
| `local` | same machine | Unix socket, no overlay | none |
| `direct_lan` | a same-subnet candidate answers a probe | UDP | "direct" |
| `direct_wan` | a global IPv6 candidate or a punched IPv4 mapping answers | UDP | "direct" |
| `via_cloud_region` | the host is a member of a team VPC and the device's tunnel attaches that VPC | inner datagrams as UDP to the host's VPC address through the Freestyle tunnel | "via cloud region" |
| `do_relay` | always where HTTPS works | batched binary WebSocket frames through the host's `HostDO` | "relayed" |

Dial (client to host):
1. Look up the host in the cached peer map (public key, overlay address, VPC address, last candidates). If the host is a paused VM, `TeamVmDO.ensure_awake` first (Freestyle resume measured at about 100 ms).
2. At t = 0, in parallel: send the WireGuard handshake initiation to the VPC address (VPC hosts) or to every direct candidate (other hosts), and open the relay WebSocket to the host's `HostDO` with this client's fresh candidates and the same initiation.
3. The host answers on the path that reached it first; the client starts the link there. `HostDO` forwards the client's candidates to the host, so both sides probe each other's candidates at the same time, which opens NAT mappings in both directions.
4. Probes are tiny overlay UDP packets inside the session (authenticated by WireGuard, no second key), sent on one path and answered on the path they arrived on; each answer is that path's RTT.
5. The selector (`cmux_transport::Selector`) ranks any live direct path above every relay; inside a class the lower smoothed RTT wins, but only after the challenger beat the current path by max(3 ms, 10 %) on three answers in a row. A switch only changes where the next datagram goes: no reconnect, no resent data.
6. While the link carries traffic, the endpoint probes the current path every 5 s and keeps direct paths alive with one datagram every 10 s (measured NAT idle limits are 16 to 30 s, section 13.3); other paths are probed every 30 s. An idle link sends nothing; its NAT mappings lapse and the next use repeats step 2 on the warm session (no new handshake while keys are fresh). These are network keepalives with a reviewed `wakeup-allow` reason and stop when the link is idle.

Downgrade: a path that loses three probes in a row is dead (about 15 s at the 5 s cadence, so a send error or an expected answer that does not arrive within 2 s also counts as a loss); traffic moves to the next live path at once; with no live path the endpoint sends on every path until one answers. A local network change, and the first send after the link was idle long enough for NAT mappings to lapse (more than 15 s), send every path back to probing (direct mappings changed, the relay WebSocket died with the old interface, and the tunnel gateway learns the new source only from the next datagram), so the endpoint sends on every path until the first answers. The property tests in `cmux-transport` check these rules (section 15).

When DO and when direct WireGuard, in one rule: direct WireGuard whenever a direct probe answers; the Freestyle tunnel for VPC hosts; the DO relay while nothing else answers yet, when UDP is blocked, when the NATs on both sides map per destination, for web clients, and when it measures faster than the VPC path (it rarely does: 7.8 ms vs 2.2 ms in one metro).

## 5. Endpoint discovery and NAT traversal

- Candidates: same-subnet addresses with the endpoint's UDP port, global IPv6 addresses, the reflexive IPv4 address from STUN (`stun.cloudflare.com:3478`, sent from the same UDP socket; the classifier tells STUN from WireGuard by the magic cookie and exact length), a port-preservation guess (reflexive IP with the local port, which raised the success rate on a per-destination NAT), and the VPC address for VPC hosts.
- NAT type: an endpoint classifies its own mapping from four or more STUN destinations including two ports on one IP (a two-server check misclassified the office NAT as endpoint-independent). It sends the class with its candidates so the peer knows whether to expect a direct path.
- Publication: a host sends its candidates to its `HostDO` on start and on every network change; a client sends its candidates inside the dial. Nothing is polled.
- Punching: both ends probe all of the other's candidates every 100 ms for up to 3 s after the rendezvous. Measured: a punch completes about 1 RTT after both sides have candidates (6 to 7 ms in one metro); when one side starts late, it completes 5 to 110 ms after the late side starts.
- Hard NATs: when both NATs map per destination, or one maps per destination and the other filters per port, a direct path often fails (47 % success office to cloud, section 13.3). The link stays on the relay. NAT-PMP/PCP mapping on home routers is a later improvement (the home router granted a mapping but inbound traffic did not arrive; cause not found).
- LAN: same-subnet candidates are tried first; on iOS and for app-spawned helpers on macOS the Local Network prompt appears only when the user opens a session whose host was seen on the same LAN.

## 6. The DO relay (`HostDO`)

- One `HostDO` per host. The host keeps one WebSocket to it with the hibernation API; pings are answered by the auto-response, so an idle host costs nothing (measured: the object is evicted after 30 s idle and wakes for the first message in 15.5 ms p50).
- Frames (`cmux_transport::relay_frame`, golden vectors in `tests/vectors/relay-frames.json`): `[u8 version=1][u8 kind][16-byte peer id][payload <= 16 KiB]`, one frame per binary message. The relay rewrites `peer` in a client's frame to the client's authenticated install; it never trusts the client's value. Kinds: `datagrams` (one or more `[u16 length][datagram]` records), `candidates`, `wake`. A sender packs every ready datagram into one frame: one object passes about 4,000 incoming messages per second (5 MB/s at WireGuard size, 21 MB/s with 16 KiB messages, measured), and batching also cuts request billing about 12 times.
- The object forwards datagrams between the host socket and the addressed client socket and cannot read them. It writes nothing to storage on the datagram path.
- Admission: a client's frames are forwarded only if its install is in the host's compiled reachability from `TeamDO`, so the relay is not an open pipe; WireGuard on the host still drops unknown keys.
- Placement: Cloudflare places a new object near its first caller but not always in the nearest colo (from SJC: 7 of 14 in SJC, 7 in LAX; a LAX object makes the relay 24.5 ms instead of 7.8 ms; `locationHint` cannot pin a colo). So the host picks its relay object at enrollment: it creates up to four candidate names `host:<id>:<n>`, measures each object's echo RTT, keeps the fastest, and records the name in `TeamDO`. Cloud VMs do the same from the VM. The relay sits near the host; a far client pays only the triangle (measured: sjc client to fra host 161 ms through the relay vs 138 ms direct).
- Limits: past about 40 Mbit/s of relayed traffic for one host (unbatched) or 170 Mbit/s (batched), the host splits clients across two relay objects; the frame format already names the peer, so a split needs no protocol change.
- Cost (Cloudflare pricing read 2026-10-02): an interactive terminal hour is $0.0013 to $0.0067, 1 GB batched about $0.0005, an idle host $0.0000002 per day. The included 1 M requests per month cover about 20 M relayed messages.

## 7. Freestyle: tunnels, VPCs and firewall

Measured facts (Freestyle v5, 2026-10-02, section 13.2):
- A tunnel created with `clientPublicKey` never gets a platform-minted key. Its config is fixed; VPCs are attached and detached. Every tunnel today uses one endpoint, `208.72.218.30:51820` in San Francisco, for clients in every region; the tunnel MTU is 1280.
- `rotate-key` keeps the tunnel id and addresses but also changes the server public key; the client must take the new `[Peer]` key from the response. The old key works for about 2.8 s after the call.
- Firewall rules are allow-only matchers (`vmId`, `vpcId`, `tunnelId`, `cidr`, `port`, `protocol`). With no rule, traffic is dropped silently (no reset). A new rule works 0 to 250 ms after the API returns; a deleted rule or tunnel blocks new and open connections within about 0.25 s. Rules that name a tunnel, VM or VPC are deleted with it.
- Two tunnels in one VPC cannot reach each other even with an allow rule (`/v5/firewall/evaluate` says allowed; no packet arrives). A VM in the VPC can relay (measured +2.6 ms).
- Attached networks on one tunnel must not overlap, so team VPCs use cmux-allocated CIDRs (or IPv6-only attachments). Amended 2026-10-07: tunnels are per (device, mesh), so one tunnel attaches only its own team's VPC (Model below).

Model:
- Amended 2026-10-07 (coordinator; workers/cmux-vm/mesh/DESIGN.md sections 3 and 8): one tunnel and one WireGuard key per (device, team mesh). A device install (the `cmux link` on a Mac or Linux device, the iOS app install) that joins a team mesh makes a key for that mesh and enrolls through the cmux VM API (`POST /v1/meshes/{meshId}/devices`); the Worker creates the tunnel with that public key, attached to that team's VPC only, with routes limited to the mesh CIDRs. A user in three teams has three keys and three tunnels, each owned by one tenant, revoked and budgeted per tenant; `cmux link` holds one gateway session per tunnel (`WgMesh::add_gateway`). This replaces the earlier "one key, one tunnel, three attachments".
- Owner (amended 2026-10-07): the cmux VM API Worker owns the network policy, devices, tunnels and firewall rules (versions in Postgres, one `MeshDO` per mesh as the single writer of compile and apply). `TeamDO` calls the cmux VM API for them and keeps only the peer-map push to hosts.
- Cloud VMs, team VMs and cmux servers hosted in the VPC are members (no tunnel). Their overlay endpoint listens on UDP 4101 on the VPC address.
- Compiled firewall rules per team VPC: `allow {tunnelId: T} -> {vmId: V, protocol: udp, port: 4101}` for each (device, VM) pair the policy allows, plus the VM egress rules of spec/agent-egress.md. The host's peer map carries the same pairs, so the policy is enforced twice.
- The reconciler (in the cmux VM API Worker) runs on policy change, membership change, device join or revoke, and VM create or delete. Each Freestyle call carries an idempotency key; after each batch it re-reads effective rules and alerts on drift. A silent drop means a missing rule shows up as a dial timeout, so `cmux network status` reports "no rule" from the compiled view (read through the cmux VM API) instead of waiting for it.
- Device-to-device traffic never crosses the VPC; the `HostDO` relay forwards end-to-end-encrypted WireGuard packets and sees only outer addresses and sizes (section 9.1).

## 8. Keys

| Key | Algorithm | Made where | Stored | Leaves the device? | Used for |
| --- | --- | --- | --- | --- | --- |
| Install identity key | P-256 | device | Secure Enclave on Apple; 0600 file on Linux | never (Secure Enclave keys cannot) | signs enrollment, token refresh and the cmux VM API device enroll and rotate calls |
| WireGuard key | X25519 | device | Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synced; 0600 file on Linux and VMs | never; only the public key goes to the cmux VM API Worker, `TeamDO` peer maps and Freestyle; one key per (device, team mesh) | every overlay session and the Freestyle tunnel |
| Link token | ES256 JWT, minutes | `UserDO` | memory | sent to the host in `hello` | principal and grant |
| Relay ticket | ES256 JWT, minutes | `UserDO` | memory | sent to `HostDO` | relay admission |

Secure Enclave keys are P-256 only, so the WireGuard key cannot live there. It is a Keychain item that is never exported, never synced and never logged.

Minting: the first sign-in on a device makes both keys, registers the identity key (identity spec), then, for each team mesh it joins, makes a WireGuard key and calls the cmux VM API `POST /v1/meshes/{meshId}/devices {wgPublicKey, installPublicKey, signature}`. The Worker checks the signature, membership and budgets, records the key, creates that mesh's tunnel with `clientPublicKey` attached to that team's VPC, and applies the device's firewall rules. `TeamDO` then pushes a peer map delta to hosts.

Rotation: every 90 days and on demand (cmux VM API `POST /v1/devices/{deviceId}/rotate-key`, per tunnel). The device makes a new key; the cmux VM API Worker calls Freestyle `rotate-key` with the new public key and returns the new server public key to the device; `TeamDO` pushes the new key to peers in a peer map delta. Sessions re-handshake once. The old key is deleted on the device after the push is acknowledged.

Revocation and device loss: cmux VM API `DELETE /v1/devices/{deviceId}` (by the user from any signed-in device or the dashboard, by an admin, or caused by install revocation or team removal; team removal revokes at once on the Stack team-membership webhook or token refresh, with a 60 s sweep only in the experiment) makes the cmux VM API Worker delete that mesh's Freestyle tunnel (its rules go with it; measured effect within 0.25 s); `TeamDO` removes the key from every peer map (hosts drop the peer and its sessions at once), refuses relay tickets, and lets tokens expire (minutes). A lost device keeps its key, but nothing accepts it.

## 9. Authorization and ACL enforcement points

| Point | Checks | Compiled from |
| --- | --- | --- |
| Freestyle firewall | which tunnel may send to which VM on the VPC path | team policy |
| Host peer map | which WireGuard keys may complete a handshake with this host, on every path | team policy and directory |
| `HostDO` admission | which installs may relay to this host | same |
| Link `hello` | which principal (user, agent, grant) opens the link; the owner checks every op | identity spec |

A key in the peer map gives reachability only. A link with no valid token is closed after `hello`.

### 9.1 Relay security analysis (skills/cmux-socket-policy relay rules)

The overlay adds no socket method and no command path; it carries the existing link. The relay rules still apply to the `HostDO` relay because it forwards traffic toward a machine:
- Local command or content execution: the relay forwards WireGuard datagrams it cannot decrypt. A datagram that does not complete a handshake with a key in the host's peer map is dropped by the host before any byte reaches the daemon. Every remote method stays behind the link `hello` and the owner's per-op checks, which default to deny.
- Access to unowned objects: relay admission is per (client install, host) from `TeamDO`; frames name a peer, and the object forwards only to the socket bound to that peer. A client cannot address another client.
- Local-state exposure: the relay sees sizes, timing and peer ids, never content. The host learns a client's candidate addresses and the client learns the host's; candidates are shared only between peers the policy lets talk.
- Abuse: tickets expire in minutes; per-client message and byte budgets close a socket that floods; a host can drop a peer at once.

## 10. Roaming, reconnect, sleep and wake

- Network change (NWPathMonitor on Apple, netlink on Linux): rebind the UDP socket, re-run STUN, publish candidates to `HostDO`, reopen the relay WebSocket if it died, and probe every path. Measured: following the source of the latest authenticated datagram, as WireGuard does, recovered 0 of 8 rebinds when the other side was behind a port-filtering NAT, because the new source never got through. Re-rendezvous plus a new punch recovered 6 of 6 in about 6 ms after new candidates (plus about 8 ms STUN and the rendezvous RTT). So roaming always goes through the rendezvous; the relay carries traffic in the meantime. TCP streams inside the overlay keep their state; the link does not reconnect.
- Sleep and wake: WireGuard session keys expire after 180 s; after a longer sleep the first datagram must start one handshake at once (today's stack waited 5.15 s and closed its streams, a defect). The host keeps a link's TCP state for 10 minutes (today 60 s), and past that the link reconnects and resumes from `last_seq` (sync-and-transport.md 3.3).
- Host restart: the host's key and address are stable; clients re-handshake and the link resumes from `last_seq`.
- iOS: on return to the foreground the app rebinds and sends one handshake (one RTT); while suspended it runs nothing (alert pushes with a Notification Service Extension tell the user about host events).

## 11. Platforms

| Platform | Endpoint | Notes |
| --- | --- | --- |
| macOS app | `cmux link` (launchd agent) owns the endpoint; app and CLI dial through its Unix socket | no root, no system extension, no VPN prompt; the overlay reaches only cmux processes; SSH to team VMs through `cmux team ssh` (ProxyCommand into the link); a packet-tunnel system extension stays an opt-in for system-wide access (the Developer ID entitlement exists) |
| iOS app | in-process endpoint in the client xcframework | foreground and short background only; no VPN slot, so it coexists with any VPN the user runs; Local Network prompt only for same-LAN hosts; the in-app browser can reach VPC ports through an in-process proxy (`ProxyConfiguration`, iOS 17) |
| Linux client | `cmux link` (systemd user unit) | same as macOS |
| cmux server, team VM, Cloud VM | daemon endpoint; VPC members listen on their VPC address UDP 4101 | userspace by default; kernel WireGuard on root-capable VMs only if measured bulk throughput needs it |
| Web dashboard | no WireGuard in browsers; `HostDO` application relay (sync-and-transport.md section 5) | the only path that is not end-to-end |

iOS trade-offs: a packet tunnel would keep a tunnel up while the cmux app is suspended (the app itself would still be suspended, so terminals would not run) and give Safari and other apps the VPC. It costs the single VPN slot (it stops a mesh or corporate VPN the user runs), adds the "Add VPN Configurations" prompt and App Review 5.4 duties, runs in a 50 MiB extension, and needs the key shared with a second process. In-app is the default; the gap it leaves (other apps cannot reach VPC ports) is closed later by an opt-in tunnel if users ask.

## 12. T2: own session and other sessions

- The app connects to its own cmux-tui session on the local Unix socket by default, with every capability. No overlay is involved.
- "Open window/workspace on session X": the app asks `owner_for(session X)` (data-model.md); the session registry holds X's host id. The app asks `cmux link` to dial that host; the link returns a local Unix socket that speaks the daemon protocol (as `remote connect` does today), and the window or workspace binds to that session. Capabilities that the host's policy refuses are disabled with the reason.
- iOS has no local session: every session is remote; the phone opens the user's chosen default session.

## 12a. What the overlay offers to local processes

`cmux link` is the only process that holds the WireGuard key on a machine. Local processes of the same user (the app, the CLI, `remote connect` sidecars, the macOS screen agent helper, acpmux) use the overlay through the link's Unix sockets in a user-only directory (0600); the link checks peer credentials (same uid) and, on macOS, the caller's code signature (cmux team id) before it opens a stream or a datagram port. No second process needs or receives the key, so the screen agent helper does not get its own key (remote-desktop.md 19, question 5).

| Service | Shape | Used by |
| --- | --- | --- |
| Interactive stream | one overlay TCP connection per link: control frames and `terminal_bytes` channels, Nagle off | session host, workspace store, acpmux (cmux.wire/1) |
| Bulk stream | a second overlay TCP connection in the same WireGuard session: snapshots, history pages, files, loopback forwards | ghostty-next snapshot channel, file transfer, remote-localhost |
| Datagrams | unreliable overlay UDP to a registered port on the peer; `cmux link` exposes a Unix datagram socket per local service; payload up to the link's `max_datagram` | remote desktop media (port 4103) |
| Path events | subscription on the link socket: `path.changed {peer, path, rtt_ms, jitter_ms, loss_pct, max_datagram}` on every switch, plus the same fields every 5 s while the link carries traffic | path badge in the terminal view, remote desktop congestion control |

Scheduling inside one session, strict priority: interactive datagrams and connections with a small flight (control and terminal bytes) first, then media datagrams, then bulk. Every TCP connection is paced at twice its flight per RTT with a 10-segment floor, so interactive connections are never slowed and a bulk stream cannot burst when its queue runs short (decision TR1, landed 4bbaba274a9). Each datagram class is bounded at 512 queued datagrams and never blocks TCP. Media datagrams older than 50 ms in the send queue are dropped (oldest first): media is unreliable by design and must never queue behind a stall. Streams never drop: a full send queue backpressures the writer (TCP window and the app's credit).

Terminal channels (ghostty-next.md sections 2 and 11): live output is an ordered byte stream per terminal on the interactive connection, bounded by the per-viewer credit (`terminal.viewerBacklogBytes`, 256 KiB), so one flooding terminal cannot hold more than its credit in the interactive connection and cannot delay another terminal's echo by more than that backlog. Snapshots and history pages go on the bulk connection. Each frame carries `generation` and `offset`, so a snapshot that arrives on the bulk connection ahead of or behind live bytes is ordered by the viewer (bytes below the snapshot offset are discarded). The `behind` resync is a session host decision on its own credit, not a transport drop. The terminal view reads the path badge and RTT from the path events above.

Inner MTU and `max_datagram`: one session uses one MTU, the smallest over the paths it may take, so a path switch never changes it: 1200 when the host is a VPC member (the Freestyle tunnel MTU is 1280, minus IPv6, UDP and WireGuard headers), else 1380 (room for one more encapsulation on common paths). `max_datagram` is the inner MTU minus 48 bytes (IPv6 and UDP headers): 1152 or 1332. The device tunnel itself (the `wg hub` session, whose WireGuard peer is the Freestyle gateway) uses the tunnel's own MTU, 1280, so its datagram service reports `max_datagram` 1232 (measured, round 4, 2026-10-03); only a session nested inside that tunnel uses 1200 and 1152. The DO relay carries any size up to its 16 KiB frame, and frames batch several datagrams (landed in `cmux-transport`), so the relay is not the limit.

Ports and policy: a host's overlay endpoint accepts only registered ports: 4100 (link), 4101 (WireGuard on VPC members, outer), 4102 (probes, inside the session), and ports that a local service registers with `cmux link` under a catalog service name (`remote-desktop` on 4103). Everything else is dropped. The network policy names services, not raw ports, for overlay destinations (`tag:desktop:remote-desktop`); the compiler maps service names to ports for host peer maps and to Freestyle firewall rules for VPC members. A peer allowed to reach a host therefore reaches only the services the policy names.

In-process TCP defaults (`cmux-wg`): Nagle off; keepalive probe after 15 s idle; link connections use a 10-minute user timeout (60 s today, being raised); a FIN lost on close is a known bug from the remote desktop prototype, with a regression test in the engine round.

### 12b. Answers to lanes 13 and 17 (round 3)

- Port numbers: overlay UDP 4102 is taken by path probes inside the session. Remote desktop media, input, cursor and feedback datagrams use 4103 (service name `remote-desktop`). remote-desktop.md section 6 and its policy example (`autogroup:self:4102`) should move to 4103 and to the service name (`autogroup:self:remote-desktop`).
- Datagram payload: `max_datagram` is 1232 bytes on the device tunnel's hub (MTU 1280, what a VPC member's remote desktop gets through `wg hub` today), 1152 bytes for an end-to-end session nested in the Freestyle path, and 1332 bytes otherwise, fixed for the session's life and reported in every `path.changed` event. remote-desktop.md's estimates (about 1150 and about 1350) match within the headers.
- Relay batching is landed (`cmux_transport::relay_frame`, kind `datagrams`, up to 16 KiB of length-prefixed datagrams per message): one relay message carries about 14 media datagrams, so the per-object ceiling of about 4,000 messages per second is no longer the video limit; the relay's byte rate (21 MB/s measured with 16 KiB messages) is. remote-desktop.md section 6.6 ("one WireGuard datagram per message") is out of date.
- Session close: a lost FIN on a stream close is resent by TCP (end seen after 3.02 s in the engine test); a close lost at tunnel shutdown is now resent after shutdown (end seen after 410 ms instead of 60 s). Landed in 99ca23d8102.
- Terminal frame fields (`kind` snapshot or bytes, `generation`, `offset`), per-viewer credit and `presence.set {visible, counts}` are `cmux.wire/1` channel and presence fields (sync-and-transport.md sections 3 and 4). The overlay carries those frames unchanged and adds nothing to them; the spec owner adds the fields there. The overlay's part is section 12a: the interactive and bulk connections, no drops, and path events for the badge and RTT.
- First connect on a long-idle Freestyle tunnel: the engine forces one new handshake when a fresh session gets no answer within max(1 s, 2x RTT) (round 3), so a remote desktop or terminal attach after idle waits about 1 s, not 15 s.

### 12c. Answers to lane 3 (Finder over hosts, plans/cmux-next/finder.md 3.5)

1. Plain SSH hosts: yes, as a second connection kind in `cmux link`, outside the overlay (a plain SSH host has no WireGuard endpoint). The link runs the system OpenSSH client with the existing validated argv builder (`cmux-remote` `ssh_args.rs`), the user's SSH config and agent, and a link-owned known-hosts file (`StrictHostKeyChecking yes`; the host-owned sheet writes a confirmed key into it before the first connect; the user's `~/.ssh/known_hosts` is read-only input). SFTP v3 runs over `ssh -s sftp` stdio with a small Rust SFTP client in the link. A host reached only through a cmux host (a machine on a team VM's network) uses that host as the jump: the SSH TCP stream rides the overlay to the cmux host and leaves it as a loopback-forward style stream (remote-localhost.md 4), so no new listener appears anywhere.
2. Host-to-host copy without the Mac: yes for two cmux endpoints. The destination's `cmux link` dials the source host over the overlay (hosts are overlay peers; the same path ladder applies) under a job grant that `UserDO` mints for `(job, source conn, read-only, expiry)`; bytes never pass through the Mac. The peer map must allow the pair (`autogroup:self` covers a user's own hosts). This is a narrow exception to "daemons never connect to each other" (data-model.md, sync-and-transport.md non-goals): only `cmux link` dials, only bulk byte channels for a job, never state or ops federation. DECISION for the coordinator: accept this exception (RECOMMEND yes: a 4 GB copy between two VMs through a phone or a laptop on hotel Wi-Fi is the alternative). When the source is a plain SSH host, the Mac's link relays, as finder.md says.
3. Bulk class: yes. Bulk channels ride the bulk connection (12a) with credit-based backpressure and never drop. Cancel is per channel: `channel.close {channel}` (sync-and-transport.md 3.1) makes the sender stop at once and discard its queued bytes; at most one credit window (default 4 MiB for files) is still in flight and the receiver discards it. Closing the bulk connection itself is never needed to cancel one job.
4. `conn_…` owner: `cmux link` on that machine, single writer. It holds what a connection is (target, credential reference, host key state, path state) and issues, lists and revokes `conn_…` per (user, app). The app supervisor only holds handles and forwards intents with them; `host.watch` events come from the link's path events (12a).
5. Team VM SSH certificate: yes, automatic. The link makes an Ed25519 SSH key per install (Keychain or 0600 file, never exported), asks `TeamDO` (`team_vm.ssh_cert`, spec team-vm.md) with its install token when a connection needs it, keeps the 15 to 60 minute certificate in memory and renews it before expiry. The connect sheet has no credential step for team VMs; the policy decides which Linux user the certificate names.

## 13. Measurements (2026-10-02)

The local development Mac had a load of about 800 on 18 cores, so no timing was taken from it. Ends were Fly.io machines (shared-cpu-1x, 256 MB, sjc unless named), a Freestyle VM (`freestyle/ubuntu-sm`, San Francisco) and a lightly loaded fleet Mac mini behind the office NAT. Raw files and scripts are in the lane's private scratch directory.

### 13.1 Summary

| Path, same metro unless named | RTT p50 / p99 (64 B, n=1000) | Throughput | Setup |
| --- | --- | --- | --- |
| Direct UDP, two cloud machines (baseline) | 1.05 / 2.27 ms | n/a | none |
| Punched UDP, office Mac mini to cloud (two NATs) | 5.58 / 6.91 ms | n/a | punch about 1 RTT after candidates |
| Freestyle tunnel, cloud client to VM, in-process stack | 2.18 / 2.51 ms | 228 Mbit/s down; upload fails above 1 MiB (defect) | 142 ms cold, 2.7 ms new TCP connection on a warm session |
| Freestyle tunnel, kernel WireGuard (reference) | 2.29 / 2.63 ms | 425 up / 227 down Mbit/s | 145 ms |
| Tunnel to VM relay to second tunnel | 4.80 / 5.48 ms | n/a | 7.3 ms new connection |
| DO relay, object in the host's colo (SJC) | 7.82 / 14.16 ms | 5 MB/s at 1,280 B messages; 21 MB/s at 16 KiB | 66 ms socket open (warm object), 261 ms (new object) |
| DO relay, object in a neighbor colo (LAX) | 24.5 / 28.0 ms | same | same |
| Far host: sjc client to fra host, direct | 138.2 / 150.0 ms | n/a | none |
| Far host through the DO relay | 161 to 163 / 171 to 173 ms | n/a | same |

### 13.2 Freestyle

| Item | Value |
| --- | --- |
| Tunnel endpoint | one address for all tunnels and client regions, San Francisco; no ICMP |
| API p50 (from the loaded Mac, indicative) | VPC create 164 ms, VM create 450 ms (running 497 ms), tunnel create 397 ms (with inline VPC 136 to 171 ms), attach 233 ms, rule create 172 ms (n=16, max 1,356), rule delete 132 ms, tunnel delete 247 ms, rotate-key 96 ms |
| New rule to first good connection | 185 ms p50, 244 ms max (n=6) |
| Rule delete to blocked (new and open connections) | 196 ms p50, 257 ms max (n=5) |
| Tunnel delete to blocked | about 220 ms new, about 0 ms open (n=1) |
| Rotate-key to old key blocked | about 2.8 s (n=1); new server public key required |
| Tunnel to tunnel | not forwarded, even with an allow rule |
| No rule | silent drop (timeout, no reset) |
| Kill and restart the in-process hub (new UDP port, like a NAT rebinding) | first echo 142 ms |
| Hub paused 190 s (past the 180 s session lifetime) | open stream closed; next connection 5.15 s |
| VM egress | IPv4 through NAT and native IPv6 |
| One outlier | the first connection on one new tunnel took 15.3 s (cause unknown; a second fresh tunnel took 145 ms) |

### 13.3 NAT traversal

| Item | Value |
| --- | --- |
| Home router (one residential network) | endpoint-independent mapping, port preserved; UPnP, NAT-PMP and PCP answer; IPv4 only |
| Office NAT (fleet mini) | per-destination mapping, local port kept about half the time; per-port filtering |
| Cloud egress NAT (Fly) | endpoint-independent mapping, port preserved; per-port filtering |
| Punch success | home to cloud 26/26; office to cloud sjc 64/135 (47 %); office to cloud fra 6/8 |
| Punch time, both sides start together | 6.3 to 7.1 ms in one metro (one 106 ms run lost a 100 ms tick); 150 to 262 ms to fra |
| Punched path RTT | office to sjc 5.58 / 6.91 ms, 0/1000 lost; office to fra 153.2 / 166.9 ms, 1.4 % lost |
| Roaming by source following only | 0/8 recovered in 5 s |
| Roaming by re-STUN + rendezvous + punch | 6/6 recovered; punch about 6 ms after new candidates |
| NAT idle limits | home 25 to 30 s; office to cloud breaks at 16 to 18 s when the office sends first; office inbound holds 180 s |
| DO rendezvous (one sample) | 16.5 ms round trip after a 201 ms socket open |

### 13.4 Durable Object relay

| Item | Value |
| --- | --- |
| Echo by the object itself | SJC 3.83 / 9.24 ms; LAX 13.0 / 16.0 ms |
| Placement from an SJC edge | 7 SJC, 7 LAX of 14 with no hint; `wnam` also gave SEA, DFW, DEN; no way to pin a colo |
| First request to a new object | 246 ms p50 |
| Reconnect to first relayed message | 74 ms p50, 142 ms p99 |
| First message after 30 to 75 s idle (object hibernated and rebuilt) | 15.5 ms p50 (n=12) |
| Message ceiling per object | about 4,000 incoming messages per second; two clients share it; two objects about 7,000 |

### 13.6 Round 2 (2026-10-02 afternoon): IPv6, far regions, first-connect stalls

| Item | Value |
| --- | --- |
| Direct IPv6, cloud machine (sjc) to Freestyle VM public IPv6, UDP 64 B | 2.72 to 2.77 / 3.44 to 3.63 ms p50/p99 (n=1000 x2); tunnel path to the same VM 2.80 / 3.34 ms |
| VM public IPv6 with no firewall rule | silent drop; with an allow rule for the peer's /128 it works on the first probe |
| Cloud NAT66 to NAT66 (sjc to fra) | needs simultaneous probes (port preserved); then the first probe answers; 141.2 / 144.7 ms |
| Far device, fra, to the San Francisco VM | tunnel 146.4 / 149.6 ms (kernel), 145.7 / 150.1 ms (in-process); direct IPv6 142.3 / 146.0 ms |
| Far device, nrt | tunnel 106.3 / 107.7 ms (kernel), 111.8 / 113.9 ms (in-process); direct IPv6 105.4 / 119.1 ms |
| Far device download, single stream (fra / nrt) | tunnel kernel 14.1 / 20.6 Mbit/s; in-process 11.0 / 15.6 (bounded by the 256 KiB window); direct IPv6 43.9 / 61.6 Mbit/s |
| Far device cold start to first echo, in-process | fra 547 ms, nrt 459 to 469 ms (handshake ready at 206 ms; the ready signal moves in ~100 ms steps) |
| First connect on fresh tunnels used at once | 13 of 13 under 2 s (348 to 627 ms create to first good connection); rule to first SYN at the VM 19 to 34 ms; reused addresses behave like fresh ones |
| First connect on a never-used tunnel idle more than ~5 min | about 15 s in 5 of 6 cases (and the round 1 outlier): the handshake completes, the gateway drops the session's data, and WireGuard re-handshakes only after 15 s; a forced second handshake connects in 156 ms. Tunnels used once and then idle 12 min were fast (4 of 4) |

Consequences: the engine forces a new handshake when no authenticated packet arrives within about 1 s of sending data on a new session (instead of waiting 15 s), and this goes on the Freestyle ask list as a gateway bug with the repro. VPC hosts gain a direct IPv6 path for devices that have IPv6: same RTT as the tunnel in San Francisco, but 3 to 4 times the single-stream throughput at 100 to 150 ms RTT, where the tunnel path is slower even with kernel WireGuard (cause not known). The firewall rule for that path follows the device's current IPv6 /128 from its published candidates (rules take effect in 19 to 34 ms).

### 13.5 Cost of the measurements

Round 1: Freestyle VM about $0.11, Fly.io about $0.03; round 2: about $0.18 (Freestyle VM $0.16, Fly $0.02) (no IP addresses allocated); Cloudflare within the included plan. Every resource was created with the `cmuxnp-dev-tp-` prefix and deleted (Fly apps, Freestyle VPC, VM, three tunnels and their rules verified 404, the Worker and its Durable Object class).

## 14. Replacing iroh

| iroh use today | Replacement | Delete when |
| --- | --- | --- |
| `cmux-remote` iroh provider (`provider/iroh.rs`, feature `iroh-transport`) | `overlay` provider: a link carrier that is a TCP stream to the host's overlay address through `cmux link` | the overlay provider passes the remote conformance suite |
| iOS irx transport and the `AccountControlPlane` iroh device routes | in-app overlay endpoint plus `UserDO` tokens and `HostDO` rendezvous | the rewritten iOS app ships (IOS1) |
| `cmux-terminal-client` with `iroh-transport` | the same client with the overlay carrier (cmux-wg enabled for iOS) | same |
| Relay v2 Durable Objects (`relays/cloudflare-do`) for cmux-tui | `HostDO` datagram relay | the overlay provider ships |

The overlay provider first runs under the existing Noise link (no change above the carrier), so it ships next to the old providers. When the link moves to `cmux.wire/1` with a token `hello`, the overlay's end-to-end WireGuard session replaces the Noise layer for overlay links.

## 15. Build steps and verification

1. Done (branch feat-cmux-next-transport): `cmux-tui/crates/cmux-transport`, the pure core: datagram classifier (WireGuard, STUN), RFC 5389 binding codec (RFC 5769 vector), relay frame codec with batching and golden vectors shared with the TypeScript relay, path probes, and the path selector. Property tests (2,000 random event sequences): the current path is always alive; something is selected whenever a path is alive; a live direct path always beats relays; jitter inside the margin never switches; a challenger with fewer than three of its own winning answers never switches; a steadily faster path wins. Unit tests: a network change sends every path back to probing and the first answer carries traffic; removed path ids are never reused. Planted mutants (class rule, hysteresis margin, dead path kept, network change ignored) each fail the tests. A review subagent's findings (WireGuard data padding, streak counting, relay peer rewriting, vector coverage) are fixed.
2. Landed (99ca23d8102): the `cmux-wg` engine: an `Underlay` seam, multipath sending through the `Selector`, probes inside the session, a proof test that moves an 8 MiB TCP stream across a path switch, a cut path and a rebind with every byte intact, `rebind`/`refresh` with an immediate handshake, CUBIC, backpressure instead of drops (ENOBUFS on macOS included, retried 1 to 50 ms), per-connection pacing at twice the flight per RTT with the shortest queue first (4 MiB through a 64-packet queue: 3.37 s before, 633 ms after; a keystroke during the upload 12 ms on a 10 ms one-way path), timer ticks only after new data (about 700 wakeups per idle hour with an open connection, from 14,400), and resets resent after shutdown (peer sees the close in 410 ms, from 60 s). Next (round 3): the first-connect watchdog for the idle-tunnel stall (section 13.6), the 10-minute link TCP user timeout, the datagram service and path events (section 12a), and the peer's overlay address in `WgConfig`.
2b. Landed (b1e188d4e49): the first-connect watchdog in `cmux-wg` (`watchdog.rs`): a session that sends data and gets no authenticated answer within max(1 s, 2x RTT) forces one new handshake and resends its silent packets. Simulated: 31.05 s to 1.09 s. Real Freestyle tunnels idle 12 to 20 min: stalls 1.21 to 1.83 s (3 of 12) against 15.60 to 15.68 s with the old binary (3 of 6). Next round-3 items, in order: the 10-minute link TCP user timeout; the datagram service and path events (section 12a); the peer's overlay address in `WgConfig`; the Wi-Fi to cellular test with lane 14 (ready, waits for the phone slot); the per-device IPv6 firewall rule in the reconciler; then `HostDO` (step 3).
3. Started: the relay frame codec and the routing rules of `HostDO` as pure modules in `backend/apps/api/src/host-relay/` (`frame.ts`, `route.ts`), checked against the same golden vectors as `cmux-transport` and against the routing rules of section 9.1 (peer rewrite, reachability, offline ends, malformed frames). Next: the `HostDO` class (needs a new Durable Object migration tag from the backend lead), sockets with the hibernation API, tickets from `UserDO`, placement probing at enrollment, a review subagent before it goes live. The full step: `HostDO` rendezvous and batched datagram relay in the backend (TypeScript, the backend lead's DO base), checked against the shared vectors, with placement selection at enrollment and a load test.
4. Device enroll, rotate and revoke plus the Freestyle reconciler in the cmux VM API Worker (workers/cmux-vm/mesh/DESIGN.md); peer map push to hosts in `TeamDO`.
5. `overlay` provider in `cmux-remote` and `cmux link` dialing; the app session registry routes through it; then the iOS client.
6. Delete the iroh paths (section 14).

Verification beyond unit tests: a TLA+ model of dial, path switch, roaming and revocation (a revoked key never completes a handshake after the push; a session never sends only on paths both ends marked dead), and a benchmark on two Fly.io machines and a Freestyle VM that records section 13's table per release.

## 16. Risks and open questions

- The in-process stack has measured defects that block shipping: uploads above about 1 MiB fail through the Freestyle tunnel (no congestion control; datagrams dropped when the UDP send queue is full), a 5 s stall after sleep, a fixed 250 ms timer when idle, no rebind, and a 60 s TCP timeout that kills suspended phones' links. smoltcp also has no SACK. If the fixed stack still falls short, bulk moves to QUIC streams inside the session (one more layer) or the host side uses kernel WireGuard on VMs.
- About half of office-to-cloud pairs get no direct path; they stay on the relay (7.8 ms in one metro, 40 Mbit/s unbatched). Hole punching with many ports and router port mapping can raise the rate later.
- Freestyle has one tunnel endpoint in San Francisco: users far from it pay that round trip to reach VMs (which are in San Francisco too, so this costs nothing extra today). Ask list for Freestyle: regional endpoints, tunnel-to-tunnel forwarding (or a documented no), firewall evaluate that matches the data plane, the gateway that drops the first session's data on a never-used tunnel idle for more than ~5 min (repro in section 13.6), lower single-stream throughput through the gateway at high RTT, limits on tunnels and rules per VPC.
- TCP inside the relay WebSocket: under loss two TCP layers retransmit. Acceptable for a fallback; the selector leaves the relay as soon as UDP works.
- Durable Object placement can drift if Cloudflare moves objects; the host re-measures its relay object RTT on start and re-picks when it is more than 10 ms worse than at enrollment.
