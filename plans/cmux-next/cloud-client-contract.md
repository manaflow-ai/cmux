# cmux-next Cloud: client side and API contract (proposal)

Status: ACCEPTED by the backend lead 2026-10-04 (02cec80fd42, `state-placement.md` section 5 and 6;
where they differ, state-placement.md wins). Cloud lead v2 (R121 redirect).
Owners: the backend lead owns the new Cloud backend (API Worker, Durable Objects, PlanetScale MySQL,
Freestyle calls) and the state split. The Cloud lead owns the client side: `cmux-cloud` (the app
server in `first-party-apps/cloud/server`), the Cloud page, the Swift glue, and this contract.
Inputs: Lawrence R121 ("no production cloud VM infra; Worker/DO <> Freestyle; no merges to main"),
his answers (same Freestyle account with new cmux-next keys; migrate classic users; MySQL only),
plans `cloud-app.md`, `transport.md`, `team-vm-plan.md`, `identity.md`, backend catalog
`backend/catalog/cloud-operations.json` (protocol `cmux.wire/1`).

## 0. Summary

1. The client talks to one backend: the cmux-next API Worker, through `cmux.wire/1` ops
   (`POST /v1/read`, `POST /v1/ops`) and the WebSocket wire (`/v1/wire/user`, `/v1/wire/team`).
   No call goes to `web/app/api/vm`, Vercel, the classic Postgres, the GCP edge or the classic
   image pipeline.
2. Every Cloud op is a row in the backend catalog, family `cloud.machine.*` and friends, owner
   `cloud:<DO>`. The client catalog fragment (`first-party-apps/cloud/catalog/cloud-catalog.json`)
   is generated from those rows plus client-only ops (connect, ports, browser, transfers). One op
   name on both sides; the old relay names and HTTP routes go away. Owner: `cloud:CloudDO`, one
   object per team (state-placement.md 5.1).
3. Auth is the cmux-next identity: a signed-in session or an install token (`principals`).
   `cmux-cloud` never holds a token. The host adds it (credential relay, now an install token, not
   a Stack bearer). Because install tokens work on the backend, the relay can live in the daemon,
   so CLI and MCP Cloud ops work without the Mac app.
4. The data plane (terminal, files over the daemon, ports, browser proxy) does not go through the
   backend. The VM daemon joins the cmux-next overlay at bind (transport.md: end-to-end WireGuard,
   VPC path, `HostDO` relay fallback). The client dials the machine's host id through `cmux link`.
   The backend gives the identity and the peer map entry, never bytes. The one exception is the
   rescue shell (section 2.6).
5. Classic users migrate per user, one way, opt-in from the new app (section 4). Classic VMs appear
   as "Classic" machines with a reduced op set until the user upgrades each one.

## 1. What the client needs from the backend (contract)

### 1.1 Conventions (all ops)

- Protocol `cmux.wire/1`. Reads: `class: read`, `idempotency: forbidden`. Mutations: `class:
  mutation`, `idempotency: required`; the client sends one key per user intent and reuses it on
  every retry (today's `Idempotency-Key` rule moves into the wire envelope). The one exception is
  `cloud.machine.link_token` (`idempotency: none`, section 1.7): each call mints a fresh token.
- A provider call cut off mid-flight answers `mutation.indeterminate`; the client retries the same
  key and never makes a new one (C7's delete retry logic maps to this one code).
- Every mutation result carries the entity `revision`; the client applies it to its projection and
  drops any older event (C4i watch/revision logic survives).
- Principals: `session` and `install` for reads and ordinary mutations. Money and destructive ops
  (`machine.create`, `machine.delete`, `machine.resize`, `machine.upgrade`, `snapshot.create`,
  `snapshot.restore`, `snapshot.delete`, `billing.checkout`, `migration.start`) never use the default
  install grants (coordinator decision, 2026-10-04): they need a user principal (session), or, after
  the origin window lands, an install carrying a fresh single-use `origin.confirmation` token from the
  native confirmation sheet (decision ORIGIN). Until then an install is refused with `auth.forbidden`,
  also when its grant lists money or destructive; agent principals (`agt` claim) are always refused.
  Vectors: `machine.create.install`, `machine.delete.install` (refusals) and
  `machine.create.install_confirmed` (marked PENDING ORIGIN).
- Target: `team` (a personal account is a team of one). Ownership: a machine belongs to a team and
  has a creator user; v1 shows the caller's own machines and the team machines the policy allows.

### 1.2 Entities the client reads

| Type | Fields the client uses |
| --- | --- |
| `CloudMachine` | `id` (`vm_…`), `team`, `creator`, `name`, `size {cpu, memory_mb, disk_mb}`, `status` (`provisioning`, `starting`, `running`, `pausing`, `paused`, `deleting`, `failed`), `image {id, daemon_version}`, `host` (overlay host id, null until bound), `classic` (bool), `created_at`, `last_active_at`, `idle_policy`, `error {code, message, at}`, `revision` |
| `CloudSnapshot` | `id`, `machine`, `name`, `size_mb`, `status`, `created_at`, `revision` |
| `CloudPlan` | `plan_id`, `limits {max_active, max_saved, memory_options_mb, locked_memory_options_mb, vm_hours_included}`, `usage {active, saved, vm_hours_used, period_end}` |

### 1.3 Ops (v1)

| Op | Class | Params | Result | Errors beyond the standard set |
| --- | --- | --- | --- | --- |
| `cloud.machine.list` | read | `{cursor?, limit? (1..100)}` | `{machines: [CloudMachine], next_cursor, revision}`; no cursor = first page | |
| `cloud.machine.get` | read | `{machine}` | `CloudMachine` | `cloud.machine.not_found` |
| `cloud.machine.create` | mutation | `{name?, size, image?, from_snapshot?}` | `{machine: CloudMachine}` (status `provisioning`) | `cloud.plan.required`, `cloud.quota.exceeded {limit, used}`, `cloud.size.locked`, `cloud.provider.unavailable` |
| `cloud.machine.rename` | mutation | `{machine, name}` | `{machine}` | |
| `cloud.machine.start` | mutation | `{machine}` | `{machine}` | `cloud.quota.exceeded` |
| `cloud.machine.pause` | mutation | `{machine}` | `{machine}` | |
| `cloud.machine.resize` | mutation | `{machine, size}` | `{machine}` | `cloud.size.locked`, `cloud.quota.exceeded` |
| `cloud.machine.delete` | mutation | `{machine}` | `{deleted: true}`; a retry after delete answers the same | |
| `cloud.machine.idle_policy.set` | mutation | `{machine, idle_seconds}` | `{machine}` | |
| `cloud.machine.connect_info` | read | `{machine}` | `{host, daemon_version, capabilities}` | `cloud.machine.not_bound` (still provisioning), `cloud.machine.paused` |
| `cloud.snapshot.list` | read | `{machine?}` | `{snapshots}` | |
| `cloud.snapshot.create` | mutation | `{machine, name?}` | `{snapshot}` | `cloud.quota.exceeded` |
| `cloud.snapshot.restore` | mutation | `{snapshot, name?}` | `{machine}` (a new machine) | as create |
| `cloud.snapshot.delete` | mutation | `{snapshot}` | `{deleted: true}` | |
| `cloud.plan.get` | read | `{}` | `CloudPlan` | |
| `cloud.billing.checkout` | mutation | `{plan}` | `{url}` (opened in the browser; no card data in cmux) | |
| `cloud.shell.open` | mutation | `{machine, cols, rows}` | `{stream}` (a wire stream id, section 2.6) | `cloud.machine.paused` |
| `cloud.migration.status` | read | `{}` | `{state, classic_count, imported: [..]}` | |
| `cloud.migration.start` | mutation | `{}` | `{state}` | `cloud.migration.unavailable` |
| `cloud.machine.upgrade` | mutation (risk `execute`, person-only: origin `user`, it installs software through exec) | `{machine}` (classic only) | `{machine}` | `cloud.machine.not_classic`, `cloud.upgrade.failed` |

Not in v1 (dropped with the classic VPC model or moved to other owners): `cloud.network.*`,
`cloud.tunnel.*`, `cloud.firewall.*` (the overlay and `TeamDO` policy replace them, lane 12),
`cloud.domain.*`, `cloud.publication.*` (later, backend lead), backend file routes (`cloud.fs.*` go
through the daemon on the link; section 2.4).

### 1.4 Events (on the team wire)

`cloud.machine.upsert {machine}` and `cloud.machine.removed {machine, revision}`;
`cloud.snapshot.upsert` and `.removed`; `cloud.plan.changed {plan}`. Every provider state change
(provisioning done, idle pause by Freestyle, a failure) is an event, so the client never polls.
This closes cloud-app.md DECISION 5 (machine change feed).

### 1.5 Quotas and billing, as the user sees them

The backend checks the plan before any provider call (`cloud.plan.required`,
`cloud.quota.exceeded {limit, used}`, `cloud.size.locked`) and reads the plan from the billing
owner, never from the request. The client shows `CloudPlan.limits` in the create sheet (locked
sizes disabled with the reason), the usage bar on the page, and maps each error to a localized
sentence with a "See plans" action that runs `cloud.billing.checkout`. The client never computes
a limit itself.

### 1.6 Idempotency and the resource ledger (asks to the backend lead)

1. One ledger row per provider resource (VM, snapshot) written BEFORE the Freestyle call, keyed by
   the op's idempotency key, with the provider id filled in after; a crash resumes from the row.
   The client relies on this: a retried create never makes a second VM.
2. Freestyle resource names are deterministic: `<env prefix><machine id>` with prefixes
   `cmuxnp-dev-`, `cmuxnp-stg-`, `cmuxnp-prod-` (never `cmux-`, which classic uses on the same
   account). The driver refuses a resource without its prefix, except imported classic machines
   (allowlisted by provider id). The alarm repairs a lost create by this name, so a cleanup never
   needs a list call (accepted, state-placement.md 5.2 and 5.3).
3. The Freestyle keys are Worker secrets per environment (new cmux-next keys on the same account).
   No client, VM or app server ever sees one.
4. Agent principals (`agt`) are refused by the backend for create, delete, resize up, snapshot
   delete, billing checkout and migration start. `cloud.machine.exec` exists only as an internal op
   for the upgrade path (not public in v1).
5. Deletes are idempotent: a provider 404 on delete is success, and the tombstone answers
   `{deleted: true}` for 30 days.

### 1.7 `cloud.machine.connect_info` for `cmux link` (contract for lane 12, 2026-10-04)

Purpose: `cmux link` turns a Cloud host id into a peer it can dial (`link.dial {host, service}`,
lane 12 slice 2). Owner: `cloud:CloudDO` (the machine row) with the peer data from `TeamDO`'s peer
map (transport.md section 2: `TeamDO` owns keys and reachability). Product decisions (a9,
2026-10-04): services are `daemon` and `ssh` only; scp, sftp and rsync use `ssh` with `cmux link`
as ProxyCommand; the app's own file features use daemon RPC on `daemon`; no `files` service.

Who calls: `cmux link`, through the host credential relay (the host adds the install token of the
install that runs the link). `cmux-cloud` passes only the host id to `link.dial`; it never sees
peer keys or link tokens. Principals: `session`, `install`. Class `read`. A read never mints a
credential: `connect_info` carries no token. The dial token comes from `cloud.machine.link_token`
(below), which only `cmux link` calls.

Request: `{machine}` or `{host}` (exactly one).

Result:

| Field | Type | Meaning |
| --- | --- | --- |
| `machine` | `vm_…` | the machine |
| `host` | `host_…` | its overlay host id (stable for the machine's life) |
| `epoch` | int | the VM epoch; a restore or re-bind raises it; the link refuses a hello from a lower epoch |
| `state` | `CloudMachine.status` | `running`, `paused`, `starting`, ...; peer data is returned in every bound state |
| `peer.wg_public_key` | base64, 32 bytes | the VM endpoint's WireGuard key |
| `peer.overlay_address` | IPv6 in `fd7c:6d78::/32` | derived from the host id (transport.md 3.1); the link checks it against its own derivation and refuses a mismatch |
| `peer.vpc_endpoint` | `[addr]:4101` or null | the VM's VPC address, UDP 4101 (VPC members, no tunnel) |
| `peer.public_ipv6` | IPv6 or null | for `direct_wan` when the VM has one and the policy opened it for this install's /128 |
| `gateway` | object or null | this install's own Freestyle tunnel when it is attached to the VM's VPC and the firewall rule for UDP 4101 exists: `{tunnel_id, endpoint, server_public_key, client_address, allowed_ips}`; null = no `tunnel` path for this caller (the link then reports `path_state` without it) |
| `services` | array of `daemon`, `ssh` | what this caller may dial on this host (team policy); the VM's endpoint enforces the same list |
| `daemon` | `{version, capabilities}` | as the VM reported at bind; for the client's capability gates |
| `revision` | decimal string (`cmux.wire/1` `Revision`) | the CloudDO stream sequence of the last change to this record |

Errors: `cloud.machine.not_found`; `cloud.machine.not_bound` (still provisioning; wait for the
`cloud.machine.upsert` with `host` set); `auth.forbidden` (the caller may not reach this machine;
`link.dial` maps it to `not_authorized`). A paused machine is NOT an error here: the result has
`state: paused`, and `link.dial` answers `host_paused` when the handshake fails and the cached
state is paused; the caller runs `cloud.machine.start` with an idempotency key, waits for the
`running` upsert, and dials again.

`cloud.machine.link_token` (the dial credential; CLOUD-ROUTE and LINK-TOKEN-OP, 2026-10-04): class
`mutation` with NO idempotency key (`idempotency: "none"`): each call mints a fresh token and
nothing replays, so a stored answer can never hand a credential out twice; a retry mints another.
Risk `execute`. Principals `install` only (no session). An agent (chief) token is refused
(`auth.forbidden`, decision 2026-10-04): an agent can get a dial token later only through its
owner's install principal with a confirmation, and that is a separate decision. Further rules: owner `cloud:CloudDO`, off MCP, hidden on
the CLI, never in an app's `consumes.ops`. CloudDO audits every mint; a mint commits no stream event and
the token is never cached, logged or kept in a ledger row. Request `{host, services}` (`services`: 1 or 2 unique of `daemon`, `ssh`, a subset of
what `connect_info` lists). Result `{token, expires_at, host, epoch, services}`: `token` is a
secret for one `hello` (the VM daemon checks it; a link with no valid token is closed after
`hello`), single host, single install, these services, this `epoch`; `expires_at` at most 5
minutes after the mint. Errors: `cloud.machine.not_found`, `cloud.machine.not_bound` (also for a
machine in `deleting` or `failed`), `cloud.machine.paused {machine, state}` (paused, pausing or starting: no dial to a machine that cannot answer and no automatic start; the client asks "Start machine?" and calls `cloud.machine.start`), `auth.forbidden`, `cloud.rate_limited` (per install), plus the
standard mutation and Worker gate codes.

Cache rules for `cmux link`:
1. Cache the `connect_info` result by host id for at most 300 s or until a
   `cloud.machine.upsert` with a higher `revision` arrives (key rotation, epoch change, VPC change,
   policy change all raise it). Pause and resume do not change peer data.
2. A `cloud.machine.link_token` token is used for one `hello` and never cached; a reconnect
   mints a new one.
3. On a handshake failure with a cached entry, fetch once more before reporting `unreachable`.
4. `cloud.machine.removed` drops the entry at once and closes open links to that host.

Host side, the daemon's offline limits (lane 10, 2026-10-04): when the host's token verifier
accepts a `daemon` hello, the link stamps the stream for the remote entry with
`"check":"link_token"` next to `link_peer`. The entry records that as the install's good
control-plane check (`record_remote_check`) before it binds the stream, so the 24 h / 72 h
offline limits count from the last accepted token. Only the link writes the field, only after
the verifier accepted the token, and the entry reads it only from the stamp line (before any
peer byte); a peer frame that looks like a stamp is a frame and is denied.

The entry records the field only when the daemon started with a real token verifier. The daemon
decides that once, at start, from its own config (`CMUX_LINK_TOKEN_VERIFIER` in the daemon's
environment: only the exact value `control_plane` names a real verifier; absent, unknown or
unreadable means `DenyAllTokens`), never from a stamp or a stream (`cmux_link::token::StampChecks`).
Without a real verifier a stamp that carries any `check` is malformed: the entry closes the stream
and records and binds nothing.

Limit of the stamp check (named, 2026-10-04): the entry trusts the stamp's author through the
caller check only. On macOS that check is the cmux code signature; on Linux it is the same user,
so any process of the host user can write `"check":"link_token"`. And the entry records the time
it read the stamp, not the time the control plane issued the token, so a held stream or a slow
link moves the 24 h / 72 h limits later than the token allows.

Hard gates before ANY link token format goes live (the daemon refuses to start with
`control_plane` until G1 and G2 hold, and G3 and G4 land before that code can start; `CheckBinding::BUILT` names them and tests prove the refusal):
- G1 (Linux): the entry binds `check` to the supervised link child: the stamp's writer must be the
  link process the daemon's supervisor started, named by its SO_PEERCRED pid AND that process's
  start time (so a reused pid fails). Fix F1.
- G2 (every OS): the recorded check uses the token's issue time (`iat`, carried in the stamp by the
  link after the verifier accepted the token) instead of the time the entry read the stamp. Fix F2.
- G3 (every OS, ad349 2026-10-04): the daemon logs its verifier mode (`deny_all` or
  `control_plane`) ONCE at start, with no token or secret in the line.
- G4 (every OS, ad349 2026-10-04): the daemon strips `CMUX_LINK_TOKEN_VERIFIER` from the
  environment it passes to terminals and other children, with a test that a child never sees it.
  Lane 10 finding (2026-10-05): `daemon_env.rs` builds only the caller-merged `extra_env`; a
  terminal (`PtyCommand`) and the other spawn paths inherit the daemon's process environment, so
  the strip must remove the variable from that inherited environment (every spawn path, or the
  daemon's own environment once, before any thread starts), not only in `daemon_env.rs`.
- G3 and G4 are implemented (lane 10, 2026-10-05): `main` calls
  `cmux_link::token::take_from_process_env` as its first statement (read, then `remove_var`),
  and `start_link_entry` logs one `cmux link: token verifier mode ...` line. A `cmux` client
  strips the variable too, so an owner started by `cmux server ensure` runs `deny_all`; only a
  daemon its supervisor execs directly with the variable can ask for `control_plane`.
- How a deployment selects `control_plane` (decision ad349, 2026-10-05): ONLY the Cloud host's
  boot supervisor (the image-owned service that starts, owns and re-keys the daemon,
  `cmux-devbox-boot` or its systemd unit) selects it, by exec'ing the daemon binary directly with
  `CMUX_LINK_TOKEN_VERIFIER=control_plane`. There is no `cmux server ensure` flag and no
  user-writable config file for it: the verifier mode belongs to the host image, not to the
  session user or a client, and a client or a user process must not be able to flip it. A daemon
  started any other way (a Mac, `cmux server ensure`, a user shell) runs `deny_all`. The link
  child gets the mode from the daemon that supervises it (passed explicitly at spawn from the
  daemon's OnceLock), never from the inherited environment, which closes limit (4) below.
- Keyset (VM side, lane 10, 2026-10-05): `cmux_link::keyset` reads `GET /v1/cloud/keyset` and
  the bind answer's `keyset` (schemas/link-token/keyset-vectors.json) and schedules refreshes:
  one daily deadline at a per-host jittered time, at most one unknown-kid fetch per 60 s, a 429
  holds every fetch for `retry-after` (60 s default), only an accepted 200 replaces the held
  keyset. The HTTP fetch and the timer task wire in with `host_inbound` (not in `serve` yet).

Limits that remain: (1) the host uses `DenyAllTokens` until a token format ships, so no Cloud
stream reaches the entry yet, and G1/G2 block a real verifier until F1 and F2 land; (2) a paired
Mac that is not a Cloud host has no control-plane check, so its streams stay refused (fail
closed) until a recheck driver exists; (3) a revoke in the middle of a stream depends on `HostDO`
closing the link, because nothing calls `revoke_remote_install` yet; (4) the link process does not
read `CMUX_LINK_TOKEN_VERIFIER` yet (`host_inbound` is not wired into `serve`); when it is, the link
and the daemon must read the same config.

Mapping to `link.dial` errors: `host_paused` also = `cloud.machine.paused` from link_token; `unknown_host` = `cloud.machine.not_found`; `not_authorized` =
`auth.forbidden` or a refused token; `host_paused` = handshake failure with `state: paused`;
`unreachable` = no path answered; `bad_request` = malformed op line.

Dependencies: VM bind (the backend lead: CloudDO records `host`, `epoch`, `wg_public_key` at bind
from the image's bind agent); the driver writes `/var/lib/cmux/bind.json` (0600 root, dir 0700 root)
as `{team, machine, bind_token, api_origin, env}` on every create, retry and restore (the bind request adds `install_public_jwk`, the VM's ES256 P-256 install key made per clone and kept in /var/lib/cmux/install/ 0600 root; the bind answer adds `install {id, user, grant}`: a kind "vm" install of the machine's creator, bound to the team and the machine, grant `vm-self`, tokens through /v1/auth/challenge and /v1/auth/token; an epoch raise replaces it, and an old VM install can do nothing because the machine names only the current one): `api_origin`
is the https origin from the Worker var `CLOUD_API_ORIGIN` (no write if it is not https) and `env`
is `dev`, `stg` or `prod`, the same tag as the token's `iss` `cmux:cloud:<env>`; the image's agent
refuses an origin not on its per-environment allowlist, binds, deletes `bind.json` and writes
`bound.json` `{host, epoch}`; `TeamDO` peer map and the Freestyle tunnel and rule reconciler (lane
12); for `ssh`, the VM's sshd trusts the team SSH CA (`team_vm.ssh_cert`, team VM lead), so scp and
sftp use short-lived certificates, never a static key.

## 2. How the client uses it

### 2.1 Process shape (unchanged)

The app supervisor starts `cmux-cloud` on demand. The page, the sidebar, the CLI and MCP all call
`cmux.cloud.*` ops on `cmux-cloud`. `cmux-cloud` keeps the machine projection (from
`cloud.machine.list` plus the team wire events) and owns one link per machine.

Routing (D-ROUTE, accepted 2026-10-04): the backend catalog
(`backend/catalog/cloud-operations.json`) is the single owner of the client-facing `cloud.*`
names; the Cloud app's fragment declares none of them and names the ones it serves in
`cmux-app.v2.json` `consumes.ops`. The host routes those consumed ops to `cmux-cloud`, never
straight to the backend, so the projection, the ledger, the origin rules and the argument checks
always run. The app types (`cmux-app.d.ts`) must come from `cmux-cloud`'s own schemas (what it
answers: `{machine, revision}`, no `expected_revision`, no credential), not from the backend rows.
OPEN: `gen-cmux-global.ts` types every backend row from the backend catalog and reads no
`consumes`, so this needs a generator change (owner: app platform). The same generator gives
`cloud.machine.link_token` the app scope `cloud:execute` (its `scopeFor` reads only the risk, not
`mcp.expose`, `principals` or "never consumed by an app"); it must be in the app global's `never`
list before any route sends app `cloud.*` calls to the backend.

### 2.2 What of today's server code survives (9.1k lines)

| Module | Fate |
| --- | --- |
| op loop, catalog fragment, `ops/machine*`, `ops/snapshot*`, `ops/plan*`, `machine_projection`, watch/revision, `delete_retry`, `api/ledger` | keep; the param and result shapes move to section 1.3 |
| `api/control_plane.rs` (`ControlPlane` trait) | keep the trait; replace `HttpCall {method, path}` with a wire call `{op, params, idempotency_key}` and the `x-cmux-vm-error` mapping with wire error codes |
| `api/relay.rs`, `host.rs`, `serve.rs` | keep; the credential relay sends wire calls and adds the install token |
| `link/` (supervisor, spawner, argv for `remote connect --wireguard-hub`) | rewrite to dial `connect_info.host` through `cmux link` (lane 12); the supervisor shape stays |
| `connector/`, `rescue/` (C13 pump, frames, open_token) | keep; C13 continues as planned |
| `ports/`, `proxy/`, file transfers on the link | keep; they ride the link |
| `fs/` over OpenSSH scp | delete; files go over the daemon on the link (2.4) |
| `ops/network*`, `ops/domain*`, firewall/tunnel/publication | delete for v1 |
| recorded fixtures of `/api/vm` | replace with fixtures of the wire ops (shared with the backend tests as vectors) |

### 2.2a Per-file plan (`first-party-apps/cloud/server`, 9,155 lines at 9d3a4b43543)

KEEP = no change of behavior (rename of op names or shapes only through the catalog). CHANGE = same
role, new backend or transport underneath. DELETE = gone in v1. NEW = files the swap adds.

| File | Lines | Fate | What happens |
| --- | --- | --- | --- |
| `src/main.rs`, `src/lib.rs` | 12, 23 | KEEP | module list loses `fs/openssh` etc. |
| `src/clock.rs` | 69 | KEEP | |
| `src/app_env.rs` | 201 | CHANGE | env allowlist stays; child env for `ssh`/`scp` goes; adds only what `cmux link` needs |
| `src/api/mod.rs` | 21 | KEEP | |
| `src/api/wire.rs` | 63 | KEEP | the host-to-server op line (`apps-run`) does not change |
| `src/api/host.rs` | 156 | KEEP | host-only ops (`link.get`, `connector.open`) stay |
| `src/api/serve.rs` | 171 | KEEP | serve loop and single inbox stay; gains the team wire event input |
| `src/api/ledger.rs` | 123 | KEEP | replay by idempotency key stays |
| `src/api/call.rs` | 82 | CHANGE | `Ctx` makes one wire call `{op, params, key}` instead of an `HttpCall` |
| `src/api/control_plane.rs` | 57 | CHANGE | trait stays; `HttpCall{method, path, body}` becomes `WireCall{op, params, idempotency_key}`; `HttpReply` becomes a wire result or wire error |
| `src/api/relay.rs` | 380 | CHANGE | `HostRelay` sends wire calls; the host adds the install token (not a Stack bearer) |
| `src/api/error.rs` | 97 | CHANGE | maps `cmux.wire/1` codes (`cloud.quota.exceeded`, `mutation.indeterminate`, ...) instead of `x-cmux-vm-error` |
| `src/api/args.rs` | 111 | CHANGE | path-segment checks go (no paths); id and name checks stay against the new schemas |
| `src/api/models.rs` | 224 | CHANGE | records follow section 1.2 (snake_case `cmux.wire/1` types, `host`, `classic`, `revision`) |
| `src/ops/mod.rs` | 468 | CHANGE | dispatch, origin rules and idempotency stay; the `network` and `domain` groups go; `migration` and `upgrade` come |
| `src/ops/machine.rs` | 181 | CHANGE | same ops on wire calls; `stats` goes (not in v1); `connect_info` read added |
| `src/ops/machine_projection.rs` | 138 | CHANGE | revision stays; fills from list plus `cloud.machine.upsert/removed` events |
| `src/ops/snapshot.rs` | 72 | CHANGE | `fork` goes (restore makes a new machine) |
| `src/ops/plan.rs` | 36 | CHANGE | reads `cloud.plan.get`; `usage.get` folds into it |
| `src/ops/auth.rs` | 27 | KEEP | the host answers sign-in state |
| `src/ops/delete_retry.rs` | 94 | CHANGE | per-kind not-found codes become one rule: retry on `mutation.indeterminate` with the same key |
| `src/ops/domain.rs` | 124 | DELETE | publications later, on the new backend |
| `src/ops/network.rs` | 85 | DELETE | overlay replaces VPC/tunnel |
| `src/ops/network_args.rs` | 165 | DELETE | |
| `src/ops/network_firewall.rs` | 134 | DELETE | `TeamDO` policy replaces firewall rules |
| `src/ops/network_models.rs` | 170 | DELETE | |
| `src/link/mod.rs` | 185 | KEEP | attach ops entry |
| `src/link/supervisor.rs` | 446 | KEEP | one link per machine, single writer |
| `src/link/park.rs` | 104 | KEEP | ops wait for a link without blocking the loop |
| `src/link/ops.rs` | 315 | CHANGE | connect calls `cloud.machine.connect_info`, starts a paused machine, waits for the `host` upsert |
| `src/link/config.rs` | 234 | CHANGE | link details from `cmux.host.link.get` for `cmux link`, no hub socket |
| `src/link/spawner.rs` | 177 | CHANGE | spawns or asks `cmux link` to dial a host id (lane 12) |
| `src/link/argv.rs` | 157 | DELETE | the `remote connect --wireguard-hub` argv goes with the classic transport |
| `src/connector/mod.rs` | 128 | CHANGE (C13) | `connector.open` app-to-host, frames, pump. STATUS: iface swap done (shared `cmux-terminal-iface`); the frame data plane is not used yet: the link reports `DataPlane::Socket {path}` (shared crate, cldv3-iface) and refuses data/credit frames as `invalid`, bytes ride the carrier socket; close by channel and the `ConnectorEvent` drain are trait methods now; the PUMP is the next Cloud lane item, C13b uses the carrier socket behind one adapter until then |
| `src/connector/iface.rs` | 127 | DELETE (C13) | replaced by `cmux-terminal-iface` |
| `src/rescue/mod.rs`, `src/rescue/backend.rs` | 10, 342 | KEEP (C13 frames) | the byte terminal stays |
| `src/rescue/iface.rs` | 332 | DELETE (C13) | replaced by `cmux-terminal-iface` |
| `src/rescue/transport.rs` | 86 | CHANGE | `MissingRescueRoute` becomes the `cloud.shell.open` wire stream. GATE: the live stream may land only with the held-output bound (`rescue/stream.rs` MAX_HELD_BYTES, retryable `lost` output_overflow) or transport backpressure |
| `src/ports/mod.rs`, `ops.rs`, `listener.rs`, `loopback.rs`, `tunnel.rs` | 234, 201, 214, 299, 61 | KEEP | loopback streams ride the link |
| `src/proxy/mod.rs` | 212 | KEEP | browser proxy route on the link |
| `src/fs/mod.rs` | 64 | CHANGE | only provider + transfers over the link |
| `src/fs/provider.rs` | 147 | CHANGE | calls the VM daemon's file ops on the link instead of `files.rs` |
| `src/fs/path.rs` | 108 | KEEP | guest and local path checks |
| `src/fs/running.rs`, `src/fs/cancel.rs` | 360, 62 | KEEP | worker thread, cancel, transfer list stay |
| `src/fs/transfer.rs` | 304 | CHANGE | push/pull stream over the link; fixes "a cancelled push deletes the partial file" there |
| `src/fs/files.rs` | 209 | DELETE | no backend file routes (C2) |
| `src/fs/openssh.rs` | 303 | DELETE | no scp |
| `src/fs/key.rs` | 99 | DELETE | no per-transfer SSH key |
| `src/fs/known_hosts.rs` | 151 | DELETE | no SSH host keys (the overlay authenticates hosts) |
| NEW `src/ops/migration.rs` | | NEW | `cloud.migration.status/start`, `cloud.machine.upgrade` |
| NEW `src/api/events.rs` | | NEW | team wire events into the serve inbox |
| NEW `src/fs/link_files.rs` | | NEW | file ops over the daemon link |

Tests (`tests/`, 36 entries): KEEP `attach_connector`, `attach_link`, `attach_rescue`, `child_env`,
`delete_retry`, `host_link`, `link_events_once`, `machine_not_found`, `machine_ops`, `machine_watch`,
`manifest`, `open_token`, `ports_forward`, `ports_loopback`, `ports_proxy`, `relay`,
`rescue_conformance`, `rescue_rules`, `serve*`, `snapshot_plan_ops`, `transfer_list` and the
`*_common` helpers, each moved to the new shapes. DELETE `domain_ops`, `network_ops`, `fs_ops`
(rewritten as link file ops), `known_hosts`, `openssh_cancel`. CHANGE `fs_transfer` (link transfer).
`tests/fixtures/` (52 recorded `/api/vm` answers) are replaced by `cmux.wire/1` vectors shared with
the backend tests.

Totals (counted): DELETE 2,056 lines (network/domain 678, fs SSH 762, argv 157, interface mirrors
459 at C13). CHANGE 3,596 lines. KEEP 3,503 lines. Total 9,155.

### 2.3 Terminal

`cloud.machine.connect`: projection says running (else `cloud.machine.start`, then wait for the
`upsert` event with `host` set), `cloud.machine.connect_info`, dial the host through `cmux link`,
then C13: `cmux.terminal.connector.open` to the host, the pump moves bytes, and the Mac client
opens a DaemonConnection on the `apps-terminal-link` socket keyed `cmux/cloud/<machine>` (C13b).

### 2.4 Files, ports, browser

Files: the app's file features (explorer, upload, download) use daemon RPC on the `daemon` link
service, streamed like classic `remote rpc --stream` (`cmux.fs.provider/1`, kind `cloud-vm`); the app
never runs scp. scp, sftp and rsync from a shell use the `ssh` service with `cmux link` as
ProxyCommand (a9 decision, 2026-10-04). No backend file route and no static SSH key. Ports: loopback streams on the link (remote-localhost.md). Browser:
`browser.tab.open {url, machineStore{proxy}, engine: cef}` with the proxy on the link.

### 2.5 Swift path

`CmuxNextCloud` and the Cloud parts of `CloudService`/`MachineRegistry` are frozen now (they call
`web/app/api/vm`) and are deleted when 2.3 works. Slice 1 dogfood on the Swift path is cancelled.
The capability gates for older daemons (helper side branch) stay useful for SSH machines and for
classic VMs during migration.

### 2.6 Rescue shell

`cloud.shell.open` is the only byte path through the backend: the Worker opens Freestyle's
exec/terminal stream with its key and relays it as a wire stream. `cmux-cloud` serves it as a
`cmux.terminal.backend/1` byte terminal (C3/C7 rescue code). It works when the VM daemon is down
and for classic VMs before upgrade.

## 3. Dogfood order on the new backend

1. Backend lead: `cloud.machine.list/get/create/delete` + events on development with a
   `cmuxnp-dev-` Freestyle key and a cmux-next image with the bind agent.
2. Client (Cloud lead), in parallel against a fake backend that serves the section 1.3 vectors:
   ControlPlane swap, page and sidebar on the new shapes, migration screens.
3. Live: create, list, rescue shell (works before the overlay), then the overlay terminal when
   lane 12's VM endpoint and C13 land.

## 4. Classic migration (client view)

1. Detection: after sign-in, `cloud.migration.status` reports classic VMs for this user. The
   records come from a one-time read-only JSONL export per wave (encrypted, R2 bucket
   `cmux-next-migration`), imported by the admin op `cloud.migration.import` into the team's
   CloudDO as `classic: true` (state-placement.md section 6). No live connection to classic.
   Who runs the export and with which read credential is Lawrence's decision.
2. What the user sees: a one-time banner on the Cloud page, "You have N machines from cmux Cloud
   classic", with "Move them" and "Later". Before the move, classic machines are listed read-only
   with a "Classic" badge.
3. Move (`cloud.migration.start`): one way, per user. After it, the classic app shows these
   machines as moved (needs a fence on the classic side, DECISION M1), and the new backend is the
   only writer. Pause, start, snapshot and delete work at once (Freestyle-level ops). Terminal works
   through the rescue shell at once.
4. Upgrade (`cloud.machine.upgrade`, per machine, user-initiated): the backend installs the
   cmux-next daemon and bind agent into the running VM through Freestyle exec, binds it to the
   overlay, and the machine loses the "Classic" badge. A failed upgrade leaves a working classic
   machine and a typed error. Alternative: "Snapshot and recreate" on the new image.
5. Cutover: classic stays read-write for users who did not move. A date for a forced move is
   Lawrence's decision.

## 5. Decisions (through the coordinator)

- M1: the classic-side fence (`moved_to_next`, a small main PR). Prepared, merged only with
  Lawrence's verdict. Until it is live for a user, imported machines are read-only in cmux-next.
- M2: DECIDED: upgrade in place first, snapshot-and-recreate as the fallback.
- C1: DECIDED: network/firewall/tunnel/domain/publication ops are dropped in v1.
- C2: DECIDED: files only over the daemon link.
- Credential: DECIDED: the install token (state-placement.md 5.5).
- Rescue/classic exec stream: DECIDED feasible as a plain Worker WebSocket pipe (one per stream,
  idle close 10 min, max 4 per machine).

- OPEN ITEM (a9, D-MONEY accepted): ops with risk `money` (`cloud.machine.create`,
  `cloud.machine.resize`, `cloud.snapshot.create` (it counts against `max_saved`),
  `cloud.snapshot.restore`, `cloud.billing.checkout`) get no app scope and
  are in the app global's `never` list. The first-party Cloud page reaches them only through its own
  page path with a native confirm (origin `user`). Later, agents and mux principals that need to
  create or resize machines (cloud browser and CUA work) get a user-granted spend budget (per
  principal: amount, machine size cap, expiry, revocable, every spend audited), never an app scope.

## 6. Risks

- The terminal on the new backend depends on lane 12's VM overlay endpoint and bind, and on a new
  cmux-next image (owner: backend lead now that the classic pipeline is out).
- The classic export needs Lawrence's choice of operator and read credential.

### VM daemon ops (VM install at bind, coordinator and a9, 2026-10-05)

Only a kind "vm" install with grant `vm-self`, for its own bound machine (and only while the machine
names that install), may call these; a VM install has no team read, no execute and no cloud-link, and
cannot subscribe to the team's cloud stream. No idempotency key (fresh facts, never replayed).

- `cloud.vm.self.get {machine}` (read): the machine's public view.
- `cloud.vm.status.report {machine, state: running|degraded|stopping, daemon {version, capabilities},
  health?, activity {last_user_input_at?, last_agent_action_at?, active_sessions}}`: answers
  `{applied}`; at most one applied per 10 s per machine, a newer report in the window replaces the
  held one (latest wins). Activity feeds CloudDO's idle pause (no polling of the VM); only a daemon
  change emits `cloud.machine.upsert`.
- `cloud.vm.event.emit {machine, kind, at, data}`: v1 kinds agent.started, agent.finished,
  agent.needs_input, notification, browser.lease.changed {tab, state}, cua.session.started,
  cua.session.ended, service.port.opened {port, proto, process?}, service.port.closed {port}; data at
  most 4 KB, unknown fields refused, URL query strings and fragments removed, never secrets or page
  content; 10 per second, burst 50 per install (`cloud.rate_limited {retry_after_ms}`). Delivered to
  team members as the ephemeral frame `{t: "ephemeral", stream, event: "cloud.machine.event", data:
  {machine, host, kind, at, data}}`: never stored, no seq, no cursor.

Vectors: backend/catalog/cloud-vectors.json (`vm.*` cases, `machine.event.*` events).

### Pause, start and idle pause (2026-10-05)

- `cloud.machine.pause` / `cloud.machine.start`: money ops (a signed-in person, plan and quota on start,
  per-team limit). The answer is `pausing` / `starting`; `cloud.machine.upsert` brings the outcome.
- A paused, pausing or starting machine: `connect_info` answers `state`; `link_token` refuses with
  `cloud.machine.paused {machine, state}`. Nothing starts a machine on connect: the client asks the
  person ("Start machine?") and calls `cloud.machine.start`.
- Freestyle never pauses, stops or deletes a machine by itself (every Freestyle timer -1 at create), so the
  machine record stays true. Our 24 h backstop pauses a machine whose own reports show no sessions and no
  input or agent action for 24 h, for every team (bounds the cost of a forgotten machine).
  A running machine whose VM sent no report for 24 h after its last start or bind is also paused (the cost
  backstop for a silent VM; a machine that never binds counts from its create). Until the VM daemon sends
  `cloud.vm.status.report`, every machine is therefore paused 24 h after its bind or start: the app shows
  `pause_reason: no_report`. `pause_reason` on the machine says why cmux paused it: idle, no_report,
  provider_stopped or provider_paused (connect_info and link_token read the VM's real state and correct
  the record, e.g. after a poweroff inside); a person's pause or a start clears it.
- Idle pause: team policy `cloud.idlePause`, default OFF until auto-start is decided. When on, a machine
  pauses only when its own `cloud.vm.status.report` shows no sessions and no input or agent action past
  its idle policy (`cloud.machine.idle_policy.set` changes only this policy); a VM that stops reporting is
  unknown and never paused.

### Snapshots (2026-10-05)

`cloud.snapshot.create {machine, name?}` (a running or paused, bound machine; answers `creating`,
`cloud.snapshot.upsert` brings `ready` or `failed`; counts against `max_saved`), `cloud.snapshot.list
{machine?}`, `cloud.snapshot.delete {snapshot}` (the provider snapshot under its recorded name only;
`cloud.snapshot.removed {snapshot, revision}`), `cloud.snapshot.restore {snapshot, name?}` (a new machine
booted from the snapshot, every create check, a fresh bind). Create, delete and restore are money ops (a
signed-in person, per-team limit). Snapshots stay after their machine is deleted; a snapshot still being
taken when its machine is deleted finishes first (intent order), so "snapshot, then delete" keeps the state. `size_mb` is the
machine's disk size when it was taken (Freestyle reports no snapshot size).

