# chief-vm: parity with the Freestyle VM API and CLI

Scope (Lawrence, 2026-10-21): the Cloud Chief's sandbox tool (`chief-vm` on the turn machine,
`backend/chief-cc/image/chief-vm.mjs`; the Worker side is `backend/apps/api/src/chief-brain-cc/sandbox*.ts`)
supports everything Freestyle VMs support, on the Chief's own VMs only.

Sources read (2026-10-21): https://www.freestyle.sh/docs/vms and every page linked from it (lifecycle, files,
base snapshots, SSH, client sessions, domains, domain verification, domain DNS, wildcard domains, VPCs,
firewall, inbound/outbound TLS, tunnels, PTY, forward auth, pricing and limits, CLI, VM CLI, domains CLI),
https://api.freestyle.sh/openapi.json (v5, 88 operations) and the `freestyle` SDK 0.2.20 sources.

## Rules

- Owner check on every verb: a VM, snapshot, VPC, firewall rule, TLS rule, tunnel or forward-auth config is
  reachable only when this Chief made it (its id in the brain's cb_config, and the `cmux_chief_sandbox`
  metadata on the VM). Anything else answers 404.
- The team API key stays on the Worker. It never reaches a VM, the turn machine, the Chief or the Mac.
- Client sessions (security model): one Freestyle identity per Chief, a VM grant only for VMs it owns with
  `allowedLinuxUsers` set explicitly (`["root", "chief"]`, never null), tokens minted and stored on the
  Worker only, short-lived (15 min, rotated by the Worker), never logged. exec and pty use the identity
  token (header `x-freestyle-identity-access-token`), so they reach only that VM as those users. Team-key
  verbs (create, resize, snapshot, fork, domains, firewall, delete, ...) stay on the Worker behind the
  owner check. The grant is revoked on VM delete; on `chief.archive` the Chief's sandboxes pause and its
  identity (with its tokens and grants) is deleted.
- Limits: a per-Chief cap on live sandboxes (`CHIEF_CC_SANDBOX_CAP`, per Chief `CHIEF_CC_SANDBOX_CAPS`,
  default 2, at most 10); sizes over the plan's per-VM maximums (`CHIEF_CC_FREESTYLE_PLAN`, default pro:
  32 vCPU / 64 GiB / 256 GB, probed 2026-10-21) are refused before Freestyle sees them.
- Per Chief, not per conversation: the sandbox list, cap, snapshots and Freestyle identity live in the
  Chief's `<agent>/sandboxes` object; a conversation brain's older list is adopted on its next call.
- Small disks (Lawrence, 2026-10-22): `create` starts from `freestyle/ubuntu-sm` (16 GB disk), grown to
  4 vCPU / 8 GiB; `--image chief` starts from the Chief's machine image (32 GB, its tools and clones).
  The Chief image could be 16 GB too (8.8 GB used) but needs a re-bake on a 16 GB base: planned.
- Cost: create, resize and list show cost per hour at Freestyle's list prices (vCPU $0.04032/h,
  GiB memory $0.0129/h, GiB storage $0.000086/h; a paused VM bills storage only).
- Public domains are allowed and every route to a public domain is logged (Worker log line, no secrets).
- Not offered: physical hardware power (`/v5/hardware/*`, a real power outlet), account-wide placeholder
  branding (changes every team's pages), and handing an SSH or client token to anyone outside the Worker
  (the security model above).

## Matrix

Status: `done` (landed, failing test first, tried on a throwaway VM), `planned` (next batch), `no` (with the reason).

| Freestyle feature | API | chief-vm verb | Batch | Status |
| --- | --- | --- | --- | --- |
| Resize (grow only, live CPU/memory, disk then guest filesystem) | POST /vms/ID/resize | `resize ID --cpu --memory-gb --disk-gb` | 1 | done (0cf77fda6fa) |
| Create sizes | create + resize | `create --cpu --memory-gb --disk-gb` | 1 | done (0cf77fda6fa) |
| List VMs | GET /vms (filtered to own) | `list` (state, size, $/h) | 1, 2 | list done; $/h in PR #24222 (batch 2) |
| Get one VM | GET /vms/ID | `get ID` | 2 | in PR #24222 (batch 2) |
| Create options: display name, metadata, idle timeout, ttl, base snapshot | POST /vms | `create --name --meta k=v --idle S --ttl S --snapshot ID` | 2 | in PR #24222 (batch 2) |
| Create options: VPC networks, firewall, inbound TLS | POST /vms | `create --vpc NAME[:IP]`, `firewall`, `domain` verbs | 4 | planned |
| Update (display name, idle timeout, metadata, ttl) | PATCH /vms/ID | `update ID ...` | 2 | in PR #24222 (batch 2) |
| Pause | POST /vms/ID/pause | `pause ID` | 2 | in PR #24222 (batch 2) |
| Start / resume | POST /vms/ID/start | `start ID` | 2 | in PR #24222 (batch 2) |
| Stop (poweroff in guest, wait for `stopped`) | exec poweroff + GET | `stop ID` | 2 | in PR #24222 (batch 2) |
| Delete | DELETE /vms/ID | `delete ID` (also revokes the grant) | 1, 2 | delete done; revoke in PR #24222 (batch 2) |
| Exec: timeout, env, stdin, Linux user | POST /vms/ID/exec-await (identity token) | `exec ID [--timeout S] [--env K=V] [--stdin FILE] [--user U] -- CMD` | 2 | in PR #24222 (batch 2) |
| Client sessions (identity, grant, token, revoke) | /identities/* | internal (security model) | 2 | in PR #24222 (batch 2) |
| Per-Chief sandbox cap | (cmux) | `cap [N]` | 2 | in PR #24222 (batch 2) |
| Cost per hour | (cmux, list prices) | in `create`, `resize`, `list`, `get` | 2 | in PR #24222 (batch 2) |
| Files: read, write (text and binary), ls, mkdir, stat, rm, exists; also while paused | /vms/ID/fs/* | `fs read|write|ls|mkdir|stat|rm|exists ID PATH` | 3 | in PR (batch 3, stacked on #24222) |
| Files: resumable upload (to 16 GiB), streaming download | /vms/ID/fs/uploads/*, fs/read | `fs put ID LOCAL REMOTE`, `fs get ID REMOTE LOCAL` (chunked) | 3 | in PR (batch 3, stacked on #24222) |
| Snapshots: create, list, get, update, delete | /vms/ID/snapshot, /snapshots/* | `snapshot create|list|get|rename|delete` | 3 | in PR (batch 3, stacked on #24222) |
| Live fork (snapshot, then a VM from it) | snapshot + create | `fork ID [--name]` | 3 | in PR (batch 3, stacked on #24222) |
| Base snapshots (public images) | create snapshotId `freestyle/*` | `create --snapshot freestyle/ubuntu` | 3 | in PR (batch 3, stacked on #24222) |
| PTY sessions, reattachable, past the 5 min exec limit | GET /vms/ID/pty (WebSocket), pty/sessions | `pty run|read|write|signal|list|close` | 5 | planned |
| VPCs: create, list, get, rename, delete, IPs; attach a VM | /vpcs/*, PUT /vms/ID/networks | `vpc create|list|get|rename|delete|ips`, `vpc attach|detach ID VPC [--ip]` | 4 | planned |
| Firewall rules: list, create, delete, evaluate | /firewall/* | `firewall list|allow|deny|delete|check` | 4 | planned |
| Domains and inbound TLS to a VM port (style.dev, own domain, wildcard) | /tls, /domains, /verifications, /certificates | `domain add ID PORT [--domain D]`, `domain list|remove`, `domain verify D`, `domain wildcard D` | 4 | planned (public routes logged) |
| Outbound TLS (credentials held outside the VM) | /tls (outbound rules, transforms) | `tls-out add|list|remove` | 4 | planned |
| Forward auth | /tls/forward-auth/* | `forward-auth create|list|get|update|delete` | 4 | planned |
| WireGuard tunnels | /tunnels/* | `tunnel create|list|get|rename|delete|rotate|attach|detach` | 4 | planned |
| SSH identity tokens | identity tokens | none | - | no: the token would leave the Worker (security model); `pty` covers shells |
| Background requests | GET /background-requests/ID | internal (long exec) | 5 | planned |
| Hardware power | /hardware/* | none | - | no: physical action on a real power outlet |
| Placeholder branding | /domains/placeholder | none | - | no: account-wide, changes every team's placeholder pages |

## Batches

Each batch: failing tests first for each verb, one PR to feat-cmux-next, merged when green; staging deploys
on merge, production by `backend.yml` target=promote of the staging-proven commit (the a161 deploy guard
stays); then each verb is tried on a throwaway sandbox that is deleted afterwards.

1. Resize and create sizes (landed straight on feat-cmux-next before the PR rule: 5407956b2c0..0cf77fda6fa).
2. Security model (identity, grants, tokens), lifecycle (get, update, pause, start, stop), exec options,
   per-Chief cap, plan limits, cost per hour.
3. Files, snapshots, fork, base snapshots.
4. Networking: VPCs, firewall, domains and inbound TLS, outbound TLS, forward auth, tunnels.
5. PTY sessions and long runs.

The turn machine's `chief-vm` comes from the snapshot (bake.sh). Until the next bake, a running turn reaches
every new action through `curl -s 127.0.0.1:4018/vm -d '{"action":...}'`; the new client ships with the
next snapshot.
