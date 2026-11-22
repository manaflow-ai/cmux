# cmux mesh: design (experiment, cx-0op)

Status: design 2026-10-07, built in slices M1-M3 on `feat-cmux-next` (section 11 has the state and the SHAs). Decision: CMUX-MESH-EXPERIMENT M1-M5 and amendment 1 (one region; Freestyle facts validated by our own experiments, section 1.4). Built inside the cmux VM API (CMUX-VM-API V1-V7, amendment 1).

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
- Tunnel to tunnel inside one VPC is not forwarded even with pairwise or VPC-wide allow rules, while `evaluate_firewall` answers allowed (Q1, Q2). A VM in the VPC can relay (+2.6 ms) [TR §7].
- Attached networks on one tunnel must not overlap and must fall inside `routes` (409) [OA:attach_vpc_to_tunnel].
- No batch, replace or compare-and-swap API for rules; atomicity exists only for inline rules at create [FD:firewall].

### 1.2 Measured behavior (transport lane, 2026-10-02/03)

| Item | Value | Source |
| --- | --- | --- |
| Tunnel endpoint | per-tunnel name `tun-<id>.beta-vpn.freestyle.sh`, every name resolves to `208.72.218.30:51820` (and `2602:f470:1::30`), San Francisco; no ICMP | TR §7, §13.2, Q16 |
| Tunnel MTU | 1280 (docs say 1280; older configs 1200) | TR §7, FD:tunnels, UW |
| API p50 | VPC create 164 ms, tunnel create 397 ms (136-171 ms with inline VPC), attach 233 ms, rule create 172 ms (max 1,356), rule delete 132 ms, tunnel delete 247 ms, rotate-key 96 ms | TR §13.2 |
| New rule to first good connection | 185 ms p50, 244 ms max (n=6); rule to first SYN 19-34 ms (round 2) | TR §13.2, §13.6 |
| Rule delete to blocked (new and open connections) | 196 ms p50, 257 ms max (n=5) | TR §13.2 |
| Tunnel delete to blocked | ~220 ms new, ~0 ms open (n=1) | TR §13.2 |
| Rotate-key, old key still works | superseded: 236 ms p50, 285 ms max after the call returns (n=50); server public key changes every time | Q4 (TR §7 had ~2.8 s, n=1) |
| Rule calls from the web app | ~0.5 s per call; serial policy change took 5-11 s; batches of 8 fix it | WEB:drivers/freestyleNetworkPolicy.ts |
| Firewall change on a running VM | ~0.1 s | WEB:drivers/freestyleNetworkPolicy.ts |
| Tunnel RTT, cloud client to VM, same metro | 2.18 / 2.51 ms p50/p99, 228 Mbit/s down (in-process) | TR §13.1 |
| Far clients through the SF endpoint | fra 146 ms, nrt 106-112 ms; single stream 11-21 Mbit/s vs 44-62 direct IPv6 | TR §13.6 |
| First connect on a never-used tunnel idle > ~5 min | ~15 s in 5 of 6; fixed client-side by the cmux-wg watchdog (1.2-1.8 s) | TR §13.6, §15 step 2b |
| Default VPC /24 filled up in production | moved to /20 per network | WEB:privateNetwork.ts |

### 1.3 Limits: known and unknown

Known: one VPC per VM [OA]; at most 200 firewall rules may name one resource (409 "already has the most firewall rules one resource may have (200)", measured Q3); an account-wide rule limit also exists (`create_firewall_rule` 409 "your account is at its firewall rule limit") but its number was not pushed, because the validation key shares the production account (Q0, Q3); plan limits cover VMs, vCPU, memory, disk, transfer ($0.02/GB across the datacenter boundary; VPC-internal free) but not VPCs, tunnels, rules or regions [FD:pricing-and-limits]; API anti-affinity topology is `node` only [OA:VmPlacementTopology]; one region, San Francisco (Q16).

Still unknown (not measured): tunnels per account and per VPC; attachments per tunnel; VPCs per account; the account-wide rule number; API rate limits (Q3 reached 188 rule creates/s with no 429); gateway throughput at 100-150 ms RTT (no far vantage point, Q10).

Critical consequence: cmux runs every tenant on one Freestyle account [WEB:privateNetwork.ts], so the rule limit, tunnel limit and the API key are shared by all tenants. Section 7 treats this as a cross-tenant availability and blast-radius risk. The per-resource limit of 200 also caps the rules that can name one VM or one tunnel (section 7.1).

### 1.4 Freestyle facts validated by experiment (amendment 1)

We do not ask Freestyle; each fact below comes from our own script under `workers/cmux-vm/mesh/validation/` (bun + TypeScript; WireGuard client `wgprobe/`, userspace wireguard-go + gVisor netstack, run on cmux-lawrence-2, Santa Clara, no root). All runs on 2026-10-07 UTC. Every resource had the prefix `cmux-mesh-validation-<run>`, was written to a ledger at create, and was deleted by exact id; `verify-gone.ts` then read all 658 ledger ids by exact id and every one returned 404 (`validation/evidence/cleanup-proof.jsonl`). Raw results: `validation/evidence/results-*.jsonl`. Latency numbers carry the probe resolution: one TCP connect every 10 ms, 7-8 ms RTT to the VM.

| Q | Question | Method | Result | Script |
| --- | --- | --- | --- | --- |
| 0 | Is the dev key on the production account? | `list_identities` + `describe_identity` (`accountId`) and snapshot-set overlap, read only, for both keys | Same account (`acct-942e3bec...`; 200 of 200 snapshots shared). Consequence: Q3 not pushed to the account limit | `00-account-check.ts` |
| 1 | Tunnel to tunnel forwarding | 2 tunnels in one VPC, both clients up; TCP 7000 and ICMP each way with no rule, pairwise rules both ways, then plus a VPC-wide member rule | Not forwarded in any case: 0 of 5 pings and TCP timeout both ways, 2 runs. Tunnel to VM works (299-324 ms first connect). Every tunnel has the same client address `100.64.0.1/32` | `01-tunnel-to-tunnel.ts` |
| 2 | `evaluate_firewall` vs the data plane | 10 cases (tunnel/VM/public, rule/no rule/platform block), evaluate then probe | Agrees in 9 of 10. Only disagreement: tunnel A to tunnel B with a rule, evaluate `allowedByRule`, data plane drop. TCP 25 to public: `deniedByPlatform:outboundMail` and dropped | `02-evaluate-vs-dataplane.ts` |
| 3 | Firewall rule limit and rate | One throwaway VPC, rules `{vpcId}->{vpcId,port}`, 8 concurrent, stop at 409 or 300 | 409 after 200: per-resource limit 200 rules per VPC/VM/tunnel. Account limit not reached and not pushed (shared account). Create 188 rules/s (p50 35 ms, p95 53 ms), delete 175 rules/s (p50 32 ms, p95 46 ms), no 429 | `03-rule-limit.ts` |
| 4 | Propagation (n=50 each, probed on the data plane) | Continuous TCP probe to the VM while the call runs; time = start of the first probe in the final stable run, from the moment the call was sent | Rule create: effective 35 ms p50 / 65 ms p95 after send (API 56 / 96 ms, so it is live before the call returns). Rule delete: blocked 26 / 45 ms after send. Tunnel delete: blocked 45 / 55 ms after send. Rotate-key: old key dead 236 / 279 ms after the call returns (max 285 ms); new key works 23 / 55 ms after it returns; server public key changed 50 of 50. New tunnel first connect: 293 ms p50, 479 ms p95, max 11.0 s (1 of 50) | `04-propagation.ts` |
| 5 | Stateful replies and ICMP | One tunnel-to-VM rule only, then probe both directions | Stateful: a tunnel-to-VM `tcp 8080` rule carries the replies; the VM cannot open to the tunnel without its own rule (timeout), and can with one. ICMP needs `protocol: icmp` (a TCP rule gives 0 of 3); with a tunnel-to-VM ICMP rule echo-reply returns (20 of 20, 7.7 ms) and the VM can also ping the tunnel (3 of 3), while with no ICMP rule the VM gets 0 of 3 | `05-stateful.ts` |
| 6 | Does a `cidr` source match a tunnel? | Rule `{cidr} -> {vmId, tcp 8080}` alone, 4 candidates | Yes, by the attachment address: `/32` of the attachment, the VPC CIDR and `10.0.0.0/8` all match (3 of 3, evaluate `allowedByRule`); the client address `100.64.0.1/32` does not. The VM sees the attachment address as the source | `06-cidr-source.ts` |
| 7 | Same `clientPublicKey` on two tunnels | One key, tunnels in the same VPC and in a second VPC | Accepted in both cases. Each tunnel gets its own server key and endpoint name; traffic stays per tunnel (each reaches only its own rule's target), also with all three up at once | `07-duplicate-key.ts` |
| 8 | IPv6-only attachment and IPv4 overlap | Two VPCs with the same IPv4 CIDR; attach both to one tunnel, default and with an explicit IPv6 address | Both VPC creates succeed. Second attach refused 409 (IPv4 overlap) by default and with an explicit IPv6 address. A VPC created with `cidr: null` still gets an IPv4 /24. No IPv6-only path exists | `08-ipv6-overlap.ts` |
| 9 | First session after > 5 min idle | 5 rounds: tunnel used then idle 90 s, used then idle 360 s, never used for 360 s; no keepalive; VM kept awake | Used tunnel after 360 s: first connect 41-129 ms, 0 of 5 slow. Never-used tunnel after 360-376 s: 70-83 ms in 4 of 5, 16.0 s in 1 of 5 (17 attempts). Together with Q4 (11.0 s in 1 of 50 fresh tunnels): the stall hits a first handshake on a fresh tunnel, not idle time | `09-idle-first-session.ts` |
| 10 | Single-stream throughput, gateway vs direct | 10 s TCP, 3 runs each way, through the gateway; each end's direct path to speed.cloudflare.com (no direct path between the two ends exists) | Gateway 58.0 Mbit/s down, 57.7 up (p50) at 7.7 ms RTT. Client host direct 60.4 down / 60.0 up; VM direct 643 down / 595 up. No measurable gateway penalty at 8 ms; the client link is the bottleneck. Far RTT not tested | `10-throughput.ts` |
| 11 | Path MTU | DF ping from the VM, binary search; client with inner MTU 1500 | Config MTU 1280. VM VPC interface MTU 1450; VM to tunnel with DF: 1450-byte packets. Client to VM: inner packets up to 1454 bytes pass. Fragmented inner packets (3000 bytes) pass. 1280 is safe | `11-path-mtu.ts` |
| 12 | Handshake and byte telemetry from the API | Read the tunnel by get and by VPC list before and after a handshake and 10.4 MB; scan the live spec | None. No field changes after traffic; no handshake, byte or last-seen field on `Tunnel`, `TunnelAttachment` or the list (live spec, 88 operations). Device online state must come from our own client | `12-telemetry.ts` |
| 13 | Paused VM wake by tunnel traffic | API pause, then TCP probes every 20 ms (300 ms timeout), n=10; one idle-timeout pause | Wakes: first success 1.72 s p50, 6.79 s p95, 10 ms min after probing starts. API pause 133 ms p50. Traffic the firewall denies (port without a rule) also wakes a paused VM. Idle-timeout (300 s) pause seen at 371-401 s (10 s polling); wake then 0.24-3.0 s | `13-paused-wake.ts` |
| 14 | Keepalive and gateway idle timeout | Per tunnel: hold a TCP connection, idle T, then the VM opens to the client and the held connection sends | No keepalive: works after 30, 120 and 300 s idle; both fail after 600 s. `PersistentKeepalive = 25`: both work after 600 s. State expires between 300 and 600 s; returned configs have no keepalive, so the client must add 25 s | `14-keepalive-idle.ts` |
| 15 | `egressIpv4` and IPv4-only hosts | VM with no rules and VM with `{public: true}` egress, no VPC | `egressIpv4` is set at create on both, one shared account address (`208.72.218.133`, SF). With the egress rule: GitHub release asset 13 MB in 0.50 s, `git ls-remote https://github.com/manaflow-ai/cmux` 616 ms, github.com resolves A only. Without a rule: DNS fails | `15-egress-ipv4.ts` |
| 16 | Single region | 3 tunnels, 3 VMs; DNS, ipinfo, traceroute, handshake and RTT from cmux-lawrence-2; egress geo and anycast RTT from each VM | One region. All tunnel names `tun-<id>.beta-vpn.freestyle.sh` resolve to `208.72.218.30` / `2602:f470:1::30` (San Francisco, AS36320). All VMs egress from SF, 3-4 ms to 1.1.1.1 and 8.8.8.8. From Santa Clara: handshake 72 ms, tunnel RTT 8.1-13.1 ms p50. Gateway drops traceroute probes. Testbox vantage not run (gate refused approval) | `16-single-region.ts` |
| 17 | Scoped keys / sub-accounts | Read the live spec; one identity with no grants, its token tried on read routes, identity deleted | None. Two schemes only: account API key and identity access token. Identity permissions are VM-only; an identity token gets 401 on VPC, tunnel, rule and VM routes. Account keys are created only in the dashboard (Stack session). One key controls every tenant | `17-scoped-keys.ts` |
| 18 | Billing | GET usage-like routes with the API key; cost from our ledgers at list prices | No usage on the API key (`/v5/usage`, `/billing`, `/account`, `/accounts/me`, `/limits` all 404; the CLI's billing uses the dashboard with a Stack session). Runs cost at most $0.23 at list price before included usage: 35 VMs, 1.54 VM-hours (2 vCPU / 4 GiB / 16 GiB each), transfer at most 1.29 GB. Whether tunnel bytes count as transfer cannot be read | `18-billing.ts` |

## 2. One region

Decision CMUX-MESH-EXPERIMENT amendment 1 (Lawrence, 2026-10-07): Freestyle is not multi-region, so the mesh is designed for one region. There is no region registry, no region choice and no region field anywhere in the API. The region-selection hysteresis from the first draft is removed: with one endpoint it would be dead code and a migration burden, so keeping it does not cost nothing.

What one region means, measured in section 1.4 (Q16): every tunnel gets its own endpoint name `tun-<id>.beta-vpn.freestyle.sh`, and every name resolves to the same gateway; VMs are in the same metro as the gateway.

- Latency reporting stays: `cmux link` measures the WireGuard handshake time to the gateway and the in-session peer RTT on overlay UDP 4102, every 5 s while the link carries traffic [TR §4 step 6, §12a]. The device reports `{handshake_rtt_ms, peer_rtt_p50_ms, path}` to `POST /v1/devices/{deviceId}/latency` at most once a minute while active, and the app shows the RTT [D:M2].
- Known limit: a user far from the gateway pays the full RTT to it on every VM connection (fra 146 ms, nrt 106-112 ms measured [TR §13.6]). The experiment accepts this and records it in P8.
- Later, "nodes around the world" means our own relays or endpoints (for example cmux WireGuard nodes on Fly.io attached to the mesh as tunnel clients with `exit` [D:T1, OA:attach_vpc_to_tunnel]), not Freestyle regions. That work is out of scope for this experiment. Device-to-device traffic already avoids the gateway (section 7.2).

## 3. Device enrollment (cmux-wg path)

Reused code: `cmux link` owns one overlay endpoint per user per machine [TR §3, WG:cmux-link/lib.rs]; `WgNet` is one client to one network over one UDP socket in-process (boringtun + smoltcp, no root, no Network Extension) [WG:lib.rs, UW]; `WgMesh::add_gateway` routes mesh peers through a gateway tunnel's datagram service [WG:mesh.rs, mesh_gateway.rs]; the first-connect watchdog handles the idle-gateway stall [TR §15 step 2b]; overlay addresses are `fd7c:6d78::/32` + 96 bits of SHA-256(install id) [WG:overlay_addr.rs].

Flow:
1. Keys on the device. The install identity key (P-256, Secure Enclave on Apple, 0600 file on Linux) already exists [TR §8]. `cmux mesh up` makes one X25519 WireGuard key per (device, mesh) in the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced) or a 0600 file [TR §8]. Private keys never leave the process that made them.
2. Authorization. A signed-in user enrolls with the Stack session. A headless machine uses a one-time code: a member calls `POST /v1/meshes/{meshId}/enrollment-codes` (single use, 10 min TTL, stored as SHA-256, bound to mesh, creator and optional tags), then runs `cmux mesh up --code <code>` on the machine [D:M1]. The device then belongs to the code's creator. As built (M2, M3): the code enrolls through `POST /v1/meshes/{meshId}/device-enrollments` with no credential. At use the creator must still be able to act (a team member, or an API key that is not revoked or expired). Any authentication failure burns the code: another mesh's path, a creator that can no longer act, a forged or stale signature, a replayed request. A valid request claims the code before the device budget and the tunnel create; if either (or anything after them) fails, the claim is given back and the same code works again.
2a. After enrollment a headless device has no credential of its own. Its install key is the credential for its own requests (M3): `POST /v1/devices/{deviceId}/signed/peers`, `/signed/tunnel` and `/signed/rotate-key`, each signed over the cmux-mesh-v1 message with purpose `peers`, `tunnel` or `rotate-key`, the device as target, `signedAt` within 120 s, and a replay store keyed by the message hash (`mesh_signed_requests`). The request runs as the device's owner, restricted to `mesh:join`/`mesh:read` on this one device and its tunnel, and the owner must still be able to act on every call, so revoking the key that enrolled a device or removing its user stops the device's signed requests at once. Nothing else accepts the signature: every other route needs an API key or a session (401).
3. Enrollment call: `POST /v1/meshes/{meshId}/devices` with `{wgPublicKey, installPublicKey, signature, name, os, code?}`. The signature is the install key over `(meshId, wgPublicKey, server nonce)`.
4. Tunnel creation in the Worker: `create_tunnel {clientPublicKey: wgPublicKey, slug: hash(tenant, device), routes: [mesh cidr, mesh cidrV6], vpcs: [{vpc: mesh}]}` (inline attach; 136-171 ms [TR §13.2]). `routes` is the mesh only, never the 10/8 default. The upstream client type requires `clientPublicKey`; if a response ever carries a non-blank `PrivateKey`, the Worker deletes the tunnel and fails closed (Freestyle mints a key only when the field is omitted [OA:create_tunnel]).
5. ACL first, then config: the mesh's reconciler adds this device's compiled rules (section 4) before the enroll call returns, so the first dial works.
6. Config delivery: the response is structured fields, not Freestyle's file: `serverPublicKey`, endpoint, client addresses, the attachment's mesh address, MTU 1280, `PersistentKeepalive` 25 s (Freestyle's config has none, and gateway state expires between 300 and 600 s idle, Q14), and the device's peer map slice. `cmux link` writes a 0600 config [UW] and brings the gateway session up in-process; later launches reuse it with no API call [UW].
7. cmux VMs do not get tunnels: `POST /v1/meshes/{meshId}/vms/{vmId}` calls `update_vm_networks` (live) [OA]; the VM daemon's overlay endpoint listens on UDP 4101 at its VPC address [TR §7].

Rotation: every 90 days and on demand [TR §8]. The device makes a new key and calls `POST /v1/devices/{deviceId}/rotate-key {newPublicKey, signature}`; the Worker calls `rotate_tunnel_key {clientPublicKey}` (tunnel id, addresses and attachments stay [OA, FD:tunnels]) and returns the new `serverPublicKey` (it changes too [TR §7]); overlay peers get the key in a peer-map delta; the device deletes the old key after the ack. The old key stops 236 ms p50, 285 ms max after the call returns, and the new key works 23 ms p50 after it (Q4). Because the server key changes too, the device must switch to the new `serverPublicKey` in the same step.

Revocation: `DELETE /v1/devices/{deviceId}` (owner or tenant admin), install revocation, or removal from the Stack team. The Worker deletes the tunnel (its rules go with it [OA:create_firewall_rule]), removes the key from every peer map, and `HostDO` refuses its relay tickets [TR §8]. Measured block time: 45 ms p50, 55 ms p95 after the tunnel delete is sent (Q4, n=50). Team removal is detected on the next authenticated call and, for the experiment only, by a reconcile sweep every 60 s that compares devices with Stack team membership. That sweep leaves a removed member up to 60 s of access; before any external user, removal revokes at once on the Stack team-membership webhook, or on every token refresh where the webhook is unavailable (GA blocker G1, section 9). A lost device keeps its key, but nothing accepts it [TR §8].

As built (M4, cx-0op.6, cx-0op.7): there is no sweep. Removal revokes on the Stack webhook `team_membership.deleted` at `POST /v1/webhooks/stack` (outside the public API; the Svix signature with the Worker secret `STACK_WEBHOOK_SECRET` is the credential, timestamp within 5 min; without the secret the route answers 503). Order: (1) the shared membership cache entry for (team, user) is revoked, so no isolate trusts a cached "member" again; (2) every live device that user enrolled in that team (`created_by = user:<id>`, session enrolls and the user's codes) is closed like `DELETE`: its tunnel deleted by the recorded provider id (404 counts as done), its rule, ownership and device rows marked deleted, one audit row `device.revoke` per device with actor `system:stack-membership-webhook` and owner `user:<id>`; (3) each affected mesh's ACL is recompiled and re-applied under the mesh writer lock (section 4.1). Any failure answers 503 and Stack retries; every step is idempotent, and a message processed to the end is recorded by its id (`stack_webhook_deliveries`), so its retry does nothing. Retries after a re-add (migration 0008): a message is judged by the time it first reached the Worker (`stack_webhook_events.first_seen_at`, kept across retries), never by the retry's own time. Every device the user enrolled in that team at or before that time is closed, also when the user was added back before the delivery or its retry (decision 2026-10-07: a removal cuts the devices that existed then, for example an admin cutting a lost laptop, and a re-add does not bring them back). A device enrolled after the event passed a fresh membership check after it and stays; if the user was removed again, that removal's own event revokes it. The webhook never asks Stack (decision 2026-10-07: the answer could not change the result, and a call per event risks a Stack 429 storm like September's). Revocation does not depend on the mesh allowlist: a tenant that left it still has its devices revoked. An event with nothing to revoke (a team outside the mesh allowlist, no devices, a user Stack no longer knows) is a recorded 200, never a 503: Svix retries a 503 and finally disables the endpoint (staging 2026-10-07: team 94eb2b2b got 503). Every answer is logged with its reason and svix-id. `user.deleted` (data `{id, teams}`) revokes the user's cached membership in every tenant and closes every device the user enrolled in each listed tenant and each tenant where the Worker holds a live device of the user (the team list may be partial), audited as `system:stack-user-deleted-webhook`; it never asks Stack about the deleted user and has no time cutoff (deleted user ids are not reused). Until 0008 is applied the schema gate (section 11, Operations) answers 503 for every route. Devices enrolled by an API key belong to the key and stop when it is revoked or expires. Membership answers for device-signed calls, code uses and sessions come from one cache shared by all isolates (`cmux_vm.stack_memberships`): a "member" answer is trusted 60 s and stored with the time its Stack request was sent, "not a member" is never cached, and an answer sent before the last revocation is never stored or read, so an in-flight answer cannot outlive the webhook. A cache that cannot be read or written is skipped (Stack answers). Without the webhook (secret not set, or Stack never delivers), a removed member keeps access for at most the 60 s cache window. Status: the webhook path is UNVERIFIED against real Stack deliveries until the coordinator sets `STACK_WEBHOOK_SECRET` on `cmux-vm-staging` and registers the endpoint; it is proven only with locally signed deliveries.

## 4. ACL

### 4.1 Source of truth

One policy document per mesh, in the NP shape (groups, tagOwners, hosts, acls `src -> dst:ports`, tests), default deny, plus default rules "allow within a user's own devices" and "admins to all" [D:M3, NP]. Versions are immutable rows in `cmux_vm.mesh_acl_versions` (mesh, version, document, sha256, author, created_at); the current version pointer and the reconciler state live in one Durable Object per mesh (`MeshDO`), the single writer that serializes every compile and apply. Undo = apply an earlier version as a new version [D:M3, NP ops].

Decision (M4, cx-0op.6): no `MeshDO`. The version pointer stays the newest row of `mesh_acl_versions`, and `PUT .../acl` keeps `expectedVersion` (409 when stale) plus the `(mesh, version)` primary key (409 when a concurrent apply inserted the same version): that is the API's optimistic concurrency between admins and needs no new object. The version check alone was not enough, because the provider rules have more writers than the ACL apply: device enroll, VM join and VM leave, and the G1 revocation also reconcile. Real race (red test `mesh-m4.test.ts`, "one writer per mesh"): an enroll reads ACL v1 and stalls on its rule create; an apply inserts v2 without that rule and deletes the rules it lists; the enroll then creates its v1 rule, so v2 is current while a rule v2 removed is live (fail-open drift until the next reconcile). Two reconciles can also create the same rule twice (the second record hits the unique key and leaves an unrecorded provider rule). Fix: one writer per mesh as a lock with a lease in the tenant's existing Durable Object (`TenantLimitsObject.lock`, key `mesh-writer:<meshId>`, 5 min lease against a holder that dies, released on every exit), held from the ACL read through the last provider call by the ACL apply (around the version check and insert), enroll, VM join and leave, and the G1 reconcile. A change that waits 15 s for the lock answers 409. Closing a device (DELETE, revocation) deletes the tunnel before it takes the lock, so revocation never waits for an apply; a rule an apply creates for that tunnel in between is refused by the provider (404) or deleted with the tunnel. Same single-writer property as `MeshDO`, without a new Durable Object class, its wrangler migration, or moving the reconciler out of the request.

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

Per changed rule: create API 56 ms p50 (96 ms p95) and effective 35 ms p50 (65 ms p95) after send; delete API 39 ms p50 and effective 26 ms p50 (45 ms p95) after send; 8 concurrent calls sustain 188 creates/s (Q3, Q4). The older figures (172 ms create, 185-196 ms to effect [TR §13.2]) were from another vantage point; from a Worker, assume ~0.5 s per batch of 8 [WEB:drivers/freestyleNetworkPolicy.ts]. Estimate for k changed rules: ceil(k/8) × 0.5 s + 0.25 s, so about 1 s for k ≤ 8 and about 2.25 s for k = 32. Target for the proof: an allow or a block takes effect ≤ 3 s p95 for ≤ 32 changed rules (M4 "within seconds" [D:M4]). Peer-map changes for device-to-device rules are one push, under 1 s [TR §1.1 revocation target].

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
| `POST /v1/devices/{deviceId}/rotate-key` | mesh:join, own device | TenantOwnsResource<device>, CallerActsOnDevice, DeviceHoldsKey |
| `POST /v1/meshes/{meshId}/device-enrollments` (M2, no credential) | a valid one-time code; the creator must still be able to act | TenantOwnsResource<mesh>, TenantMayCreate<device>, DeviceHoldsKey |
| `POST /v1/devices/{deviceId}/signed/peers`, `/signed/tunnel`, `/signed/rotate-key` (M3, no credential) | the device's install-key signature; the owner must still be able to act | DeviceHoldsKey<owner, device>, TenantOwnsResource<device>, CallerActsOnDevice |
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

Cross-tenant 404: every id resolves through the ownership table for the caller's tenant [D:V3, VM:proofs/tenant-owns-resource.ts]; another tenant's mesh, device, tunnel, VM or apply id is 404, a code from another tenant is 404, and a peer map never lists a device of another mesh. Inside a tenant, a caller that neither enrolled the device nor is a tenant admin (an API key with the `admin` scope, or a Stack team admin session) gets 404 on the device, its tunnel, its peer map, its rotation and its delete, exactly as if the device did not exist, and `GET /v1/meshes/{meshId}/devices` lists only the devices it enrolled (amended in M2/M3, was 403: a 403 would confirm that a guessed device id exists and belongs to someone else in the team; the proof is `CallerActsOnDevice` [VM:proofs/device-owner.ts]). On the credential-free device routes (M3) every refusal before the install-key signature verifies is the same 404 (unknown or deleted device, a signature by another key or for another device or request, an owner that can no longer act, experiment off), so a device id tells a stranger nothing; only the holder of the key learns that its `signedAt` is stale (403) or its request a replay (409). Every endpoint gets the B-gets-404 test [D:V5]. Every mutation writes an audit row [VM:README]; a device-signed action is audited as the device (`actor = device:<id>`) with its owner in `owner_actor` (M4, migration 0007), and a G1 revocation as `system:stack-membership-webhook` with the removed user as owner.

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
| P8 latency by client location (the one-region limit) | Mac A, Mac B, and Fly machines (sjc, iad, fra, lhr, nrt, sin) running the Linux `cmux link`, as in TR §13 | per device: client location, handshake RTT, ICMP RTT via the tunnel (n=1000, p50/p99), TCP connect, 30 s throughput |
| P9 cleanup | cmux-lawrence-2 | VM, devices (tunnels), mesh and Fly machines deleted by exact id; each verified 404 |

Ping and SSH on a Mac go through `cmux` because the userspace stack has no system interface [UW]; system-wide `ping`/`ssh` needs the opt-in Network Extension (`cmux vpn up`) [UW] and is not part of the proof. ICMP echo inside the userspace stack and service export (overlay port → local sshd) are build items. Every Freestyle resource gets a `cmuxnp-dev-mesh-` prefix [TR §13.5].

## 7. Security

Threat model:

| Threat | Control |
| --- | --- |
| Another tenant reaches a mesh (id guessing, leaked upstream id, rule naming a foreign tunnel) | opaque ids + ownership lookup per tenant (404) [D:V3]; `SameMesh` proof on every rule create; hashed slugs; per-mesh unique IPv4 /20 from `mesh_cidrs` |
| Removed member or lost device | revoke deletes the tunnel (~0.25 s) and peer-map entries; the Stack membership webhook revokes the member's devices and cached membership at once (M4); without it, at most 60 s of cached membership; tokens expire in minutes [TR §8] |
| Compromised device inside a mesh | default deny; pairwise rules only; no VPC-wide member rule unless granted; `routes` limited to the mesh; the link `hello` token still gates every application op [TR §0 item 7, §9] |
| Private key exposure | keys made on device; Worker never omits `clientPublicKey`; fail closed on a minted key; Keychain `ThisDeviceOnly` [TR §8] |
| Enrollment code theft | single use, 10 min, hashed, bound to mesh and tags, audited; the creator must still be able to act when it is used; any authentication failure with the code burns it (M3) |
| Headless device after enrollment (no credential) | its install key authenticates only its own peer map, tunnel config and rotation (M3): fresh (120 s), never replayed, refused once the owner key is revoked or the owner left the team; every other route needs a credential |
| Worker compromise or Freestyle API key leak | one key controls every tenant's VPCs and tunnels (shared account [WEB:privateNetwork.ts]); key only in Worker secrets [D:V3]; drift detection; Freestyle offers no scoped API keys (validated, Q17) |
| Noisy tenant exhausts the account rule or tunnel limit | per-tenant budgets in the Worker (section 7.1), refused with a typed 429 before any upstream call; operator alert at 70 % of the shared account's rule limit; `{vpcId}` source compression |
| Freestyle as an observer | the gateway terminates the tunnel, so plain L3 traffic to VMs (for example HTTP on 8080) is visible to Freestyle, same trust as hosting the VM; overlay traffic is end-to-end WireGuard and the relay sees ciphertext only [TR §0, §9.1] |
| ACL drift (a failed or silent call) | re-list after apply; periodic reconcile; `evaluate_firewall` is not trusted as proof (it disagrees with the data plane [TR §7]); proofs use data-plane probes |
| Wake abuse: a mesh device wakes paused VMs | tunnel traffic to a port with no rule woke a paused VM (Q13; that tunnel had a rule to the VM on another port, a tunnel with no rule at all to the VM was not tested), so a device can keep VMs running and billing with traffic the firewall drops. Control: VMs that must stay asleep are not members of a mesh with untrusted devices; the Worker alerts when a paused mesh VM wakes with no allowed flow in its audit window |

### 7.1 Budgets and the shared-account alert

The Worker enforces every budget before it makes an upstream call, with the existing typed error `QuotaExceeded` (HTTP 429, fields `message` and optional `retryAfterSeconds` [VM:src/errors.ts]), extended with a `budget` field naming the budget that was hit. A refused request changes nothing upstream.

| Budget | Experiment value | Checked at | `retryAfterSeconds` |
| --- | --- | --- | --- |
| `mesh.perTenant` | 1 | `POST /v1/meshes` | absent (frees only on delete) |
| `device.perMesh` | 50 | enroll | absent |
| `enrollmentCode.perMeshPerHour` | 20 (confirmed 2026-10-07) | code create | seconds until the hour window frees one |
| `firewallRule.perMesh` | 500 compiled rules | ACL preview and apply, enroll, VM join | absent; preview reports the count so the policy can be tightened |
| `aclApply.perMeshPerMinute` | 10 (confirmed 2026-10-07) | ACL apply | seconds until the window frees one |

Budgets are config values (the same mechanism as `TENANT_VM_QUOTAS` [VM:README]) with per-tenant overrides. The Worker keeps a count of live upstream firewall rules it owns across all tenants (ownership rows of kind `fwrule`) and alerts the operator when it reaches 70 % of `FREESTYLE_ACCOUNT_FIREWALL_RULE_LIMIT`, a config value, set to 1000 from the first deploy (placeholder: the account number was not pushed, because the only test key shares the production account, Q0/Q3), so the alert fires at 700 rules. A second, measured limit applies per resource: at most 200 rules may name one VPC, VM or tunnel (Q3). The compiler therefore refuses a policy that would put more than 180 rules on one VM or tunnel (10 % headroom), and `firewallRule.perMesh` counts rules per named resource as well as per mesh. Separately, an upstream 409 "account is at its firewall rule limit" [OA:create_firewall_rule] also pages the operator and is returned to the caller as `QuotaExceeded` with `budget: "firewallRule.account"`.

### 7.2 Device to device

Device to device with no tunnel-to-tunnel forwarding [D:T3, TR §7]: Mac↔Mac uses `direct_lan`, then `direct_wan` (punched IPv4 or IPv6), then the `HostDO` relay [D:D38, TR §4]. The Freestyle firewall is not on these paths, so the ACL is enforced by the receiving host's peer map (unknown keys get no answer [WG:mesh.rs]), `HostDO` admission (only installs in the host's compiled reachability [TR §6]), the link's registered-port filter [TR §12a] and the link `hello`. Measured: punch about 1 RTT; office-to-cloud punch success 47 %; relay 7.8 ms p50 in the same metro [TR §13.1, §13.3]. A cmux relay VM inside the VPC would keep Freestyle in the path (+2.6 ms [TR §7]) but costs an always-on VM per mesh; it is not used. The `HostDO` relay never decrypts Mac-to-Mac traffic: it forwards WireGuard packets that stay end-to-end encrypted between the two devices' keys, and it sees only outer addresses, peer ids, sizes and timing [TR §0 item 1, §6, §9.1]. It writes nothing to storage on the datagram path [TR §6]. If Freestyle adds tunnel-to-tunnel forwarding, the compiler emits `{tunnelId} -> {tunnelId, port}` rules and the path ladder gains `via_cloud_region` for device pairs.

Security review before any external user [D:M4]; the full gate list is section 9.

## 8. Trade-offs

| Choice | Alternative | Why |
| --- | --- | --- |
| One tunnel and one key per (device, mesh) | one tunnel per install attached to every team VPC (TR §7) | each tunnel has exactly one owning tenant (V3 ownership rows, per-tenant revoke and budgets) and no attachment-overlap coupling across teams; cost: one more gateway session per extra team, which `WgMesh` supports [WG:mesh_gateway.rs]. Confirmed by the coordinator 2026-10-07; TR §7 amended on this branch. |
| ACL source of truth in the cmux VM Worker (`MeshDO` + Postgres) | `TeamDO` (NP) | V1 puts every Freestyle call behind the cmux VM API; `TeamDO` calls the cmux VM API for policy and devices. Confirmed by the coordinator 2026-10-07; NP amendment text in appendix A. |
| Pairwise identity rules | CIDR rules per group with pinned attachment addresses | identity rules are measured to work; a `cidr` source matches the attachment address (Q6), so CIDR compression is possible later and is the escape from the 200-rules-per-resource limit, at the cost of tying rules to addresses instead of identities |
| Userspace WireGuard, `cmux`-mediated ping/SSH | Network Extension system tunnel | no root, no VPN prompt, decided path [UW, D:M2]; system-wide is the existing opt-in. Confirmed for the proof by the coordinator 2026-10-07. |
| Create-before-delete apply | delete-first | never interrupts traffic both versions allow; old-only traffic lasts at most one apply (~1-3 s) |

Strongest expert objection: "This is not Tailscale. Freestyle gives one San Francisco gateway, no regions, no tunnel-to-tunnel forwarding, allow-only rules with an unknown account-wide limit and 200 per resource, no atomic update, no scoped keys and no tunnel telemetry. Device-to-device traffic (most of what a tailnet does) bypasses Freestyle and runs on your own relay and NAT traversal, so 'not caring about infra' fails, and a shared vendor account makes one key the blast radius for every customer. Use Tailscale/Headscale or your own WireGuard nodes."

Answer: VMs live on Freestyle and have no public ports, so VM ingress must be Freestyle's VPC and firewall in any design; the mesh adds only per-device tunnels and rules on top of what Cloud attach already runs in production [UW, WEB:privateNetwork.ts]. The device-to-device path (LAN direct, punch, DO relay) is required anyway, because a LAN path beats any hub, and it is already built and measured [TR §13, §15]. Tailscale or Headscale would replace our identity and ACL with theirs (M1 requires our own) and still need relays. The objection's real content is the limits and the shared key: the validation measured them (section 1.4), the experiment measures them again end to end (P6, P8), and the Worker refuses over-budget tenants before Freestyle sees a call. One region is accepted (amendment 1); low latency far from San Francisco later means our own relays or endpoints, not Freestyle.

## 9. GA blockers (before any external user)

| Id | Blocker | Why |
| --- | --- | --- |
| G1 | Revoke on the Stack team-membership webhook (or on every token refresh), replacing the 60 s sweep | the sweep leaves a removed member up to 60 s of access (section 3). Code done in M4 (section 3); open until the secret is set and a real Stack delivery is observed on staging (UNVERIFIED) |
| G2 | The account-wide rule limit is measured on a separate Freestyle account (never on the production account), `FREESTYLE_ACCOUNT_FIREWALL_RULE_LIMIT` replaces the 1000 placeholder, and the absence of scoped keys (Q17) is accepted in the security review or worked around with a separate account per tier | the shared account is the cross-tenant blast radius (section 7) |
| G3 | Security review of the mesh [D:M4] | decision M4 |
| G4 | Budgets in section 7.1 reviewed against measured use from the proof | experiment values are guesses |

## 10. Order of work

Code waits until cmux VM S2 lands on `feat-cmux-next`. The first code slice is a branch from `feat-cmux-next`: the mesh, device and tunnel resources with their proofs (section 5) and the cross-tenant 404 tests, with the failing tests committed first. ACL compile/apply, enrollment codes and the proof run follow in later slices.

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

## 11. Status (2026-10-07)

| Slice | State | Landed on `feat-cmux-next` |
| --- | --- | --- |
| M1a Worker: meshes, devices, tunnels, ACL compile/apply, peer map, budgets, audit, migration 0004 | done | 61da0fd0fad4 (red 13a3d58599b0, green 9926f9587e32, clients 2c192baea5b5); IPv6 route fix 5b49821af95f |
| M1b device agent (Rust, userspace WireGuard, ping/tcp/probe) | done | 1753d8fd8b36 (red d317583fe49f, green 5d6da54d76e5) |
| M1c live proof on cmux-lawrence-2 | done | f4cf40478988 (evidence 48e76d620fe6) |
| M2 device ownership (non-owner 404), install-key signatures, one-time codes, key rotation, migration 0005 | done; 0005 applied on staging with grants | owner check a2ebee7fcae9, server 6fb2c554ab12, agent 1fb771b48e7d, live proof 899f05034cc9 |
| M3 device-signed requests, revoked-key codes, code burn and restore, migration 0006 (purpose CHECK widened) | done; 0006 applied on staging (checked read-only 2026-10-08) | Worker b543f0a6b417 (red 444f850fb0ff, green a944131f108f), agent fe33ef18ceb0 (red b00fa6102879, green 7e0c94c3b736); live proof `e2e/m3.ts` run m3muxuntiw on cmux-lawrence-2 (`e2e/evidence/m3muxuntiw`): a code-enrolled device with no API key read its peer map and tunnel config, pinged the VM (3/3), rotated (49 ms) and pinged with the new key (3/3); cross-device 404, replay 409, stale 403, forged code enroll 403 then the burned code 404, creator key revoked then signed peers and a fresh code 404; every provider id 404 after cleanup. The first run m3muxuf66g failed its own cleanup (the cleanup key lacked the admin scope); its two tunnels and VPC were deleted by exact id and checked 404 (`e2e/evidence/m3muxuf66g/cleanup-by-exact-id.jsonl`) |

| M4 shared positive membership cache (60 s), device actor in the audit log, G1 membership webhook revoke, one writer per mesh (lock in the tenant DO), migration 0007, staging allowlist (two internal manaflow teams) | code done; 0007 applied on staging (checked 2026-10-08); webhook UNVERIFIED with real Stack (secret not set) | Worker f0f0ed689db5 (red 8cc590865aa8; race red proven by running the test without the lock: 1 rule left, expected 0), staging allowlist 37878834902f |
| M4 G1 retries: event time = first receipt (migration 0008), revoke every device from before the event, also after a re-add (decision 2026-10-07; the earlier re-add skip is gone); nothing-to-revoke events are a recorded 200; schema gate; `user.deleted` in every tenant | code done; 0008 applied on staging (checked 2026-10-08) | red dc48485aea49 (6 behavior failures), Worker 1566e54ae160; live proof `e2e/m4.ts` run m4muxw42bo (evidence/m4muxw42bo): webhook answered in 100 ms, provider tunnel 404 116 ms after it was sent, the running ping's last reply 17 ms before it and no reply after (17 losses), signed peers 404, retry 200 duplicate with 0 provider calls and 0 audit rows, cache entry revoked, every provider id 404 after cleanup. Every webhook answer is logged with its reason (red ddbcb9dd14ed, fix a11f31c1cffe). Staging ran 1566e54ae160 from 09:10:36Z without 0008, so the real delivery at 09:13:04Z got 503 `first_seen_store` and left no row; Svix retries it after 0008 is applied |

| Device IPv6 address rules (transport.md 7 and 13.6, bead cx-wb5.45): a device publishes its global IPv6 address with its install-key signature (`POST /v1/devices/{id}/signed/address`); each VM its ACL allows accepts UDP 4101 from that /128 (`{cidr} -> {vm, udp, 4101}`), filling only the rule room the policy left; new rule before old delete; the device close deletes them as the mesh writer; one change per device per 10 s; over IPv6 the address must be in the request's /64; migration 0009 | code done; 0009 applied on staging before this push | red b0dc843e92f2, fix 1bfc3e4d6da9; review fixes 8192283abc1a/cec68f7fadd8 and 17164d7699/8619c095fcd4 |

The 2026-10-08 staging check (`pscale sql cmux-prod staging --org cmux`, role reader) found 0001-0008 applied with the Worker role's table grants; the "not applied" notes above were out of date.

Open: G1 live delivery, G2-G4 (section 9); ACL preview, versions, apply ids and `PATCH` device (section 5 rows not built yet); device-to-device overlay (section 7.2); the 60 s membership sweep (section 3) is not built and not needed: M3 checks the owner on every device-signed call and code use, M4 caches positive answers 60 s and revokes on the webhook.

### Operations: migrations before deploys (2026-10-07)

A push to `feat-cmux-next` deploys `cmux-vm-staging` within about 2 minutes, so each migration is applied (with its grants) on staging BEFORE the push that needs it, and the report names the migration before the push. Staging ran 1566e54ae160 without 0008 from 09:10:36Z and every Stack webhook got 503. Guard: `src/db/schema-check.ts` lists the tables, columns and privileges this build needs; on an isolate's first request the Worker checks them with one catalog query and, while anything is missing or the check fails, answers 503 on every route except `/healthz` and logs `cmux_vm_schema_not_applied` with the missing items, so the staging smoke test fails at once. Every new migration adds its items to `REQUIRED_SCHEMA`.

Production: no `cmux_vm` migration is applied there (main is parked; nothing is deployed). Before any `main` merge that deploys cmux-vm to production, apply 0001-0008 and all their grants on the production branch first, each rehearsed on staging; otherwise the schema gate answers 503 on every route.
