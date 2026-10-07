# cmux mesh: design (experiment, cx-0op)

Status: design only, 2026-10-07. Decision: CMUX-MESH-EXPERIMENT M1-M5. Built inside the cmux VM API (CMUX-VM-API V1-V7, amendment 1). No code in this step.

Sources. Every claim cites one of these keys:

| Key | Source |
| --- | --- |
| `D:<id>` | `decisions.md` in the cmux-next spec (hq `worktrees/cmux-next-spec`, commit 2731416e9c6): M1-M5, V1-V7, T1, T3, T4, D3, D37/D38 |
| `TR §n` | `plans/cmux-next/transport.md` on `feat-cmux-next` (Freestyle measurements in §7 and §13) |
| `NP` | `spec/network-policy.md` in the same spec commit (`plans/cmux-next/network-policy.md` does not exist on `feat-cmux-next`) |
| `OA:<operationId>` | `workers/cmux-vm/upstream/openapi.json` on `feat-cmux-vm-s2` (a0000870), pinned 2026-10-07, sha256 c0eef41b..., 88 operations |
| `FD:<page>` | public docs `freestyle.sh/docs/vms/network/{tunnels,firewall,vpcs}` and `/vms/pricing-and-limits`, read 2026-10-07 |
| `WEB:<file>` | `web/services/vms/...` and `web/app/api/vm/...` on `feat-cmux-next` |
| `WG:<file>` | `cmux-tui/crates/cmux-wg/src/...` and `cmux-tui/crates/cmux-link/src/...` on `feat-cmux-next` |
| `UW` | `docs/cloud-userspace-wireguard.md` on `feat-cmux-next` |
| `VM:<file>` | `workers/cmux-vm/...` on `feat-cmux-vm-s2` |

## 0. Shape in one paragraph

A mesh is one Freestyle VPC per tenant (Stack team) [D:M1, D:D37]. A cmux VM joins as a VPC member; every other device (Mac, Linux server) gets its own Freestyle tunnel created with the device's public key, attached to that VPC [D:M1, TR §7]. cmux owns identity, enrollment, rotation and the ACL; the ACL compiles to pairwise Freestyle firewall rules, changed create-before-delete [D:M1, D:M3, WEB:drivers/freestyleNetworkPolicy.ts]. Freestyle does not forward tunnel to tunnel [TR §7, §13.2], so device-to-device traffic rides the end-to-end cmux overlay (LAN, punched direct, `HostDO` relay) with the same compiled ACL enforced at the receiving endpoint [D:T3, TR §4, §9]. Everything is new resources in the cmux VM API with gdp proofs and cross-tenant 404 [D:M2, D:V3-V5].

## 1. Freestyle surface

### 1.1 Operations that exist (pinned OpenAPI, v5)

| Area | Operations | Fields that matter here |
| --- | --- | --- |
| VPC | `OA:create_vpc`, `list_vpcs`, `get_vpc`, `update_vpc` (labels only), `delete_vpc` (409 while VMs are attached), `list_vpc_ips`, `list_vpc_tunnels` | `cidr` (IPv4, default a /24 from 10.0.0.0/8, fixed for life), `cidrV6` (default ULA /64), `slug`, inline `firewall.rules` |
| VM membership | `OA:update_vm_networks` (`PUT /v5/vms/{id}/networks`, declarative, live on running, stopped and paused VMs) | at most one network per VM [OA, FD:vpcs] |
| Tunnel | `OA:create_tunnel`, `list_tunnels`, `get_tunnel`, `update_tunnel` (labels only), `delete_tunnel`, `rotate_tunnel_key`, `attach_vpc_to_tunnel`, `detach_vpc_from_tunnel` | `clientPublicKey` (supplied: "the platform never sees a private key at all"), `routes` (AllowedIPs, fixed at create, default `10.0.0.0/8, fd00::/8`), `vpcs[]` inline attach (all-or-nothing), attach `ipv4`/`ipv6` pin, `exit`, `remoteCidrs`; response `tunnelId`, `serverPublicKey`, `endpointHost`, `endpointPort`, `clientConfig` (blank `PrivateKey` except on create/rotate when minted), `attachments[].ipv4/ipv6` |
| Firewall | `OA:create_firewall_rule`, `list_firewall_rules` (filter `vmId`/`vpcId`/`tunnelId`, `limit`, `offset`), `get_firewall_rule`, `delete_firewall_rule`, `evaluate_firewall` | `action` = `allow` only; `source`/`destination` matchers `{vmId, vpcId, tunnelId, cidr, public, port, protocol}`; fields intersect, rules union, no order or priority; `port` is one port and needs `protocol` (`tcp`/`udp`/`icmp`); `description` up to 1024 chars; rules naming a VM, VPC or tunnel are deleted with it [OA, FD:firewall] |

Semantics that the design depends on:
- Default deny: a VM reaches nothing and is reached by nothing without a rule; "membership is not permission" [FD:firewall, FD:vpcs]. Missing rule = silent drop, no reset [TR §7].
- "You do not need a rule to let an attached tunnel reach the network it is attached to", given a member-to-member rule exists [FD:firewall]. So the compiler never emits a VPC-wide member rule unless the policy says `*` (section 4.2).
- Always allowed: mapped domains and the SSH proxy; never filtered: ARP, ND, DHCP; always blocked: outbound TCP 25/465/587 [FD:firewall].
- Tunnel to tunnel inside one VPC is not forwarded even with an allow rule, while `evaluate_firewall` answers allowed [TR §7, §13.2]. A VM in the VPC can relay (+2.6 ms) [TR §7].
- Attached networks on one tunnel must not overlap and must fall inside `routes` (409) [OA:attach_vpc_to_tunnel].
- No batch, replace or compare-and-swap API for rules; atomicity exists only for inline rules at create [FD:firewall].

### 1.2 Measured behavior (transport lane, 2026-10-02/03)

| Item | Value | Source |
| --- | --- | --- |
| Tunnel endpoint | one address for all tunnels and client regions, `208.72.218.30:51820`, San Francisco; no ICMP | TR §7, §13.2 |
| Tunnel MTU | 1280 (docs say 1280; older configs 1200) | TR §7, FD:tunnels, UW |
| API p50 | VPC create 164 ms, tunnel create 397 ms (136-171 ms with inline VPC), attach 233 ms, rule create 172 ms (max 1,356), rule delete 132 ms, tunnel delete 247 ms, rotate-key 96 ms | TR §13.2 |
| New rule to first good connection | 185 ms p50, 244 ms max (n=6); rule to first SYN 19-34 ms (round 2) | TR §13.2, §13.6 |
| Rule delete to blocked (new and open connections) | 196 ms p50, 257 ms max (n=5) | TR §13.2 |
| Tunnel delete to blocked | ~220 ms new, ~0 ms open (n=1) | TR §13.2 |
| Rotate-key, old key still works | ~2.8 s (n=1); server public key also changes | TR §7 |
| Rule calls from the web app | ~0.5 s per call; serial policy change took 5-11 s; batches of 8 fix it | WEB:drivers/freestyleNetworkPolicy.ts |
| Firewall change on a running VM | ~0.1 s | WEB:drivers/freestyleNetworkPolicy.ts |
| Tunnel RTT, cloud client to VM, same metro | 2.18 / 2.51 ms p50/p99, 228 Mbit/s down (in-process) | TR §13.1 |
| Far clients through the SF endpoint | fra 146 ms, nrt 106-112 ms; single stream 11-21 Mbit/s vs 44-62 direct IPv6 | TR §13.6 |
| First connect on a never-used tunnel idle > ~5 min | ~15 s in 5 of 6; fixed client-side by the cmux-wg watchdog (1.2-1.8 s) | TR §13.6, §15 step 2b |
| Default VPC /24 filled up in production | moved to /20 per network | WEB:privateNetwork.ts |

### 1.3 Limits: known and unknown

Known: one VPC per VM [OA]; account-wide firewall rule limit exists (`create_firewall_rule` 409 "your account is at its firewall rule limit") but the number is not published [OA, FD:pricing-and-limits]; plan limits cover VMs, vCPU, memory, disk, transfer ($0.02/GB across the datacenter boundary; VPC-internal free) but not VPCs, tunnels, rules or regions [FD:pricing-and-limits]; API anti-affinity topology is `node` only ("the only domain today") [OA:VmPlacementTopology].

Unknown: tunnels per account and per VPC; attachments per tunnel; rules per account, VPC or VM; VPCs per account; API rate limits; any region other than SF; rule propagation SLO; whether the firewall is stateful for replies (our measured tunnel-to-VM rule needed no reverse rule [TR §7], so it behaves stateful, undocumented); whether a `cidr` source matches a tunnel's attachment address.

Critical consequence: cmux runs every tenant on one Freestyle account [WEB:privateNetwork.ts], so the rule limit, tunnel limit and the API key are shared by all tenants. Section 7 treats this as a cross-tenant availability and blast-radius risk.

### 1.4 Questions for Freestyle

1. Regions: which regions have tunnel gateways and VM capacity today and on the roadmap? Can one tunnel (same keys) be dialed at several regional endpoints or an anycast address, and how is `endpointHost` chosen? Will VM create take a region?
2. Tunnel to tunnel in one VPC: confirm it is not forwarded; will it be? Please make `evaluate_firewall` match the data plane (it says allowed today).
3. Limits: tunnels per account and per VPC, attachments per tunnel, firewall rules per account/VPC/VM (the 409 limit), VPCs per account, members beyond a /20, and API rate limits for rule create/delete.
4. Propagation SLO for rule create, rule delete, tunnel delete and rotate-key (we measured 185/196 ms p50, ~2.8 s for rotate).
5. A batch or replace-set rule API with a revision (compare-and-swap), so a policy change is one atomic call.
6. Is the firewall stateful (replies, ICMP echo-reply) by contract?
7. Does a `cidr` source rule match traffic from a tunnel by its pinned attachment address? (This lets one rule cover a group.)
8. May two tunnels carry the same `clientPublicKey`?
9. Does an IPv6-only attachment avoid the IPv4 overlap refusal between VPCs with the same IPv4 range?
10. Fix the gateway that drops the first session's data on a tunnel idle > ~5 min (repro: TR §13.6).
11. Why is single-stream throughput through the gateway 3-4 times lower than direct IPv6 at 100-150 ms RTT?
12. MTU: is 1280 current for every tunnel (cmux code still documents 1200)?
13. Per-tenant isolation on your side: sub-accounts or scoped API keys (one key limited to a set of VPCs) and per-sub-account quotas.
14. Telemetry: last handshake time and rx/tx bytes per tunnel, and webhooks for handshake/revoke, for device online state and audit.
15. Tunnel traffic wakes paused VMs [FD:tunnels]: wake latency, and can a VM opt out?
16. `PersistentKeepalive` in returned configs, and the gateway's NAT/session idle timeout.
17. Billing: are tunnel bytes billed as datacenter-boundary transfer; is there a per-tunnel charge?

## 2. Regions and node choice

Today there is exactly one node: the SF endpoint, and VMs are in SF too [TR §7, §16]. M2 asks for the nearest region "where available" [D:M2], so the design carries a region model that holds one row now:

| Region id | Endpoint | Status |
| --- | --- | --- |
| `us-west` | Freestyle SF gateway | live [TR §13.2] |
| `us-east`, `eu-west`, `eu-central`, `ap-northeast`, `ap-southeast` | Freestyle regional gateways | proposed; exist only if Freestyle answers question 1 yes |

The list mirrors where the transport lane measured far clients (sjc, fra, nrt) [TR §13.6] plus the largest remaining user populations; it is a proposal, not a Freestyle fact.

Choice:
- The region registry lives in the Worker (`mesh_regions`: id, endpoint, live flag). A mesh has a home region where its VMs run; a device has a current ingress region.
- At enrollment and on every network change, `cmux link` measures each live region: the WireGuard handshake round trip on that region's endpoint (the gateway does not answer ICMP [TR §13.2]), 5 samples, median. With one region this is one number.
- The device picks the lowest median; it switches only when a challenger beats the current region by max(5 ms, 20 %) on three measurements in a row (same hysteresis rule as the path selector, TR §4 step 5).
- Ongoing latency per peer is the existing in-session probe on overlay UDP 4102, every 5 s while the link carries traffic [TR §4 step 6, §12a]. The device reports `{region, handshake_rtt_ms, peer_rtt_p50_ms, path}` to `POST /v1/devices/{deviceId}/latency` at most once a minute while active; the app shows region and RTT [D:M2].
- If Freestyle never ships regions, decision T1's fallback applies to ingress only: cmux regional WireGuard nodes on Fly.io, each a Freestyle tunnel client attached as an `exit` to the mesh [D:T1, OA:attach_vpc_to_tunnel `exit`]. That adds one hop and is out of scope for this experiment.

## 3. Device enrollment (cmux-wg path)

Reused code: `cmux link` owns one overlay endpoint per user per machine [TR §3, WG:cmux-link/lib.rs]; `WgNet` is one client to one network over one UDP socket in-process (boringtun + smoltcp, no root, no Network Extension) [WG:lib.rs, UW]; `WgMesh::add_gateway` routes mesh peers through a gateway tunnel's datagram service [WG:mesh.rs, mesh_gateway.rs]; the first-connect watchdog handles the idle-gateway stall [TR §15 step 2b]; overlay addresses are `fd7c:6d78::/32` + 96 bits of SHA-256(install id) [WG:overlay_addr.rs].

Flow:
1. Keys on the device. The install identity key (P-256, Secure Enclave on Apple, 0600 file on Linux) already exists [TR §8]. `cmux mesh up` makes one X25519 WireGuard key per (device, mesh) in the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced) or a 0600 file [TR §8]. Private keys never leave the process that made them.
2. Authorization. A signed-in user enrolls with the Stack session. A headless machine uses a one-time code: a member calls `POST /v1/meshes/{meshId}/enrollment-codes` (single use, 10 min TTL, stored as SHA-256, bound to mesh, creator and optional tags), then runs `cmux mesh up --code <code>` on the machine [D:M1].
3. Enrollment call: `POST /v1/meshes/{meshId}/devices` with `{wgPublicKey, installPublicKey, signature, name, os, code?}`. The signature is the install key over `(meshId, wgPublicKey, server nonce)`.
4. Tunnel creation in the Worker: `create_tunnel {clientPublicKey: wgPublicKey, slug: hash(tenant, device), routes: [mesh cidr, mesh cidrV6], vpcs: [{vpc: mesh}]}` (inline attach; 136-171 ms [TR §13.2]). `routes` is the mesh only, never the 10/8 default. The upstream client type requires `clientPublicKey`; if a response ever carries a non-blank `PrivateKey`, the Worker deletes the tunnel and fails closed (Freestyle mints a key only when the field is omitted [OA:create_tunnel]).
5. ACL first, then config: the mesh's reconciler adds this device's compiled rules (section 4) before the enroll call returns, so the first dial works.
6. Config delivery: the response is structured fields, not Freestyle's file: `serverPublicKey`, endpoint, client addresses, the attachment's mesh address, MTU 1280, and the device's peer map slice. `cmux link` writes a 0600 config [UW] and brings the gateway session up in-process; later launches reuse it with no API call [UW].
7. cmux VMs do not get tunnels: `POST /v1/meshes/{meshId}/vms/{vmId}` calls `update_vm_networks` (live) [OA]; the VM daemon's overlay endpoint listens on UDP 4101 at its VPC address [TR §7].

Rotation: every 90 days and on demand [TR §8]. The device makes a new key and calls `POST /v1/devices/{deviceId}/rotate-key {newPublicKey, signature}`; the Worker calls `rotate_tunnel_key {clientPublicKey}` (tunnel id, addresses and attachments stay [OA, FD:tunnels]) and returns the new `serverPublicKey` (it changes too [TR §7]); overlay peers get the key in a peer-map delta; the device deletes the old key after the ack. The old key stops in ~2.8 s [TR §13.2].

Revocation: `DELETE /v1/devices/{deviceId}` (owner or tenant admin), install revocation, or removal from the Stack team. The Worker deletes the tunnel (its rules go with it [OA:create_firewall_rule]), removes the key from every peer map, and `HostDO` refuses its relay tickets [TR §8]. Measured block time ~0.2-0.26 s [TR §13.2]. Team removal is detected on the next authenticated call and, for the experiment only, by a reconcile sweep every 60 s that compares devices with Stack team membership. That sweep leaves a removed member up to 60 s of access; before any external user, removal revokes at once on the Stack team-membership webhook, or on every token refresh where the webhook is unavailable (GA blocker G1, section 9). A lost device keeps its key, but nothing accepts it [TR §8].

## 4. ACL

### 4.1 Source of truth

One policy document per mesh, in the NP shape (groups, tagOwners, hosts, acls `src -> dst:ports`, tests), default deny, plus default rules "allow within a user's own devices" and "admins to all" [D:M3, NP]. Versions are immutable rows in `cmux_vm.mesh_acl_versions` (mesh, version, document, sha256, author, created_at); the current version pointer and the reconciler state live in one Durable Object per mesh (`MeshDO`), the single writer that serializes every compile and apply. Undo = apply an earlier version as a new version [D:M3, NP ops].

### 4.2 Compile

1. Validate: schema, unknown groups/tags, tag ownership, and the policy's own tests; a failing policy is refused [NP].
2. Resolve: principals to devices (tunnels) and VMs of this mesh only.
3. Emit pairwise tuples `(src, dst, protocol, port)` where `src`/`dst` is `{tunnelId}` or `{vmId}`. A port list expands to one rule per port (Freestyle takes one port per rule [OA]); `*` omits port and protocol. A rule whose `src` is every mesh member becomes one `{vpcId}` source rule instead of N. ICMP is a rule with `protocol: icmp`.
4. Device-to-device tuples (both ends are tunnels) do not become Freestyle rules (not forwarded [TR §7]); they go into each host's peer map and allowed services [TR §9, §12a].
5. Invariant checks: no rule names a resource outside this mesh; no `{vpcId} -> {vpcId}` rule unless the policy grants `*` between all members; rule count within the tenant's rule budget (section 7).
6. Output: the desired rule set keyed by a canonical string, each rule tagged `description: "cmux:mesh:<meshId>:v<version>"`, so reconcile touches only its own rules (same pattern as `EGRESS_RULE_DESCRIPTION` [WEB:drivers/freestyleNetworkPolicy.ts]). `POST .../acl/preview` returns this set and its diff before apply [D:M3].

### 4.3 Apply order (no gap)

Invariant: during an apply, the traffic allowed is always a subset of (old policy ∪ new policy), and traffic allowed by both is never interrupted.
1. Read actual rules for the mesh's own resources (`list_firewall_rules` by `vmId`/`tunnelId`, `limit` 1000) and diff with desired.
2. Create every missing rule (batches of 8 concurrent calls [WEB:drivers/freestyleNetworkPolicy.ts]); each call has an idempotency key derived from (mesh, version, rule key). A changed rule is a new rule plus a delete of the old one, never an edit.
3. Push peer-map additions to hosts.
4. Only after every create succeeded: push peer-map removals, then delete surplus rules (404 counts as done).
5. Re-list, compare with desired, record drift; mark the version `applied` with timings, or `converging` with the failing calls and retry with backoff. A failed create aborts before step 4, so a failure leaves the old ∪ partial-new state, never a closed one.

Revocation (section 3) is the exception: it deletes first, because closing is its purpose.

### 4.4 Time to apply

Per changed rule: create p50 172 ms (max 1,356) plus 185 ms to effect; delete 132 ms plus 196 ms to effect [TR §13.2]; from a Worker, assume ~0.5 s per batch of 8 [WEB:drivers/freestyleNetworkPolicy.ts]. Estimate for k changed rules: ceil(k/8) × 0.5 s + 0.25 s, so about 1 s for k ≤ 8 and about 2.25 s for k = 32. Target for the proof: an allow or a block takes effect ≤ 3 s p95 for ≤ 32 changed rules (M4 "within seconds" [D:M4]). Peer-map changes for device-to-device rules are one push, under 1 s [TR §1.1 revocation target].

## 5. cmux VM API resources

New kinds in `cmux_vm.resources` (migration 0003, additive; extends the kind and prefix CHECKs [VM:migrations/0001]): `mesh` (`mesh_`, upstream = VPC id), `device` (`dev_`, no upstream; links its `tun_` or `vm_`), `tunnel` (`tun_`, upstream = tunnel id), `fwrule` (`fwr_`, upstream = rule id, never exposed). New tables: `mesh_devices` (dev id, mesh, owner user, kind mac|linux|vm, wg public key, install public key, tags, created_at, revoked_at), `mesh_acl_versions`, `mesh_enrollment_codes` (hash, mesh, creator, tags, expires_at, used_at), `mesh_cidrs` (mesh, IPv4 /20 slot, UNIQUE). Upstream VPC and tunnel slugs carry a hash of the tenant id [D:V3, WEB:privateNetwork.ts].

Scopes (added to `SCOPES` [VM:src/domain/scopes.ts]): `mesh:read`, `mesh:write`, `mesh:join`, `acl:read`, `acl:write`. Sessions get all but `admin` (existing rule); `acl:write`, mesh create/delete and revoking another user's device also need Stack team admin.

| Endpoint | Scope | Proofs |
| --- | --- | --- |
| `POST /v1/meshes` | mesh:write + team admin | KeyHasScope, CallerIsTeamAdmin, TenantMayCreate<mesh> (1 mesh per tenant in the experiment) |
| `GET /v1/meshes`, `GET /v1/meshes/{meshId}` | mesh:read | TenantOwnsResource<mesh> |
| `DELETE /v1/meshes/{meshId}` | mesh:write + admin | TenantOwnsResource<mesh>; 409 while devices exist (mirrors `delete_vpc` 409 [OA]) |
| `POST /v1/meshes/{meshId}/enrollment-codes` | mesh:join | TenantOwnsResource<mesh> |
| `POST /v1/meshes/{meshId}/devices` | mesh:join, or a valid code | TenantOwnsResource<mesh>, TenantMayCreate<device>, DeviceHoldsKey (install-key signature over the nonce) |
| `GET /v1/meshes/{meshId}/devices`, `GET /v1/devices/{deviceId}` | mesh:read | TenantOwnsResource<device> |
| `PATCH /v1/devices/{deviceId}` (name, tags) | mesh:write; tags need tag ownership | TenantOwnsResource<device> |
| `POST /v1/devices/{deviceId}/rotate-key` | mesh:join, own device | TenantOwnsResource<device>, DeviceHoldsKey |
| `DELETE /v1/devices/{deviceId}` | mesh:join (own) or mesh:write + admin | TenantOwnsResource<device> |
| `GET /v1/devices/{deviceId}/peers` | mesh:join, own device | TenantOwnsResource<device>; returns only peers the ACL lets talk to this device |
| `POST /v1/devices/{deviceId}/latency` | mesh:join, own device | TenantOwnsResource<device> |
| `GET /v1/meshes/{meshId}/tunnels`, `GET /v1/tunnels/{tunnelId}` | mesh:read | TenantOwnsResource<tunnel>; config fields only, never a key |
| `POST`/`DELETE /v1/meshes/{meshId}/vms/{vmId}` | mesh:write + vm:write | TenantOwnsResource<mesh>, TenantOwnsResource<vm>, SameTenant |
| `GET /v1/meshes/{meshId}/acl`, `.../acl/versions` | acl:read | TenantOwnsResource<mesh> |
| `POST /v1/meshes/{meshId}/acl/preview` | acl:read | TenantOwnsResource<mesh> |
| `PUT /v1/meshes/{meshId}/acl` (`expectedVersion`, `Idempotency-Key`) → 202 + apply id | acl:write + admin | TenantOwnsResource<mesh>, AclCompiled<mesh, version> |
| `GET /v1/meshes/{meshId}/acl/applies/{applyId}` | acl:read | TenantOwnsResource<mesh> |

Tunnels are created only through device enrollment; there is no free-standing tunnel endpoint, so no tunnel exists outside the ACL. In the V2 coverage list, `create_tunnel` without `clientPublicKey` and `rotate_tunnel_key` without it are denied with reason "a provider-minted private key would leave the device boundary"; `attach_vpc_to_tunnel` with `exit`/`remoteCidrs` is denied for the experiment; raw rule CRUD on mesh-owned resources is denied (the ACL owns them).

New proofs, minted only in `src/proofs/` [D:V4]:
- `SameMesh<A, B, M>`: both ends of a firewall rule are resources of mesh M of the caller's tenant. `createFirewallRule` in the upstream client requires it for its exact `source` and `destination`, so a rule can never name another tenant's tunnel or VM, even with a leaked upstream id.
- `AclCompiled<M, V>`: the rule set came from validated version V of mesh M; the reconciler's create/delete calls require it.
- `DeviceHoldsKey<D, K>`: the install key signed this request's nonce.
- `CallerIsTeamAdmin<C>`: Stack team admin permission for a session.

Cross-tenant 404: every id resolves through the ownership table for the caller's tenant [D:V3, VM:proofs/tenant-owns-resource.ts]; another tenant's mesh, device, tunnel, VM or apply id is 404, a code from another tenant is 404, and a peer map never lists a device of another mesh. Inside a tenant, a member acting on another member's device without admin gets 403 (the resource is visible to the tenant). Every endpoint gets the B-gets-404 test [D:V5]. Every mutation writes an audit row [VM:README].

## 6. Proof plan (M4)

No step runs on this laptop. Builds: Worker in CI (miniflare, fake upstream) and the staging deploy [D:V6]; `cmux-tui`/`cmux link` on a Blacksmith Testbox or the fleet. Database: migration 0003 applied by an operator to PlanetScale database `cmux-prod`, branch `staging`, with `pscale --org cmux` [VM:README Operations], before the staging Worker uses it; production is out of scope for the experiment. Tenants: dev/test tenants T1 and T2 on staging (VM idle timeout ≤ 300 s is enforced for dev/test [VM:src/policy.ts]).

| Step | Runs on | Pass |
| --- | --- | --- |
| P1 create mesh M on T1 | cmux-lawrence-2 (CLI) | `mesh_` id; VPC slug hashed |
| P2 Mac A enrolls (session) | cmux-lawrence-2 | Keychain item exists; recorded upstream response had blank `PrivateKey`; gateway handshake RTT logged |
| P3 VM joins | cmux VM API from cmux-lawrence-2; Freestyle VM `idleTimeoutSeconds` 300 | VM is a member; paused between steps; deleted by exact id at the end |
| P4 Mac B enrolls with a one-time code | a fleet Mac through the controller job system (`cmux-ci`); if the controller cannot run this job type, report the gap (no maclease) | second use of the code is refused |
| P5 reachability | A→VM: `cmux mesh ping`, `ssh -o ProxyCommand="cmux mesh nc %h %p"`; A↔B the same over the overlay (B exports sshd as a link service) | ping and SSH succeed both ways; path label (`direct_lan`/`direct_wan`/`do_relay`) recorded |
| P6 ACL flip | VM serves tcp 8080; A connects every 50 ms; apply block, then allow, 10 times each; same for A→B on a service port | VPC path ≤ 3 s p95 per flip; overlay path ≤ 1 s; time measured from the 202 to the first changed probe |
| P7 negative | T2 key, T2 device | 404 on every T1 id; T2 device cannot reach the VM (timeout); revoked Mac B stops ≤ 1 s; rotated key dead after ~3 s |
| P8 latency per region | Mac A, Mac B, and Fly machines (sjc, iad, fra, lhr, nrt, sin) running the Linux `cmux link`, as in TR §13 | per device: region, handshake RTT, ICMP RTT via the tunnel (n=1000, p50/p99), TCP connect, 30 s throughput |
| P9 cleanup | cmux-lawrence-2 | VM, devices (tunnels), mesh and Fly machines deleted by exact id; each verified 404 |

Ping and SSH on a Mac go through `cmux` because the userspace stack has no system interface [UW]; system-wide `ping`/`ssh` needs the opt-in Network Extension (`cmux vpn up`) [UW] and is not part of the proof. ICMP echo inside the userspace stack and service export (overlay port → local sshd) are build items. Every Freestyle resource gets a `cmuxnp-dev-mesh-` prefix [TR §13.5].

## 7. Security

Threat model:

| Threat | Control |
| --- | --- |
| Another tenant reaches a mesh (id guessing, leaked upstream id, rule naming a foreign tunnel) | opaque ids + ownership lookup per tenant (404) [D:V3]; `SameMesh` proof on every rule create; hashed slugs; per-mesh unique IPv4 /20 from `mesh_cidrs` |
| Removed member or lost device | revoke deletes the tunnel (~0.25 s) and peer-map entries; 60 s membership sweep; tokens expire in minutes [TR §8] |
| Compromised device inside a mesh | default deny; pairwise rules only; no VPC-wide member rule unless granted; `routes` limited to the mesh; the link `hello` token still gates every application op [TR §0 item 7, §9] |
| Private key exposure | keys made on device; Worker never omits `clientPublicKey`; fail closed on a minted key; Keychain `ThisDeviceOnly` [TR §8] |
| Enrollment code theft | single use, 10 min, hashed, bound to mesh and tags, audited |
| Worker compromise or Freestyle API key leak | one key controls every tenant's VPCs and tunnels (shared account [WEB:privateNetwork.ts]); key only in Worker secrets [D:V3]; drift detection; ask Freestyle for scoped keys (question 13) |
| Noisy tenant exhausts the account rule or tunnel limit | per-tenant budgets in the Worker (section 7.1), refused with a typed 429 before any upstream call; operator alert at 70 % of the shared account's rule limit; `{vpcId}` source compression |
| Freestyle as an observer | the gateway terminates the tunnel, so plain L3 traffic to VMs (for example HTTP on 8080) is visible to Freestyle, same trust as hosting the VM; overlay traffic is end-to-end WireGuard and the relay sees ciphertext only [TR §0, §9.1] |
| ACL drift (a failed or silent call) | re-list after apply; periodic reconcile; `evaluate_firewall` is not trusted as proof (it disagrees with the data plane [TR §7]); proofs use data-plane probes |

### 7.1 Budgets and the shared-account alert

The Worker enforces every budget before it makes an upstream call, with the existing typed error `QuotaExceeded` (HTTP 429, fields `message` and optional `retryAfterSeconds` [VM:src/errors.ts]), extended with a `budget` field naming the budget that was hit. A refused request changes nothing upstream.

| Budget | Experiment value | Checked at | `retryAfterSeconds` |
| --- | --- | --- | --- |
| `mesh.perTenant` | 1 | `POST /v1/meshes` | absent (frees only on delete) |
| `device.perMesh` | 50 | enroll | absent |
| `enrollmentCode.perMeshPerHour` | 20 (confirmed 2026-10-07) | code create | seconds until the hour window frees one |
| `firewallRule.perMesh` | 500 compiled rules | ACL preview and apply, enroll, VM join | absent; preview reports the count so the policy can be tightened |
| `aclApply.perMeshPerMinute` | 10 (confirmed 2026-10-07) | ACL apply | seconds until the window frees one |

Budgets are config values (the same mechanism as `TENANT_VM_QUOTAS` [VM:README]) with per-tenant overrides. The Worker keeps a count of live upstream firewall rules it owns across all tenants (ownership rows of kind `fwrule`) and alerts the operator when it reaches 70 % of `FREESTYLE_ACCOUNT_FIREWALL_RULE_LIMIT`, a config value, set to 1000 from the first deploy (placeholder, unverified, replace when Freestyle answers question 3), so the alert fires at 700 rules. Separately, an upstream 409 "account is at its firewall rule limit" [OA:create_firewall_rule] also pages the operator and is returned to the caller as `QuotaExceeded` with `budget: "firewallRule.account"`.

### 7.2 Device to device

Device to device with no tunnel-to-tunnel forwarding [D:T3, TR §7]: Mac↔Mac uses `direct_lan`, then `direct_wan` (punched IPv4 or IPv6), then the `HostDO` relay [D:D38, TR §4]. The Freestyle firewall is not on these paths, so the ACL is enforced by the receiving host's peer map (unknown keys get no answer [WG:mesh.rs]), `HostDO` admission (only installs in the host's compiled reachability [TR §6]), the link's registered-port filter [TR §12a] and the link `hello`. Measured: punch about 1 RTT; office-to-cloud punch success 47 %; relay 7.8 ms p50 in the same metro [TR §13.1, §13.3]. A cmux relay VM inside the VPC would keep Freestyle in the path (+2.6 ms [TR §7]) but costs an always-on VM per mesh; it is not used. The `HostDO` relay never decrypts Mac-to-Mac traffic: it forwards WireGuard packets that stay end-to-end encrypted between the two devices' keys, and it sees only outer addresses, peer ids, sizes and timing [TR §0 item 1, §6, §9.1]. It writes nothing to storage on the datagram path [TR §6]. If Freestyle adds tunnel-to-tunnel forwarding, the compiler emits `{tunnelId} -> {tunnelId, port}` rules and the path ladder gains `via_cloud_region` for device pairs.

Security review before any external user [D:M4]; the full gate list is section 9.

## 8. Trade-offs

| Choice | Alternative | Why |
| --- | --- | --- |
| One tunnel and one key per (device, mesh) | one tunnel per install attached to every team VPC (TR §7) | each tunnel has exactly one owning tenant (V3 ownership rows, per-tenant revoke and budgets) and no attachment-overlap coupling across teams; cost: one more gateway session per extra team, which `WgMesh` supports [WG:mesh_gateway.rs]. Confirmed by the coordinator 2026-10-07; TR §7 amended on this branch. |
| ACL source of truth in the cmux VM Worker (`MeshDO` + Postgres) | `TeamDO` (NP) | V1 puts every Freestyle call behind the cmux VM API; `TeamDO` calls the cmux VM API for policy and devices. Confirmed by the coordinator 2026-10-07; NP amendment text in appendix A. |
| Pairwise identity rules | CIDR rules per group with pinned attachment addresses | identity rules are documented to work; CIDR compression waits for question 7 |
| Userspace WireGuard, `cmux`-mediated ping/SSH | Network Extension system tunnel | no root, no VPN prompt, decided path [UW, D:M2]; system-wide is the existing opt-in. Confirmed for the proof by the coordinator 2026-10-07. |
| Create-before-delete apply | delete-first | never interrupts traffic both versions allow; old-only traffic lasts at most one apply (~1-3 s) |

Strongest expert objection: "This is not Tailscale. Freestyle gives one San Francisco gateway, no regions, no tunnel-to-tunnel forwarding, allow-only rules with an unpublished account-wide limit and no atomic update. Device-to-device traffic (most of what a tailnet does) bypasses Freestyle and runs on your own relay and NAT traversal, so 'not caring about infra' fails, and a shared vendor account makes one key the blast radius for every customer. Use Tailscale/Headscale or your own WireGuard nodes."

Answer: VMs live on Freestyle and have no public ports, so VM ingress must be Freestyle's VPC and firewall in any design; the mesh adds only per-device tunnels and rules on top of what Cloud attach already runs in production [UW, WEB:privateNetwork.ts]. The device-to-device path (LAN direct, punch, DO relay) is required anyway, because a LAN path beats any hub, and it is already built and measured [TR §13, §15]. Tailscale or Headscale would replace our identity and ACL with theirs (M1 requires our own) and still need relays. The objection's real content is the limits and the shared key: the experiment measures them (P6, P8), refuses over-budget tenants before Freestyle sees a call, and makes questions 1, 3 and 13 the gate for any external user. If Freestyle answers no to regions, decision T1's Fly.io ingress nodes are the fallback.

## 9. GA blockers (before any external user)

| Id | Blocker | Why |
| --- | --- | --- |
| G1 | Revoke on the Stack team-membership webhook (or on every token refresh), replacing the 60 s sweep | the sweep leaves a removed member up to 60 s of access (section 3) |
| G2 | Freestyle answers questions 1, 3 and 13 (regions, limits, scoped keys), and `FREESTYLE_ACCOUNT_FIREWALL_RULE_LIMIT` replaces the 1000 placeholder with the real limit | the shared account is the cross-tenant blast radius (section 7) |
| G3 | Security review of the mesh [D:M4] | decision M4 |
| G4 | Budgets in section 7.1 reviewed against measured use from the proof | experiment values are guesses |

## 10. Order of work

Code waits until cmux VM S2 lands on `feat-cmux-next`. The first code slice is a branch from `feat-cmux-next`: the mesh, device and tunnel resources with their proofs (section 5) and the cross-tenant 404 tests, with the failing tests committed first. ACL compile/apply, enrollment codes, regions and the proof run follow in later slices.

## Appendix A. Amended text for `spec/network-policy.md` (for the coordinator)

The spec repo belongs to the coordinator, so this is the exact replacement text; nothing in that repo was edited.

A1. In "Goals", replace the first bullet with:

> - One network policy per team, in the spirit of a Tailscale ACL: groups, tags, hosts, source/destination/port rules, SSH rules mapped to Linux users, and built-in tests. The cmux VM API Worker owns it (versions in Postgres, one `MeshDO` per team mesh as the single writer of compile and apply; workers/cmux-vm/mesh/DESIGN.md section 4). `TeamDO` reads and changes it only through the cmux VM API.

A2. Replace the paragraph under "Policy document" that begins "Stored in `TeamDO`" with:

> Stored by the cmux VM API Worker as immutable versions (`cmux_vm.mesh_acl_versions`); JSON with comments allowed in the editor; canonical JSON stored.

A3. In "Reconciler", replace item (a) with:

> - (a) Phase 1, Freestyle: one VPC per team (D37), created as a cmux VM API mesh; each machine (Cloud VMs, the team VM, streaming hosts) is a VPC member with its tags recorded by cmux; each device gets one Freestyle WireGuard tunnel per team mesh it joins (one tunnel and one key per (device, mesh), never one tunnel shared across teams), created with the device's public key; compiled ACLs become pairwise Freestyle firewall rules, created before surplus rules are deleted, by the cmux VM API Worker when the policy, the directory or a machine changes.

A4. Replace "How a Mac joins" steps 2, 3 and 5 with:

> 2. The app calls the cmux VM API `POST /v1/meshes/{meshId}/devices {wgPublicKey, installPublicKey, signature}` (a headless machine uses a one-time enrollment code). The Worker checks the install signature, the user's team membership and the per-tenant budgets.
> 3. The Worker creates the device's Freestyle tunnel for that team's VPC with the device's public key (the platform never sees a private key), routes limited to the mesh CIDRs, applies the firewall rules that involve the device, and returns the structured tunnel config to the app.
> 5. A user in several teams has one tunnel and one WireGuard key per team mesh; the `cmux link` mesh holds one gateway session per tunnel.

A5. Replace the "Revocation" paragraph's first sentence with:

> Revocation: `DELETE /v1/devices/{deviceId}`, install revocation in `UserDO`, or removal from the team (at once on the Stack team-membership webhook or token refresh; a 60 s sweep only in the experiment) makes the cmux VM API Worker delete that team's tunnel for the device (its firewall rules go with it), stop issuing SSH certificates (existing ones expire within minutes; the team VM's revocation list cuts them at once), and drop the device from phase-2 peer maps.

A6. In "Latency", append:

> Device-to-device traffic never uses the VPC (Freestyle does not forward tunnel to tunnel); it uses same-LAN direct, NAT-punched direct, or the `HostDO` relay, which forwards end-to-end-encrypted WireGuard packets and sees only outer addresses and sizes.

A7. In "Data and audit", replace "are stored by `TeamDO` and projected to PlanetScale `cmux-next`" with "are stored by the cmux VM API Worker in PlanetScale (schema `cmux_vm`)".

