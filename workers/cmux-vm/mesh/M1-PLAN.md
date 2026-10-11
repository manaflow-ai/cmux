# cmux mesh M1: first working slice (cx-0op)

Status: plan, 2026-10-07. Design: `workers/cmux-vm/mesh/DESIGN.md` on `feat-cmux-mesh` (862c194f7d8d), decisions CMUX-MESH-EXPERIMENT (+ amendment 1) and CMUX-VM-API. Goal: one device reaches one cmux VM over its own Freestyle tunnel, with the ACL owned by the cmux VM API, behind an experiment flag. Each slice lands red first (failing tests commit), then green, on its own branch, then onto `feat-cmux-next`.

Base. The cmux VM shapes M1a builds on (ownership table, `QuotaExceeded.budget`, team admin, coverage manifest, migration 0003) are on `feat-cmux-vm-s3a` (85587cd9627f), not yet on `feat-cmux-next`. M1a therefore branches from `feat-cmux-vm-s3a` (`feat-cmux-mesh-m1a`) and lands on `feat-cmux-next` only after S3a has landed there; M1a never lands S3a by itself. M1b (Rust, standalone) and M1c (script) do not depend on S3a and branch from `feat-cmux-next`.

Bound facts (DESIGN.md 1.4): no tunnel-to-tunnel forwarding; 200 rules per resource (we cap at 180); rule changes take effect in 35/65 ms p50/p95; returned configs lack keepalive and the gateway forgets idle state between 300 and 600 s, so the client sets PersistentKeepalive 25; MTU 1280 is safe; the first handshake of a new tunnel can stall 11-16 s; any tunnel traffic wakes a paused VM; egressIpv4 works with an egress rule.

## Flag

`CMUX_VM_MESH_EXPERIMENT` (Worker var, `"1"` enables) and `CMUX_VM_MESH_TENANT_IDS` (comma or space separated Stack team ids). A request to any mesh route answers 404 `{"_tag":"NotFound","message":"Not found"}` unless both hold for the caller's tenant, checked after authentication and before any store or upstream call. Default off in every `wrangler.jsonc` environment.

## M1a: Worker (TypeScript, `workers/cmux-vm`)

Resources (public ids, opaque like `vm_`): `mesh_` (upstream VPC), `dev_` (no upstream id; owns one tunnel), `tun_` (upstream tunnel). New `ResourceKind`s `mesh`, `device`, `tunnel` in `cmux_vm.resources`.

Endpoints (all tenant-scoped; another tenant's id is 404):

| Endpoint | Scope | Notes |
| --- | --- | --- |
| `POST /v1/meshes` `{displayName?}` → 201 `Mesh` | `mesh:write` (+ team admin for sessions) | creates the VPC with a unique /20 from `10.128.0.0/9`; budget `mesh.perTenant` = 1 |
| `GET /v1/meshes`, `GET /v1/meshes/{meshId}` | `mesh:read` | ownership table only |
| `DELETE /v1/meshes/{meshId}` | `mesh:write` (+ admin) | 409 while devices or VMs are members |
| `POST /v1/meshes/{meshId}/devices` `{name, wgPublicKey}` → 201 `{device, tunnel}` | `mesh:join` | creates the upstream tunnel with the device key (`clientPublicKey` always set; a minted private key in the response deletes the tunnel and fails closed), `routes` = the mesh /20, inline VPC attach; budget `device.perMesh` = 50 |
| `GET /v1/meshes/{meshId}/devices`, `GET /v1/devices/{deviceId}` | `mesh:read` | |
| `DELETE /v1/devices/{deviceId}` | `mesh:join` | deletes the tunnel first (its rules go with it upstream), then the rows |
| `GET /v1/tunnels/{tunnelId}` → `TunnelConfig` | `mesh:read` | `endpointHost`, `endpointPort`, `serverPublicKey`, `interfaceAddress`, `meshAddress`, `allowedIps`, `mtu` 1280, `persistentKeepaliveSeconds` 25; never a private key |
| `PUT /v1/meshes/{meshId}/vms/{vmId}` → `MeshMember` | `mesh:write` + `vm:write` | `update_vm_networks` (live); records the VM's mesh address |
| `DELETE /v1/meshes/{meshId}/vms/{vmId}` | `mesh:write` + `vm:write` | removes the VM's mesh rules, then detaches |
| `GET /v1/meshes/{meshId}/acl` | `acl:read` | current version and document |
| `PUT /v1/meshes/{meshId}/acl` `{expectedVersion, rules}` → `AclApplied` | `acl:write` (+ admin) | compile, then create-before-delete apply; returns version, created/deleted counts, apply ms; 409 on a stale `expectedVersion`; budget `aclApply.perMeshPerMinute` = 10 |
| `GET /v1/devices/{deviceId}/peers` → `PeerMap` | `mesh:join` | the VMs this device may reach and on which ports, compiled from the current ACL |

ACL document (M1 subset of the NP shape): `rules: [{src: ["dev_…" or "device:*"], dst: ["vm_…" or "vm:*"], allow: ["tcp:8080", "udp:53", "icmp", "*"]}]`, default deny. Compile emits one upstream rule `{tunnelId} → {vmId, protocol, port}` per (device, VM, port); every name must be a member of this mesh (`SameMesh`), and a policy that would put more than 180 rules on one VM or tunnel, or more than 500 on the mesh, is refused with `QuotaExceeded` budget `firewallRule.perResource` or `firewallRule.perMesh` before any upstream call. Device-to-device and VM-to-device tuples are refused in M1 (no tunnel forwarding; overlay is a later slice).

Proofs (minted only in `src/proofs/`): `TenantOwnsResource` extended to `mesh`, `device`, `tunnel` (same WeakMap evidence pattern); `SameMesh<C, M, R>` = resource `R` (device, tunnel or VM) is a live member of mesh `M` of caller `C`'s tenant; the upstream mesh client's `createFirewallRule` requires a `SameMesh` for both ends, `createTunnel` requires `TenantOwnsResource` of the mesh plus `TenantMayCreate<C, "device">`, `attachVm` requires ownership of both mesh and VM.

Budgets: `QuotaExceeded.budget` gains `mesh.perTenant`, `device.perMesh`, `firewallRule.perMesh`, `firewallRule.perResource`, `aclApply.perMeshPerMinute`, `firewallRule.account` (upstream 409 "account is at its firewall rule limit"). All checked before the upstream call.

Audit: one row per mutation (`mesh.create`, `mesh.delete`, `device.create`, `device.delete`, `mesh.vm.attach`, `mesh.vm.detach`, `acl.apply`), public ids only.

Migration `0004_cmux_vm_mesh.sql` (schema `cmux_vm` only, additive, no GRANTs): widen the `resources` kind/prefix CHECKs and the `audit_log.cmux_id` CHECK to accept `mesh_`, `dev_`, `tun_`; new tables `mesh_cidrs` (mesh, /20 slot, UNIQUE), `mesh_devices` (device, mesh, tunnel, owner, wg public key, created_at, deleted_at), `mesh_members` (mesh, VM, mesh IPv4, attached_at, detached_at), `mesh_acl_versions` (mesh, version, document, sha256, author, created_at; UNIQUE (mesh, version)), `mesh_firewall_rules` (mesh, rule key, upstream rule id, created_at, deleted_at; never exposed). The grant statements go in the hand-off, not the file.

Coverage manifest: `create_vpc`, `get_vpc`, `delete_vpc`, `create_tunnel`, `get_tunnel`, `delete_tunnel`, `create_firewall_rule`, `list_firewall_rules`, `delete_firewall_rule`, `update_vm_networks` move to `wrapped`; `rotate_tunnel_key`, `attach_vpc_to_tunnel`, `detach_vpc_from_tunnel`, `list_vpc_tunnels` stay `planned` (cx-0op); free-standing rule CRUD on mesh resources is not offered.

Files (new unless marked): `src/api/mesh.ts`, `src/handlers/mesh.ts`, `src/handlers/mesh-acl.ts`, `src/mesh/acl.ts` (pure compiler), `src/mesh/flag.ts`, `src/db/mesh.ts`, `src/proofs/same-mesh.ts`, `src/upstream/mesh.ts`, `src/upstream/live-mesh.ts`, `migrations/0004_cmux_vm_mesh.sql`, `test/support/mesh-fakes.ts`, `test/workers/mesh.test.ts`, `test/workers/mesh-isolation.test.ts`, `test/node/mesh-acl.test.ts`, `test/node/mesh-store.pg.test.ts`. Edited: `src/api.ts`, `src/app.ts`, `src/index.ts`, `src/errors.ts` (budget names), `src/lib/ids.ts` (kinds), `src/domain/scopes.ts` (`mesh:read`, `mesh:write`, `mesh:join`, `acl:read`, `acl:write`), `src/proofs/tenant-owns-resource.ts`, `test/support/harness.ts`, `test/support/endpoints.ts`, `test/workers/isolation.test.ts` (table coverage), `upstream/coverage.json`, `openapi.json` (generated), `wrangler.jsonc` (flag vars off).

Tests (red first): flag off and tenant not allowlisted → 404 with no upstream call; create mesh, enroll device (upstream body carries `clientPublicKey`, `routes` = the /20, no private key; a minted key in the response deletes the tunnel); every mesh endpoint answers 404 to another tenant (key with all scopes and signed-in member) and calls nothing upstream; 403 without the scope; budgets return 429 with the budget name and no upstream call; ACL compile unit tests (port expansion, `*`, foreign or non-member names refused, 180 per resource, create-before-delete order, stale version 409); peer map lists only what the ACL allows; audit rows for every mutation; the pg store test runs 0001-0004 on PGlite.

## M1b: device agent (Rust, `workers/cmux-vm/mesh/agent`)

A standalone Cargo workspace (own `Cargo.toml`, `Cargo.lock`, a regular-file `rust-toolchain.toml`, no symlinks), binary `cmux-mesh-agent`:

- `keygen` makes an X25519 key in a 0600 file; the private key never leaves the process or that file.
- `enroll --api URL --mesh mesh_… --name N` registers the public key (`POST /v1/meshes/{meshId}/devices`), saves the returned tunnel config (no key in it).
- `peers` fetches `GET /v1/devices/{deviceId}/peers`.
- `up` brings up ONE userspace WireGuard session (no root, no Network Extension, no system interface): PersistentKeepalive 25 s, MTU 1280, endpoint from the config, first-handshake retry (the 11-16 s stall).
- `ping <peer> [-c N]` ICMP echo through the tunnel; `tcp <peer> <port>` connect test (and a line echo when the server answers); `probe <peer> <port> --interval-ms 50` emits one JSON line per attempt for M1c's block/allow timing.

Transport: reuse `cmux-tui/crates/cmux-wg` by path if its public API gives TCP and raw ICMP without changing cmux-tui files; otherwise boringtun + smoltcp directly (ICMP and TCP sockets), with the reason recorded in the crate README. Tests on a Blacksmith Testbox: an in-process loopback (two boringtun peers, one acting as the VM with an ICMP responder and a TCP echo) proves ping and TCP; config parsing and the keepalive/MTU defaults are unit tests. macOS build and the live run happen on cmux-lawrence-2 in M1c.

## M1c: end-to-end proof (`workers/cmux-vm/mesh/e2e/`)

`run-m1.sh` on cmux-lawrence-2 (userspace only, no sudo): starts `serve.ts`, the cmux VM API's real `makeWebHandler` composed in bun with in-memory stores and limits, the experiment flag on for one dev/test tenant (`team_mesh_m1_<run>`), and the live upstream client with the dev key loaded into an env var inside the script (the key file is only `stat`ed by the caller); no database, so no migration is applied anywhere. Through the cmux VM API only: create a mesh, create one VM (`idleTimeoutSeconds` 300, egress for the test server), join it to the mesh, start a TCP server on 8080 via exec, enroll the agent's key, apply an ACL `device → vm: tcp:8080, icmp`; the agent proves `ping` and `tcp`. Then the ACL drops `tcp:8080` (agent probe every 50 ms records time from the PUT send to the first refused connect), then allows it again (time to the first good connect), 5 rounds each. Cleanup deletes device, VM membership, VM and mesh by exact cmux id through the API, and a ledger of every upstream id is checked by exact id against the provider (404 each). At most 20 live resources; the ledger and the proof output are committed under `e2e/evidence/`.

## Beads

`cx-0op.M1a`, `cx-0op.M1b`, `cx-0op.M1c` (children of cx-0op, BD_ACTOR=cmuxterm-hq-ff), closed with the landed SHAs.
