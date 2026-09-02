# Cloud VM domains: Freestyle TLS with CMUX access policy

Status: implementation design for `codex/cloud-vm-public-urls`. The VPC and device-tunnel foundation from [PR #11602](https://github.com/manaflow-ai/cmux/pull/11602) is already on `main`.

## Product model

A publication maps one VM port to one canonical HTTPS hostname:

```text
hostname -> CMUX publication -> Freestyle VM + port
```

Every publication has exactly one access mode:

| Mode | Viewer policy |
| --- | --- |
| `personal` | Only the CMUX user who owns the publication |
| `team` | Any current member of the selected CMUX team |
| `public` | Anyone with the URL |

There are no viewer grants, access requests, approvals, or per-domain share lists. A person either satisfies the current publication policy or does not.

The unauthorized browser states are deliberately small:

- signed out: **You don't have access** and **Sign in to cmux to view this site.**;
- signed in without permission: **You don't have access** and the signed-in identity.

## Ownership split

Freestyle is the data plane. It owns DNS-facing routing, customer certificates, TLS termination, VM wake-up, and proxying to the selected VM port.

CMUX is the control and policy plane. It owns publications, their `personal | team | public` mode, CMUX identity, current team membership, browser authorization transactions, and publication sessions.

CMUX does not terminate customer-domain TLS and the VM never receives CMUX authentication secrets.

The owner's tunnel path is separate and simpler: while connected to the
account VPC, the owner reaches the service directly at the VM's private IP and
port. It does not resolve or traverse the public publication hostname.

## Request path

```text
https://<publication-host>/
  -> Freestyle TLS edge
       |
       | public
       |   -> wake VM if needed
       |   -> proxy to VM:port
       |
       | personal or team
       |   -> bodyless forwardAuth request to CMUX
       |        -> 2xx: proxy to VM:port
       |        -> 3xx: return sign-in/callback redirect to browser
       |        -> 4xx: return unauthorized response
       |        -> timeout, network failure, or 5xx: return 503
       |
       -> strip CMUX cookies and trusted edge metadata before VM delivery
```

Freestyle calls one reusable CMUX `forwardAuth` configuration from every protected public rule. Public rules omit `forwardAuth` entirely.

```ts
const cmuxAuth = await freestyle.tls.forwardAuth.create({
  url: "https://cmux.com/api/freestyle/forward-auth",
  headers: { authorization: `Bearer ${serviceToken}` },
  timeoutMs: 1500,
  protectedCookies: [
    "__Host-cmux-preview",
    "__Host-cmux-preview-tx",
  ],
});

await freestyle.tls.rules.create({
  action: "allow",
  domain: publication.hostname,
  protocol: "http",
  source: { public: true },
  destination: {
    vmId: publication.providerVmId,
    port: publication.port,
  },
  forwardAuth: publication.accessMode === "public"
    ? undefined
    : { id: cmuxAuth.id },
});
```

Freestyle does not follow authorization redirects. It returns them to the browser. Protected cookies are visible to CMUX during the authorization check, removed before the request reaches the VM, and protected from VM response writes.

## Browser authorization

1. A browser opens the publication hostname.
2. Freestyle asks CMUX to authorize the request before waking the VM.
3. CMUX matches the trusted rule identity and exact hostname to one active publication.
4. CMUX validates the host-only publication session and reloads the current publication policy.
5. `personal` compares the viewer with the owner. `team` checks current Stack team membership.
6. An allowed viewer receives `200` from CMUX and Freestyle proxies the original request.
7. A signed-out top-level `GET` or `HEAD` is redirected to the CMUX access page and normal Stack sign-in.
8. A signed-in but unauthorized viewer receives the denial page. There is no request-access action.
9. Non-idempotent requests and WebSocket upgrades are not buffered or replayed through sign-in; without a valid session they receive `401` or `403`.

After successful CMUX sign-in and policy evaluation:

1. CMUX creates a random, short-lived, single-use code bound to the user, publication, exact callback URI, PKCE challenge, state, and relative return path.
2. CMUX redirects the browser to the publication hostname:

   ```text
   https://<publication-host>/_cmux/auth/callback?code=<code>&state=<state>
   ```

3. Freestyle intercepts the callback through `forwardAuth`; the VM never sees it.
4. CMUX atomically consumes the transaction and code, issues a host-only publication session, clears the transaction cookie, and redirects to the validated relative path.
5. The repeated request is authorized and reaches the VM.

Cookie contract:

```text
__Host-cmux-preview=<opaque random token>
  Secure; HttpOnly; SameSite=Lax; Path=/; no Domain

__Host-cmux-preview-tx=<opaque transaction token>
  Secure; HttpOnly; SameSite=Lax; Path=/; no Domain
  short expiry
```

Only token hashes are stored. Every check compares the session's routing revision with the active publication and reloads current team membership, so team removal, access-mode changes, and unpublishing take effect on the next request.

## Publication records

```text
cloud_vm_domains
  id
  owner_user_id
  hostname                verified zone base, for example mydomain.com
  kind                    generated | custom
  provider
  provider_domain_id
  verification_state
  certificate_state
  verification_records
  created_at
  updated_at

cloud_vm_publications
  id
  owner_user_id
  vm_id
  domain_id
  hostname                exact canonical publication hostname
  hostname_claimed_at nullable
  port
  access_mode             personal | team | public
  team_id nullable
  provider_tls_rule_id nullable
  provider_forward_auth_id nullable
  routing_revision
  state
  created_at
  updated_at
  disabled_at

cloud_vm_publication_auth_transactions
  transaction_hash
  publication_id
  callback_uri
  pkce_verifier
  state_hash
  return_path
  expires_at
  consumed_at

cloud_vm_publication_auth_codes
  code_hash
  publication_id
  user_id
  callback_uri
  pkce_challenge
  state_hash
  return_path
  expires_at
  consumed_at

cloud_vm_publication_sessions
  token_hash
  publication_id
  user_id
  routing_revision
  expires_at
  revoked_at
```

Server-owned records are authoritative for VM ownership, provider VM id, private network attachment, port, TLS rule id, domain state, and publication state.

## Customer domains

Generated `*.style.dev` names need no customer DNS proof. CMUX reserves a name and reconciles its TLS rule immediately.

For a customer zone and its publication hostnames:

1. CMUX verifies that the user owns the target VM before creating any local or provider record.
2. CMUX asks Freestyle for a fresh verification challenge for the normalized base zone, such as `mydomain.com`.
3. CMUX returns the zone's TXT ownership record and `_acme-challenge.mydomain.com` NS delegation, plus the exact publication hostname's routing record.
4. CMUX completes verification by the stored Freestyle verification ID—not by domain string—and requires the response to contain that exact ID and base zone.
5. CMUX atomically promotes the successful proof to the one globally active CMUX-owner claim for that base zone. Pending attempts are scoped to their CMUX owner and are not ownership claims.
6. CMUX requests Freestyle's ongoing `*.mydomain.com` wildcard certificate and polls it to readiness.
7. The same CMUX owner may reuse the verified zone for the apex or any one-label child: `mydomain.com`, `app.mydomain.com`, or `docs.mydomain.com`. A deeper name needs its own covering zone because one wildcard covers one label.
8. Before provider I/O, CMUX atomically claims the exact publication hostname. A pending DNS attempt cannot squat a hostname; only a generated name or successfully verified owner may win the serving claim.
9. Only the winning publication claim may create a Freestyle TLS rule. CMUX marks it active after its exact route and a covering certificate are ready.

Freestyle verification is provider-account scoped and parent ownership covers subdomains. CMUX therefore never infers one CMUX user's ownership from Freestyle's domain list, parent coverage, an existing certificate, or TLS-rule success. The stored challenge ID and base domain identify the CMUX owner; only that same owner can reuse the zone for wildcard publication hosts.

The CLI surface is:

```text
cmux cloud domains list
cmux cloud domains publish <vm> <port> [--domain <hostname>]
  [--access personal|team|public] [--team <team-id>]
cmux cloud domains verify <publication-id>
cmux cloud domains access <publication-id> <personal|team|public>
  [--team <team-id>]
cmux cloud domains rm <publication-id>
```

## Safe state transitions

- `public -> personal/team`: attach `forwardAuth` at Freestyle first, then commit the protected CMUX policy and increment `routing_revision`.
- `personal/team -> public`: commit the public CMUX policy first, then remove `forwardAuth` from the Freestyle rule.
- `personal <-> team`: commit the new CMUX policy and increment `routing_revision`; the shared Freestyle `forwardAuth` id stays attached.
- unpublish: freeze new work, disable CMUX authorization, delete every exact-host Freestyle rule, then delete the local publication.
- VM deletion: durably freeze publication creation for that VM, disable its publications, sweep every exact-host Freestyle rule, and only then destroy the provider VM.
- account deletion: apply the same publication cleanup before destroying owned VMs and erase publication authentication PII.

Ambiguous provider deletion fails closed and is safe to retry. A reconciler repairs active routing drift and never exposes a protected publication whose Freestyle rule lacks `forwardAuth`.

## Direct tunnel path

The public/custom hostname is an Internet-sharing endpoint only. It always
resolves to Freestyle's public TLS edge and always follows its configured
`personal | team | public` policy, even when the viewer also has a CMUX tunnel.

The owner's authenticated WireGuard tunnel already places their computer on
the same per-account VPC as every owned VM. Local tools therefore connect
straight to the VM's recorded private VPC IP and selected port, using whatever
HTTP or HTTPS protocol the application itself serves. This path needs no
Freestyle TLS rule, certificate, forward-auth call, relay VM, local DNS
override, or new VPC IP lookup API: CMUX already receives each VM's private
address in `VmData.vpcs[].ipv4`/`ipv6` and persists it with the VM.

## Security invariants

- A protected public request reaches the VM only after a CMUX `2xx` decision.
- Direct private-IP access exists only over the owner's authenticated tunnel into the owner VPC.
- The CMUX service credential is sealed, redacted, bounded, and rotatable.
- The VM never receives CMUX cookies, callbacks, service credentials, or trusted edge metadata, and cannot overwrite protected cookies.
- Callback URIs use the exact active hostname; return locations are relative paths on that origin.
- Codes are random, hashed, one-time, short-lived, and bound to publication, callback, state, and PKCE.
- Sessions are publication-scoped and routing-revision-scoped.
- Current team membership and current access mode are authoritative.
- Authorization outages fail closed for protected traffic.
- Customer-zone verification is attributed to one CMUX owner by exact challenge ID and base domain; wildcard reuse is limited to that owner.
- Non-HTTP and TLS-passthrough rules cannot enable browser authorization.

## Verification

- Publish a generated hostname and a verified customer hostname.
- Confirm owner-only `personal`, current-member `team`, and unauthenticated `public` behavior in fresh browsers.
- Confirm signed-out sign-in and signed-in denial UI, with no request-access action.
- Exercise callback state, PKCE, expiry, replay, exact-host, and open-redirect failures.
- Confirm POST-after-session, uploads, streaming, SSE, WebSocket reconnect, and sleeping-VM wake-up.
- Remove a teammate and confirm the next request is denied.
- Inspect VM-facing traffic to confirm CMUX cookies and trusted edge metadata are absent.
- Stop the CMUX auth endpoint and confirm protected traffic fails closed while public traffic continues.
- Race two CMUX owners verifying one customer zone and confirm exactly one proof is promoted.
- Confirm pending attempts cannot squat a publication hostname and only a verified covering-zone owner can claim it and provision TLS.
- Verify `mydomain.com` once, then publish two independent one-label hosts using the same wildcard certificate; reject an uncovered deeper host.
- Start a custom publication against a foreign VM and confirm no local reservation or Freestyle challenge is created.
- Delete a publication, VM, and account under injected provider failures; retries must leave no serving rule behind.
- From the owner's active tunnel, confirm the VM's private IP and port are reachable directly; confirm the public hostname still follows its configured browser policy.

## Completion criteria

- one generated or verified customer hostname maps to one owned VM port;
- access is exactly `personal`, `team`, or `public`;
- unauthorized viewers can sign in or see denial, never request approval;
- Freestyle owns certificates, TLS termination, wake-up, and forwarding;
- public mode makes no forward-auth call;
- protected public mode uses the redirect/code/host-only-cookie flow;
- verified-zone and wildcard rights cannot cross CMUX tenants;
- publication, VM, and account deletion remove edge reachability before provider teardown;
- the VM cannot observe or forge CMUX authentication state;
- the owner's tunnel reaches the VM directly by private IP and port without changing public-hostname behavior.
