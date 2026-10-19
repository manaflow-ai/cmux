# VM identity at the TLS edge: automatic auth for machines, and machines talking to machines

Status: the identity table and peer-grant broker below are NOT implemented; instead,
**machine identity + reflection shipped on `freestyle-vm-agent-primitives` (2026-09-06)**
on top of the VM-bound route token — see "What shipped" below. Owner: cloud VM control plane.

## The problem

A cmux Cloud machine has no way to call the control plane. `/api/vm/*` accepts only a
Stack Auth user session (bearer + refresh token, or browser cookie), and nothing that
lives inside a VM may hold either — a refresh token in a guest is the user's whole
account sitting in an agent sandbox. CodeRouter credentials are held at the TLS edge;
the guest has placeholders, not a user or machine control-plane token. The earlier
Mac-brokered `cmux vm link` prototype was superseded by main's trusted private-network
listener. Existing peer-route files remain readable, but this build cannot create new
peer grants. The following design describes a future broker, not a shipped flow.

## The primitive that changes this

Freestyle's TLS rules let the **edge** hold credentials instead of the guest
(`freestyle.tls.rules`, see freestyle.sh/docs — "secret injection"):

```ts
await freestyle.tls.rules.create({
  action: "allow",
  domain: "cmux.com",                      // only this origin, ever
  source: { vmId },                        // only this VM's sessions
  destination: { public: true },
  transform: [{ headers: { "x-cmux-vm-token": "cvt_…" } }],
});
```

The edge terminates the guest's outbound HTTPS to the named domain, injects the
header, and re-originates. Properties that matter:

Both hops require HTTPS with certificate and hostname validation. Reject an HTTP
origin or an unvalidated upstream certificate before installing the injection rule;
the injected token must never traverse an unauthenticated edge-to-origin connection.

- **The guest never holds the credential.** A compromised agent can *use* the VM's
  authority while the VM lives, but cannot exfiltrate a token to use elsewhere or
  after revocation. Header values are write-only at the provider (read back `***`).
- **Identity is asserted by the platform, not the guest.** `source: { vmId }` means
  the header appears only on that VM's sessions — the VM cannot claim to be another VM.
- **Domain-pinned.** The rule names only the cmux API origin; the edge never sprays
  the header to any other host.
- **Rotation without downtime** (`tls.rules.update` keeps the rule id), and
  **lifecycle cascade**: deleting the VM deletes its rules.

## Architecture

### 1. A machine principal, not the user

At create, the control plane mints a **VM identity token** (`cvt_` + 256 random bits),
stores only its sha256 in a new `cloud_vm_identities` row
`{ vm_id, token_hash, user_id, billing_team_id, scopes, state, expires_at, revoked_at }`, with a
unique index on `token_hash` for authentication lookup, and hands the
raw token to the driver exactly once — which writes it into the edge rule above and
then forgets it. This is the same pattern as the coderouter route token (`crt_`,
sha256-stored, 30-day), which is already the house way to mint scoped machine-side
credentials.

`verifyRequest` grows a third mode: `x-cmux-vm-token` → identity row → a
**machine principal** `{ kind: "vm", vmId, userId, billingTeamId, scopes }`.
The lookup hashes the presented token and rejects missing rows, rows with
`expires_at <= now`, and rows with `revoked_at != null` before constructing any
principal. Revocation and expiration checks apply to every request.
Stack
Auth remains the authenticator of *people*; the VM token is a derived, scoped,
per-machine credential recorded against the Stack user. (Stack-native "server users"
per VM were considered and rejected: an external dependency and a heavier lifecycle
for no security gain over hash-stored tokens + edge injection.)

**Never** inject the user's Stack access/refresh tokens at the edge. The machine
principal exists precisely so a VM's authority is narrower than its owner's.

### 2. Scopes: what a machine may do

The machine principal is deny-by-default. Initial scope set:

| Scope | Routes it opens | Constraint |
| --- | --- | --- |
| `peers.read` | `GET /api/vm` (filtered to granted peers + self) | same owner only |
| `peers.attach` | `POST /api/vm/:peer/attach-endpoint`, `…/cmux-remote/approve` | requires a peer grant row |
| `peers.exec` | `POST /api/vm/:peer/exec` | requires a peer grant row with `exec` |
| `self.notify` | notification fan-out to the owner's devices | self only |

No create, destroy, snapshot, billing, or team routes — a machine can never spend
money, delete machines, or widen its own access.

### 3. Peer grants: the user decides who talks to whom

The proposed `cmux vm link <src> <dst>` becomes a control-plane
row: `cloud_vm_peer_grants { src_vm, dst_vm, scopes, created_by, revoked_at }`,
written only by a **user** principal. The grant is the authorization; everything
after it is plumbing:

1. Inside `src`, the in-VM `cmux vm exec <dst> -- …` calls the control plane (edge
   injects `src`'s identity).
2. The workflow checks the grant row (`src → dst`, same owner), then mints the
   cmux-remote route + enrollment invitation for `dst` — exactly what it does for a
   Mac today.
3. `src` connects with the invitation; the control plane approves the pending
   enrollment automatically **because the standing user-created grant is the
   approval**. Revocation commits the denied grant first, then immediately removes
   the peer's daemon enrollment and closes its active sessions before reporting
   success. If a daemon cannot acknowledge revocation, access stays denied and
   revocation remains pending for retry; reconciliation is recovery, not the
   authorization boundary. Every grant-mediated operation rechecks the current row.

In this proposal, the Mac drops out of the loop and `cmux vm link` on the Mac
just writes the grant. Existing route-file consumption remains a compatibility
path, but the retired Mac approval-polling broker is not an available fallback.

### 4. The data planes machines actually talk over

Two complementary layers, both already live at the provider:

- **VPC (shipped on main):** every machine of one owner shares a private network;
  the cmux-tui daemon port is reachable member-to-member with zero public exposure.
  Peer sessions ride `ws://[peer-vpc-ipv6]:1337/v1/link` with the daemon's Noise
  device enrollment as session auth. WebSocket is only the carrier: Noise encrypts
  and authenticates the session payload on every frame. This is the terminal/agent plane — what
  `cmux vm exec <peer>` uses.
- **Named internal services (TLS vm→vm rules):** `{ vmId: A } → { vmId: B, port }`
  under a private name — VM A dials `https://db.internal`, the edge terminates with
  a platform cert and forwards to B's port. This is the app plane (an API one agent
  serves to another, a shared DB). Surfaced later as `cmux vm expose <port> --as
  <name> --to <peer>`; grants gate it the same way. (No transform on vm→vm rules
  yet, per provider docs, so app-level auth stays app-level.)

### 5. Lifecycle

- **Mint** at create (driver writes the edge rule; DB row holds the hash).
- **Rotate** on TTL (30d) via `tls.rules.update` — atomic, no traffic drop.
- **Failure-safe transitions:** create an identity as `pending` with an idempotency
  key, install its edge rule, and mark it `active` only after provider confirmation.
  Failed installation revokes the pending row and queues deletion of any orphan
  rule. Authentication accepts only `active` rows. During rotation, register the
  next token hash before the atomic rule update, retain the previous hash only
  until confirmation, then revoke it. A failed update leaves the previous active
  credential usable and discards the pending replacement. Retries reconcile by the
  same operation key and provider rule ID instead of minting another identity.
- **Revoke** on: VM destroy (provider cascade + row revoke), account sign-out
  (`revokeEndpointLeases` extension), or explicit `cmux vm unlink` / grant
  revocation.
- Before sign-out succeeds, commit `revoked_at` for the affected machine identities
  and disable their identity edge rules. A failed edge deletion remains queued for
  retry; the committed database revocation immediately denies further requests.
  These identity rows and the extended sign-out flow are a proposed contract, not
  part of the currently shipped preview-lease cleanup.
- The model plane already uses the edge-held route token: the guest carries only
  the static placeholder env, while the inline Freestyle rule injects the
  bearer and VM-binding headers on the wire. There is no guest-readable route
  credential or runtime feature flag to graduate.

## What shipped: the machine principal is the route-token identity

The model plane already gave every machine an edge-asserted identity: the Freestyle
TLS rule for the alias host (`https://coderouter.cmux.internal`) injects the VM-bound
route token and `x-cmux-vm-id` into every guest request, and
`authenticateRequestRouteToken` rejects a token whose binding disagrees with the
claimed id. Minting a second `cvt_` token for the same VM would only duplicate that
row, so the control plane treats the VM-bound route-token identity as the **machine
principal** (`web/services/vms/vmPrincipal.ts`): `{vm, userId, teamId}`, deny by
default — only the reflection routes accept it, and no `/api/vm/*` route that accepts a
user session accepts a VM.

**Reflection** (modeled on exe.dev's Reflection integration) is how a machine learns
who it is and what it can use, from inside, with no credential in the guest:

```
curl -s https://coderouter.cmux.internal/api/vm/reflection      # or https://reflection.cmux.internal/
{"name":"brave-otter","vm_id":"…","owner":{"email":"…"},"plan_id":"pro","paths":[
  {"path":"/owner"},{"path":"/machine"},{"path":"/peers"},{"path":"/integrations"}]}
```

- `/` — the machine's own name at the top level (always), owner, team, plan, status,
  and the index of paths.
- `/owner`, `/machine` (size, image, private network addresses, desktop).
- `/peers` — the owner's other live machines with their private addresses and the
  daemon route (`ws://[ipv6]:1337/v1/link`). The daemon's private-network listener is a
  trusted carrier (every member of the network is the owner's Mac or machine), so this
  is discovery, not authorization: an in-VM `cmux vm exec <peer>` needs no Mac-written
  route file — the shim resolves the peer through reflection.
- `/integrations` — what the machine can use, each with a `help` one-liner (CodeRouter
  models, the installed agents, notify, env, layouts, peers, the desktop when present).

In the guest: `cmux self [path]` (aliases `cmux whoami`, `cmux reflect`), `cmux vm ls`, and `cmux auth status` (which now
prints the identity). The vanity alias `reflection.cmux.internal` is a second edge rule
on new machines; the path form under the coderouter alias works on every machine.

What remains from the plan below: **mutation scopes** for a VM (`peers.exec` as an
enforced grant rather than network membership, `self.notify` for push delivery without a
Mac), **named internal services** (`vm expose`), and **edge-injected git credentials**.

## Phasing

1. **Current PR #11609 scope:** full capability contract; in-VM `cmux` shim;
   existing peer-route compatibility; private-network port previews; inline
   model-plane edge injection and guest-safe auth/CodeRouter commands. The old
   Mac `vm link` enrollment broker was removed by the main-branch integration;
   creating new peer grants needs a separate trusted-listener workflow.
2. **Machine principal:** `cloud_vm_identities` + `verifyRequest` VM mode + edge
   rule at create + scoped `peers.read`/`self.notify`.
3. **Server-side grants:** `cloud_vm_peer_grants`, grant-gated attach/approve/exec,
   in-VM `cmux vm …` switched from route files to control-plane calls,
   auto-approval under grants.
4. **Named services:** `cmux vm expose`, TLS vm→vm rules under grants.

## Failure honesty

- Edge rule or route-token provisioning fails at VM create → the create is
  rolled back and reported retryable; an unwired machine is never handed out.
- A server that predates the machine principal → the in-VM CLI falls back to route
  files (the PR #11609 flow), which keeps working.
