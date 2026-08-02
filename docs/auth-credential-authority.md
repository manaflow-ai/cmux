# Auth plane: single credential authority

## Problem

Stack refresh tokens rotate on every mint. Multiple client lanes (RPC wake
refresh, relay-policy loop, registration refresh, discovery, revocation)
independently capture, present, and force-refresh one rotating credential
pair. Any lane's refresh invalidates every other lane's in-flight pair, so
the broker returns 401 for perfectly healthy sessions, most reliably at app
wake when all lanes fire at once. Pre-v2 code treated that 401 as fatal
(endpoint teardown + offline-cache deletion + 30-36s flat backoff), turning a
microsecond rotation race into 30s-2.5min reconnect outages (field rings,
build 20260731034828).

## Design

**One refresher.** `AuthCoordinator` is the only component that may mint.
Rejection recovery is centralized and fenced:

- `authorizedCredentials() -> AuthCredentialGrant` — one coherent capture:
  `{ sessionGeneration, accountID, accessToken, refreshToken }`. A
  transition-owned token store (launch/foreground revalidation) classifies as
  retryable (`networkError`), never signed-out (absorbs PR 9259).
- `credentialsAfterRejection(of grant) -> AuthCredentialGrant` — called after
  a server rejected the grant:
  1. Session-generation mismatch or signed out → `unauthorized`.
  2. Re-capture. If the stored refresh token differs from the rejected
     grant's, rotation already landed elsewhere → return the fresh grant, no
     mint.
  3. Otherwise force-mint exactly once, keyed on the rejected refresh token:
     concurrent rejecters of the same pair coalesce onto one in-flight mint
     (dedup task map). Re-capture, return.
  4. A definitively dead session clears auth state (existing
     `forceRefreshAccessToken` semantics), routing teardown through the auth
     owner, not through transport-layer classifiers.
- Legacy `forceRefreshAccessToken()` reroutes through the same single-flight
  so stragglers coalesce; the ad-hoc unconditional wake refresh in the RPC
  lane is deleted — recovery is rejection-driven only, so rotations happen at
  most once per genuine expiry instead of once per lane per wake.

**Uniform boundary protocol.** Every HTTP boundary that sends the
Bearer+refresh pair (iroh trust-broker client, mobile RPC lane, Mac host)
does: capture → send → on 401 → `credentialsAfterRejection` → retry once. A
second 401 is authoritative. `CmxIrohBrokerTokenSource` keeps `credentialPair`
(throwing = transient/busy → classify connectivity; nil = definitively
absent) plus `recoveredCredentialPair(rejected:)`; frozen pinned sources
(sign-out revocation) never recover.

**Auth rejections preserve verified in-memory state** (rebased from PR 9263):
- `preservesVerifiedPolicyDuringRefresh` includes 401/403 (client
  registration refresh + host runtime keep endpoint/routes/last binding).
- `retriesInitialActivation` includes 401.
- SECURITY BOUNDARY unchanged: dial-time cached grants and the offline policy
  store stay availability-only (`isAvailabilityFailure`, excludes 401/403);
  an authenticated denial never unlocks cached credentials — revocation bites
  at the next dial. Pinned by the `*NeverConsultsOfflinePolicy` suites.
- Relay-policy retry ladder: cause-aware short schedule for auth failures
  (superseded by PR 9301's `foregroundClient` bounds if that merges first;
  keep whichever lands second consistent).

## Supersedes / composes

- Supersedes PR 9263 (conflicting after connectivity-v2).
- Absorbs PR 9259's transition-window classification (same file, same seam;
  one merge decision instead of two conflicting ones).
- Orthogonal to PR 9301 (global backoff bounds) and the reconnect-hygiene
  program (bgControl double-dial, watchdog); do not duplicate those here.

## Invariants to test

1. Concurrent rejections of the same pair → exactly one mint.
2. Rejection of an already-rotated pair → fresh grant, zero mints.
3. Dead session → `unauthorized` + auth state cleared once.
4. Transition-owned store → retryable, not signed-out.
5. Broker 401 → one retry with successor pair; second 401 propagates.
6. 401/403 never consult offline/cached policy stores (existing suites).
7. 401 during registration refresh keeps endpoint active (client + host).
