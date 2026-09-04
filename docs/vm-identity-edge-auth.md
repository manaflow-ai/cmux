# VM identity at the TLS edge: automatic auth for machines, and machines talking to machines

Status: design (phase 1 shipped in PR #11609). Owner: cloud VM control plane.

## The problem

A cmux Cloud machine has no way to call the control plane. `/api/vm/*` accepts only a
Stack Auth user session (bearer + refresh token, or browser cookie), and nothing that
lives inside a VM may hold either — a refresh token in a guest is the user's whole
account sitting in an agent sandbox. The only credential a VM holds today is the
coderouter model-plane token, delivered as a root-readable file, and it authenticates
nothing but the model plane. Machine-to-machine access exists only as the Mac-brokered
`cmux vm link` flow (PR #11609): the Mac mints routes and approves enrollments because
the VM cannot.

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
`{ vm_id, user_id, billing_team_id, scopes, expires_at, revoked_at }`, and hands the
raw token to the driver exactly once — which writes it into the edge rule above and
then forgets it. This is the same pattern as the coderouter route token (`crt_`,
sha256-stored, 30-day), which is already the house way to mint scoped machine-side
credentials.

`verifyRequest` grows a third mode: `x-cmux-vm-token` → identity row → a
**machine principal** `{ kind: "vm", vmId, userId, billingTeamId, scopes }`. Stack
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

`cmux vm link <src> <dst>` (today: Mac-brokered route files) becomes a control-plane
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
   approval**. Revoking the grant revokes the access (and tears down the daemon
   enrollment on next reconcile).

The Mac drops out of the loop; `cmux vm link` on the Mac just writes the grant.
Route files and Mac-side approve polling (the PR #11609 mechanism) remain as the
fallback for control-plane-less operation and older servers.

### 4. The data planes machines actually talk over

Two complementary layers, both already live at the provider:

- **VPC (shipped on main):** every machine of one owner shares a private network;
  the cmux-tui daemon port is reachable member-to-member with zero public exposure.
  Peer sessions ride `ws://[peer-vpc-ipv6]:1337/v1/link` with the daemon's Noise
  device enrollment as session auth. This is the terminal/agent plane — what
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
- **Revoke** on: VM destroy (provider cascade + row revoke), account sign-out
  (`revokeEndpointLeases` extension), or explicit `cmux vm unlink` / grant
  revocation.
- The model-plane token rides the **same** edge rule (one rule, two headers), which
  retires the root-readable `model-plane.env` credential once
  `CMUX_VM_MODEL_PLANE_EDGE_INJECTION` graduates from its flag.

## Phasing

1. **Shipped (PR #11609):** full capability contract; in-VM `cmux` shim;
   Mac-brokered `vm link`; TLS port previews; flag-gated model-plane edge injection.
2. **Machine principal:** `cloud_vm_identities` + `verifyRequest` VM mode + edge
   rule at create + scoped `peers.read`/`self.notify`.
3. **Server-side grants:** `cloud_vm_peer_grants`, grant-gated attach/approve/exec,
   in-VM `cmux vm …` switched from route files to control-plane calls,
   auto-approval under grants.
4. **Named services:** `cmux vm expose`, TLS vm→vm rules under grants.

## Failure honesty

- Edge rule create fails at VM create → machine ships without a control-plane
  identity (in-VM `cmux vm` verbs answer "no identity; use `cmux vm link` from the
  Mac"), never a blocked create.
- A server that predates the machine principal → the in-VM CLI falls back to route
  files (the PR #11609 flow), which keeps working.
