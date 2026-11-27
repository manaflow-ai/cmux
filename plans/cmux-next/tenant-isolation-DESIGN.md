# Tenant isolation: threat model and adversarial suite

Status: 2026-10-24, a640. Scope (Lawrence): stress test that there is no data, permission or execution
leakage between different end-user accounts of cmux-next cloud, which runs sessions on Freestyle VMs
(a205 tenant VM wrapper, a242 cloud subagents, a638 Freestyle cloud sessions, a639 Freestyle parity matrix).

"Tenant" here is one end-user account: its Stack user, personal team, installs, conversations, machines,
Chiefs and credits. A shared team is a tenant with several members; members of one team are not strangers to each other
(team RBAC is `team-roles` and not tested here). The attacker is a signed-in user of another account who holds valid
credentials for their own account and knows or guesses identifiers of the victim (ids appear in links, logs,
screenshots, support tickets and error messages, so an id is never a secret).

## 1. Assets and trust boundaries

| Asset | Where it lives | Boundary that must hold |
| --- | --- | --- |
| Account, installs, tokens | `UserDO` (key: user id), ES256 install tokens (`auth.ts`), Stack session JWT | token proves one user; the DO is addressed by the TOKEN's user, never by a parameter |
| Team data (hosts, policy, directory, SSH CA, Cloud machines, snapshots, usage) | `TeamDO`, `CloudDO`, `TeamVmDO`, `UsageMeterDO` (key: team id) | the team comes from the principal (`selectTeam` re-checks membership at `TeamDO`), not from the request |
| Conversations, messages, attachments | `ConversationDO` (key: conversation id, caller-chosen string), R2 objects keyed `<conversation>/<object>` | membership check inside the DO; attachment routes check the same membership |
| Chiefs, memory, runs | `/v1/chiefs/<agent>/...`, `ChiefBrainDO`, `<agent>/sandboxes` | owner check per route |
| Machines (Cloud VM, team VM, Chief sandboxes, turn VMs) | Freestyle VMs; public ids `vm_`, `snap_` map to provider ids per tenant | tenant A can never name, start, snapshot, fork, exec on or reach tenant B's VM |
| Provider keys (Freestyle team key, Anthropic/Bedrock, Stripe, Tailscale OAuth) | Worker secrets only | never on a VM, never in a reply, never in a log |
| Credits and spend | `UsageMeterDO`, `SpendGuardDO`, credits ledger (key: team) | a stranger cannot charge, read or cap another team |
| Operator surfaces | `/v1/internal/*`, `/v1/admin/*`, webhooks | no tenant credential opens them |

## 2. Threat model by surface

For each surface: how a tenant could attack another, what stops it today, how it is tested (T = automated here,
R = reviewed from code or config, not run, O = open).

### 2.1 VM and filesystem
- Attacks: a clone of a shared image carries another tenant's or the operator's data (credentials, repo clones, bind tokens, shell history);
  two clones share a machine-id, SSH host key or RNG state (impersonation, nonce reuse); a snapshot of A is used to create B's VM; a stale
  disk is reused for a new tenant; a VM reads provider credentials.
- Controls: per-tenant ownership table (`vm_`/`snap_` ids resolve only inside the caller's tenant, else 404; `workers/cmux-vm` README);
  per-machine secrets made after bind, never at bake (`vm-image.md` section 6, 13); the bind token is single use; the provider key stays on the Worker
  (`chief-vm-freestyle-parity.md` rules); snapshot restore only from the caller's own `snap_` ids (`cloud-snapshots.test.ts`).
- Tests: T `tenant-isolation-tokens` (B cannot snapshot, restore, delete, start, rename, shell into A's machine, nor create from A's snapshot, and each answer equals the
  answer for an unknown id; a bind token binds once and only for its own team and machine); T `backend/scripts/tenant-isolation-vms.sh` on two real small VMs
  (distinct machine-id and SSH host key, no provider secret in any process environment, no bind file left, credential and private-key scan of the image);
  T `workers/cmux-vm/test/workers/isolation.test.ts` (every Tenant API VM route as another tenant: 404, nothing reaches upstream; table must cover openapi.json).
- Findings: F2 below (personal image holds private clones).

### 2.2 Network and tailnet
- Attacks: VM A connects to VM B over the public IPv6/IPv4 address or a shared VPC; a turn VM that joined the operator's tailnet reaches other
  tenants' VMs or the operator's Macs; a tenant VM reaches the metadata address or the Freestyle control plane; WireGuard keys reused across clones.
- Controls: Freestyle drops traffic with no firewall rule; Cloud VMs join one VPC per team, one tunnel and one WireGuard key per (device, team mesh)
  (`transport.md` section 7); turn VMs join the tailnet with a one-use, per-VM key and a tag (`chief-brain-cc/vm.ts`, `boot.sh`), the agent
  user's network is closed by `net.ts` (nft) and `net-check.sh` proves it.
- Tests: T `tenant-isolation-vms.sh`: A as root dials B's public IPv6 and egress IPv4 on 22, 1337, 7420, 8080, 3000, 5432 while B listens on every interface
  (with a positive control that the probe can connect); A reaches no metadata address; the Freestyle API answers a keyless caller 401.
- Open: O1 the Tailscale ACL for `tag:agent-cloud` is not in this repo. Every turn VM joins ONE operator tailnet with ONE shared tag; if end users ever get turn VMs, the ACL
  must deny tag-to-same-tag and tag-to-operator-Mac traffic. Test to add when the ACL file is available: from VM A (tagged) `tailscale ping`/TCP to VM B's tailnet address and
  to a Mac's port 7420 must fail. Today only operator-listed owners (`CHIEF_CC_OWNERS`) use this route.
  O2 team-VPC isolation (VM in team X's VPC cannot reach VM in team Y's VPC) needs the Tenant API staging credential, which no agent has yet.

### 2.3 Hub tokens, relay ports, the `mac` gate (port 7420)
- Attacks: a Cloud Chief of tenant X drives tenant Y's Mac through the `mac` gate; a hub posting token of one tenant reads or fills another's inbox; token replay across VMs.
- Controls: the gate on 7420 checks tailnet ACL, `tailscale whois`, a bearer token and writes an audit log (`chief-browser-use-DESIGN.md`); VM install tokens carry claim `vm` and reach only
  `cloud.vm.*` for their own machine (`socket-gate`, `tenant-isolation-tokens`); the keyed acpmux start is outside the op path.
- Tests: T a VM token against another tenant's machine (`cloud.vm.self.get`, `status.report`, `event.emit` all refused) and against every user surface (403).
  T the gate port is closed from a peer VM (`tenant-isolation-vms.sh`, port 7420).
- Open: O3 the gate's bearer must be bound to one (user, Mac) pair and to the whois identity; this is the daybreak `cloud-chief-1` fix, landing in progress; add a live check from a tagged VM of tenant Y once it lands.
  O4 `cloud-chief-3`: hub posting token can grow the database without bound (retention decision; a tenant-level quota is the isolation control).

### 2.4 API authentication and authorization per account
- Attacks: IDOR (A's id in B's call, in a required or an optional parameter); existence oracles (a different answer for "exists, not yours" than for "does not exist");
  forged, tampered, expired, wrong-audience or `alg: none` tokens; token replay after revoke; a challenge signed with another key; a nonce reused; naming a victim's team on
  HTTP or WebSocket; a VM or install token used as a session; admin and webhook routes.
- Tests (all hermetic against the real Worker with fake Stack keys, plus the same sweep live on staging):
  T `tenant-isolation-idor`: tenant A owns a machine, snapshot, group, DM with a message, automation, Chief, feed item, install and host. Tenant B calls EVERY operation in the catalog
  (`backend/catalog/cloud-operations.json`, 206 ops) as a session and as an install token, with A's ids in every required id parameter and every optional id parameter, and with unknown ids
  as a control. Fails on: an A canary in any reply; any change in A's own view; any difference between the answer for A's id and for an unknown id (status, code, reply shape).
  T `tenant-isolation-tokens`: six forged session tokens, payload edits of session and install tokens, challenge signed by the wrong key, nonce single use, challenge for a mismatched user/install,
  revoked install stops at once and mints nothing, WebSockets on A's conversation and team, VM tokens, bind-token theft and replay, snapshot reuse.
  T `tenant-isolation-routes`: operator, billing and webhook routes refuse a session, install, VM token and no credential; `/v1/chiefs/<A's agent>/(brain|github|memory|peer|runs|fault)` for GET/POST/PUT/DELETE answers
  like an unknown Chief; attachment intent/commit/url on A's conversation answers like an unknown one; `x-cmux-team: <A's team>` on inference is refused; the personal Claude Code route (`ccRoute`) admits only exact allowlisted owners.
  T `backend/scripts/tenant-isolation-staging.ts`: the same sweep and token checks against the deployed staging API with two real Stack sign-ups (deleted afterwards).

### 2.5 Memory, chat and workspace ids
- Chief memory and runs are behind owner-checked routes (tested above). Conversation ids are 130-bit random strings chosen by the creator; the DO is addressed by the caller-supplied id, so the DO is the boundary (F1).
  Group workspace ids (`ws_...`) are plain strings inside a team's groups; `group.add_workspace` is swept (B naming A's group id).
- Idempotency: keys and `client_msg_id` are scoped to the principal (T `tenant-isolation-race`: two tenants send the same key and the same client message id at the same instant; neither gets the other's cached result).

### 2.6 Logs, Sentry, observability
- Attacks: a tenant's tokens, queries or content in logs another tenant (or the operator) can read; support tooling joins them.
- Controls (R): staging/production observability has `invocation_logs: false` (request headers are not recorded) and `redact_query_string: true`; logs go to Axiom per environment; `cloud-redact.ts` redacts VM log
  lines; the Sentry cron check-in in `home-health.ts` carries no tenant data; the apps scrub Sentry events (`web/tests/sentry-secret-scrub.test.ts`, `CmuxSentryScrubbing`).
- Not run here: O5 a log-content canary test (send a canary in a token, query string, body and header on staging, then search Axiom/Sentry for it). Needs the Axiom read token; add as a nightly job.

### 2.7 Billing and credits
- Attacks: charge A's credits from B (team header, team param), read A's balance or usage, set A's cap, replay a Stripe webhook, top up into A.
- Controls: team resolved from the principal; `x-cmux-team` is accepted for a session only and re-checked at `TeamDO` (`selectTeam`); credits ledger and usage meters keyed by team.
- Tests: T `usage.*`, `cloud.billing.checkout`, credits routes in the IDOR sweep (team and owner params ignored); T `x-cmux-team: <A>` on both inference routes refused; T `/v1/hooks/stripe/credits` and `/v1/internal/*` refuse tenants.
- Not run: O6 a Stripe-test-mode end-to-end where B tops up with A's team id in metadata (needs `fake-stripe` extension).

### 2.8 Shared caches
- The API Worker uses no Workers Cache API and no KV (grep, 2026-10-24). State is in Durable Objects keyed by tenant id, SQL projections (PlanetScale) keyed by tenant, and R2 keyed by conversation.
  The only shared reads are public (keyset, openapi, invite preview; the preview returns the group name for a valid unspent link by design).
- Open: O7 `home.search` reads the PlanetScale projection through Hyperdrive: its tenant filter is applied in SQL, not by the DO. It is swept (B's query must not return A's canary) but only with the hermetic fake (no
  `HYPERDRIVE` binding in tests, "HYPERDRIVE binding missing"). Needs a staging run with seeded canaries (the staging runner skips nothing here; the op returns a validation error for the sample query).

### 2.9 Snapshots, forks and reuse
- Attacks: B creates or restores from A's snapshot id; a fork inherits the parent's identity or tokens; a snapshot taken from a VM that held secrets is reused as a base for others.
- Controls: snapshot ids resolve per tenant; identity regenerated at boot of every clone (`vm-image.md` 4a/13); Chief VMs refuse to start from a home whose install key is in use by another VM.
- Tests: T API level (see 2.1). T two clones of one image have different machine-id and SSH host key (live). O8 a fork of a running VM (memory snapshot) keeps RNG state: the boot unit reseeds
  (`vm-image.md` 4a); there is no automated check yet (needs two forks of one memory snapshot and a comparison of `/proc/sys/kernel/random/boot_id` and the first 16 bytes of `/dev/urandom` read immediately).

### 2.10 Concurrency
- T `tenant-isolation-race`: 12 tenants x 4 rounds, each writing (group, feed item, machine, host) and reading nine lists at the same instant; no list ever holds another tenant's canary and each tenant sees its own (control).
  T same idempotency key and same `client_msg_id` from two tenants at once; T six strangers probing one conversation, machine and snapshot concurrently (read, delete, retitle): only refusals, nothing leaks, A unchanged.

## 3. Findings

| ID | Severity | Finding | Failing test first | Fix |
| --- | --- | --- | --- | --- |
| F1 | Low | Conversation existence oracle: for 23 calls (`message.send`, `message.edit`, `message.retract`, `reaction.*`, `participants.*`, `title.set`, `thread.update`, `read_cursor.set`, `grant.*`, `invite.revoke`, `invite.approve_join`, `ownership.transfer`, `conversation.settings.set`, `conversation.import.commit`) a stranger got `not_participant`/`forbidden` for A's conversation and `unknown_conversation` for an id that does not exist. `message.send` validated the payload first, so it also leaked. | `963b46459bb` (red, 23 differences) | `22933bb855e`: a caller who never belonged gets `unknown_conversation` (home-core `reduceConversation`, large groups through `recordOf`). People who left keep `not_participant`; the ops a stranger may send (invite accept, system ops, request dismiss, sweep) are listed. |
| F2 | Medium (gate) | The personal Claude Code turn image (`CHIEF_CC_SNAPSHOT`) holds `/home/chief/work/cmux` (1.7 GB) and `/home/chief/work/cmuxterm-hq` (1 GB, the private repo) and about 40 files with secret-shaped strings (tests and fixtures; liveness not checked). Only the `CHIEF_CC_OWNERS` allowlist keeps strangers off it. | `tenant-isolation-vms.sh` residue checks (2 FAIL on the image); `ccRoute` test pins the allowlist | No code change: a tenant image must be baked WITHOUT the clones before any non-operator owner is allowed (`bake.sh` takes `HQ_DIR`; add a `--tenant` mode). Tracked as a release gate. |
| R1 | Accepted, Low | `conversation.import` (create at a caller-chosen id) answers `conversation_exists` for an existing id whoever owns it. A create with a free id succeeds, so no reply can hide the difference. Ids are 130-bit random and never listed to non-members. | pinned in the sweep (`ACCEPTED_EXISTS`: only this code on this op) | none; decision for Lawrence: accept, or derive the DO name from `(creator, id)` (breaks id portability between brains). Default picked: accept. |

## 4. Not covered by this suite (be honest)

- Team members of one shared team (RBAC): `team-roles*.test.ts`.
- Tenant API (`workers/cmux-vm`) beyond its own isolation table: a639 adds client-sessions, linux users, paused-VM files, domains, outbound rules with credentials and VPC CRUD; each new route
  must be added to `test/support/endpoints.ts` (the table is checked against `openapi.json`) and, for a list, to the "lists never include another tenant's rows" test. Credentials must be write-only (a read never returns them).
- Real Cloud VM creation on staging by throwaway accounts: staging gates machines with `CLOUD_ALLOWED_TEAMS`, so the live runner skips `cloud.*`, `team_vm.*` and anything that spends money; the hermetic suite covers them with the fake provider.
- Production data: nothing here reads or writes production.

## 5. How to run

Hermetic (CI runs it with the API tests; about 3 minutes):

    cd backend/apps/api && bunx vitest run test/tenant-isolation-*.test.ts

Live staging API (two throwaway Stack users, deleted at the end; never production, the script refuses any other env):

    bun backend/scripts/tenant-isolation-staging.ts --report /tmp/tenant-staging.json

Live VMs (two small Freestyle VMs, ttl 30 min, deleted on exit; about 2 minutes, a few cents):

    FREESTYLE_KEY_FILE=~/.secrets/freestyle-cmux-next-staging-....key backend/scripts/tenant-isolation-vms.sh [SNAPSHOT]

## 6. Results (2026-10-24)

Landed on feat-cmux-next as 51de0b651d9..ecadd45df17. Local runs after the rebase: API tenant, home and cloud tests 401/401, home-core 404/404,
`workers/cmux-vm` isolation table 103/103. Staging live runner (run e987cd1e, before the F1 fix is deployed): 18/19, the one red is F1 on the deployed pre-fix code.
Two-VM probe on the staging chief-cc image: network and identity checks pass; the image residue checks fail (F2).
