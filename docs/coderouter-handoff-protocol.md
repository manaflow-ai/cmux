# CodeRouter native handoff protocol

This protocol transfers CodeRouter authority from an authenticated cmux-native
process to another local/native process without putting a long-lived Stack
credential in the handoff. It is intentionally a bearer protocol: callers must
use TLS, keep the returned lease in process memory or an OS-protected store,
and never put it in a URL, shell argument, log, crash report, analytics event,
or Sentry context.

## Endpoints

### Mint: `POST /api/coderouter/handoff`

The caller **must** send the native Stack token pair:

```http
Authorization: Bearer <Stack access token>
X-Stack-Refresh-Token: <Stack refresh token>
X-Cmux-Team-Id: <selected Stack team id>
Content-Type: application/json
```

`X-Cmux-Team-Id` is optional when Stack has one selected team. If supplied, it
must identify a team the Stack user belongs to. The body is empty or `{}`.
Cookies, user-agent strings, `X-Cmux-Native`-style assertions, and route tokens
are not authorization for minting. A malformed native pair never falls back to
an ambient browser cookie.

The server reuses the CodeRouter request-context checks: Stack identity,
team membership/allowlisting, the `use` permission, and the existing hosted
Pro-or-Team entitlement gate when hosted billing is enabled. A successful
response is `Cache-Control: no-store` and has this shape:

```json
{
  "teamId": "team_...",
  "lease": "crh_...",
  "expiresAt": "2026-08-13T..."
}
```

The lease has 256 bits of randomness and expires after two minutes.

### Exchange: `POST /api/coderouter/handoff/exchange`

The body must be exactly one JSON field, with no surrounding whitespace in the
value:

```json
{ "lease": "crh_..." }
```

Possession of a currently valid lease is the authorization assumption for this
method. Stack credentials are therefore **not required**: this is what permits
the authenticated cmux process to hand authority to a native CodeRouter
subprocess that does not have the Stack refresh token. Browser-cookie requests
are rejected; cookies never add authority. If a caller supplies either Stack
header, it must be a complete valid native pair; when present, the pair is
additionally required to resolve to the lease's same user and team and the
current permission/entitlement checks are rerun. This optional confirmation is
method-specific and is not a replacement for the lease.

When hosted billing is enabled, exchange also rechecks the stored lease
principal's current Pro-or-Team entitlement immediately before the atomic
claim. This server-side check does not require the recipient to possess Stack
credentials.

The response is the existing CodeRouter route-session shape:

```json
{
  "teamId": "team_...",
  "token": "crt_...",
  "expiresAt": "2026-...",
  "openaiBaseUrl": "https://cmux.com/v1"
}
```

`openaiBaseUrl` is built from the server's trusted
`CMUX_CODEROUTER_PUBLIC_ORIGIN` deployment setting, not from a forwarded
request host. Deployed non-preview runtimes fail closed if that origin is not
configured. Local non-Vercel development may derive it from the local request
URL for convenience.

The route token is returned only in this no-store response and is persisted by
the existing route-token repository as a hash. Unknown, expired, consumed, and
identity-mismatched leases all return the same `401 invalid_handoff_lease`
response; clients must not use that response as a validity oracle.

## One-time and storage guarantees

The database stores only `SHA-256(lease)` in
`coderouter_handoff_leases.lease_hash`. It has no plaintext lease column. On
exchange, a conditional update requiring an unconsumed, unexpired hash and
the route-token insert run in one PostgreSQL transaction. Concurrent exchanges
therefore produce at most one route token. If route-token insertion fails, the
transaction rolls back the consumed marker and a retry remains possible until
the lease expires.

The existing route-token table stores only `SHA-256(token)`. Billing
revocation marks outstanding handoff leases consumed before revoking route
tokens, using the same principal locks as mint and exchange. Hosted mint and
exchange recheck entitlement through their transaction-bound database
connection after acquiring those locks, so cancellation cannot race either
operation into new authority. Account-deletion startup uses its deletion lock
to invalidate outstanding leases and route tokens; later mint and exchange
check the same durable tombstone while holding that lock. Normal route-token
authentication remains authoritative after exchange.

## Bounds and abuse controls

- Native Stack auth headers are bounded to 16 KiB each.
- Handoff request bodies are bounded to 2 KiB and must be JSON for non-empty
  requests.
- Deployed non-preview runtimes must configure
  `CMUX_CODEROUTER_PUBLIC_ORIGIN` as an origin-only HTTPS URL (for example
  `https://cmux.com`); no request or forwarded host is trusted for this value.
- Lease syntax is exact: `crh_` followed by 43 URL-safe base64 characters.
- The deployed route requires the existing durable Vercel Firewall rule
  `CMUX_APP_SESSION_HANDOFF_RATE_LIMIT_ID`, falling back to
  `CMUX_FEEDBACK_RATE_LIMIT_ID` for existing deployments. Missing or
  unavailable durable limiting fails closed with `503`; a limited request is
  `429`. Non-production local runs use a process-local 60 requests/minute
  backstop only.
- Responses are `no-store` and do not redirect.
- Mint traffic opportunistically deletes at most 100 leases older than the
  ten-minute retention window. Each mint adds one row, so normal mint traffic
  drains stale rows faster than it creates them without requiring a separate
  cleanup worker. Cleanup runs in its own transaction, so a maintenance
  failure cannot abort lease issuance.

Telemetry receives only fixed operation/outcome labels. Lease and route-token
values are not passed to CodeRouter analytics, breadcrumbs, error context, or
Sentry; Sentry also scrubs both `crh_` and `crt_` patterns as defense in
depth.
