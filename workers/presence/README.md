# cmux presence and Iroh control worker

This Worker is the public HTTP/WebSocket edge for cmux device presence and the
Iroh control plane. It uses one Durable Object per Stack account for ordered
control operations and keeps the existing Aurora PostgreSQL database as the
durable source of truth. It does not carry Iroh peer packets, QUIC, or relay
traffic.

## Request ownership

| Route | Auth at the edge | Owner after the edge |
| --- | --- | --- |
| `/healthz` | none | Worker |
| `/v1/iroh/session` | one Stack identity lookup (`/users/me`) | account DO, which mints a ticket |
| `/v1/iroh/session/renew` | existing signed ticket only | account DO |
| `/v1/iroh/session/revoke-all` | one Stack identity lookup | account DO epoch fence |
| `/api/devices/iroh*` | ticket signature and account epoch | account DO, then direct Iroh adapter or compatibility origin |
| `/api/relay/*` | ticket signature and account epoch | account DO, then direct relay adapter or compatibility origin |
| `/api/connectivity/v2|v3/sync` | ticket signature and account epoch | account DO, then direct connectivity adapter or compatibility origin |
| `/v1/control/socket` | ticket at WebSocket upgrade | account DO, which owns the socket |
| other `/v1` routes | existing Stack verification/cache | their existing presence/reply DO |

The public URL is the Worker. A client never addresses a Durable Object
directly. The Worker derives `control:user:<Stack user id>` from a verified
identity and forwards to that object.

## Session authentication and Stack call budget

Current clients send the Stack access and refresh pair once to
`POST /v1/iroh/session`. The Worker verifies only identity, caches that result
briefly, and the account DO returns a signed 15-minute HMAC ticket. The ticket
contains the account, session id, epoch, expiry, renewal time, and the exact
client metadata (device, app instance, namespace, tag, and platform).

Ordinary challenge, registration, discovery, revoke, pairing, relay-token,
preference, connectivity, and control-socket requests carry only
`X-Cmux-Iroh-Session-Ticket`. The Worker and DO verify the signature locally,
check the account and namespace, and check the stored session plus revocation
epoch. They do not call Stack for each request or WebSocket message.

The client renews before expiry through `POST /v1/iroh/session/renew`, which is
ticket-only and single-flighted. A temporary Worker/DO outage keeps the current
ticket in memory and retries renewal later. A 401, expired ticket, account
switch, or explicit revocation clears it and requires a fresh bootstrap. Old
app builds that still send Stack credentials are upgraded at the edge into a
ticket, so their credentials do not enter the DO or direct backend.

Endpoint binding proofs remain required for non-legacy endpoint mutations and
relay issuance. The session ticket answers “which account is this?”; the
Ed25519 binding proof answers “which registered endpoint may perform this
operation?”.

## Direct backend and the existing database

Set `CMUX_IROH_BACKEND_MODE=direct` only when the `HYPERDRIVE` binding is
configured. In direct mode the account DO invokes the existing Iroh,
connectivity, relay-policy, and repository code with an injected database
provider. No Vercel request is made and no Stack request is made after session
bootstrap.

Hyperdrive is a managed Cloudflare bridge and connection pool to Aurora. It is
not D1, a cache of application records, or a second database. The Worker uses a
fresh `postgres.js` client for each request/transaction; Hyperdrive pools the
origin connection. Query-result caching stays disabled for these permission,
mutation, and read-after-write paths.

The current Vercel database path authenticates to Aurora with AWS IAM/OIDC.
Hyperdrive needs a stable database connection credential, so production
provisioning has one explicit prerequisite: create a least-privilege Postgres
role for this Worker, allow its private network path, and rotate its password
through the Hyperdrive configuration. Do not copy an expiring Vercel OIDC token
into Hyperdrive.

Hyperdrive does not provide PostgreSQL advisory locks. An advisory lock is a
named turnstile held by a database session until its transaction ends. Both
Worker and Vercel repositories therefore take a pre-seeded
`account_mutation_fences` bucket row with `FOR UPDATE`; Vercel's hybrid path
also keeps its advisory fast path. The row query fails closed if the seed
migration is missing. This preserves cross-writer serialization without
changing the application tables or introducing Redis.

The SQL migration is
`web/db/migrations/20260904120000_account_mutation_fences/migration.sql` and
must run against the same Aurora database before direct writes are enabled.

## Optional Iroh Services RCAN minter

The RCAN minter is an optional external credential vending service. It receives
an approved EndpointID and returns a short-lived signed capability for an Iroh
Services relay. It is not a relay, does not carry terminal traffic, and is not
needed by the self-hosted managed-relay path.

The code uses it only when both `CMUX_IROH_MINT_URL` and
`CMUX_IROH_MINT_HMAC_SECRET_B64` are configured. The direct Worker can issue
our self-hosted relay JWT locally with `CMUX_RELAY_JWT_PRIVATE_KEY_PEM`, so the
RCAN service can remain untouched unless an environment audit proves that a
production client still depends on it. If the optional service is configured
and unavailable, only that external credential path fails; registration and
discovery do not depend on it.

## Observability

Both Wrangler configs enable Workers Observability. The Worker and account DO:

- accept or generate a bounded `X-Cmux-Request-Id` and return it;
- emit structured operation, status, backend, latency, revision, and session
  metadata to Workers Logs;
- add `Server-Timing` for the DO/backend leg;
- send bounded, redacted exceptions to the configured `SENTRY_DSN` using the
  Sentry envelope API; and
- report detached connectivity-invalidation failures instead of adding them
  to the registration round trip.

Bearer tokens, refresh tokens, HMAC keys, private relay credentials, raw
pairing material, and complete endpoint identifiers are never logged. Set
`SENTRY_DSN` on every production or isolated dev Worker. Missing telemetry is
non-fatal.

## Configuration and rollout

Production `wrangler.toml` is intentionally fail-closed with
`CMUX_IROH_BACKEND_MODE = "direct"`. Add the Hyperdrive resource after it is
provisioned:

```toml
[[hyperdrive]]
binding = "HYPERDRIVE"
id = "<existing-aurora-hyperdrive-config-id>"
```

The dev config stays in compatibility mode until a separate staging
Hyperdrive config is available. `CMUX_WEB_BASE_URL` is used only in that
compatibility mode and defaults to the production web origin.

Before enabling direct mode:

1. Audit production for `CMUX_IROH_MINT_URL` and its HMAC secret without
   printing their values.
2. Inventory every Iroh table writer, including retention and scheduled jobs.
3. Apply the mutation-fence migration to Aurora.
4. Create the least-privilege Worker DB role and private TLS/network route.
5. Create the Hyperdrive config with response caching disabled and attach its
   id to the production and staging Wrangler configs.
6. Provision the Worker secrets below and put the same session key in the web
   deployment while compatibility mode is still enabled.
7. Run a canary challenge → register → discover → relay-token → revoke flow,
   compare normalized responses with the existing service, and measure p50/p95
   latency plus error and Stack-call counts.
8. Point new iOS builds at `https://presence.cmux.dev`, soak with the old web
   routes healthy, then remove compatibility only after the dashboards are
   clean.

Required Worker secrets (set once per Worker):

```text
STACK_PROJECT_ID
STACK_PUBLISHABLE_CLIENT_KEY
IROH_SESSION_SIGNING_KEY
CONNECTIVITY_INVALIDATION_SECRET
SENTRY_DSN
CMUX_IROH_LAN_DISCOVERY_SECRET_B64
CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64
CMUX_IROH_GRANT_SIGNING_KEY_P8
CMUX_IROH_GRANT_SIGNING_KID
CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON
CMUX_RELAY_POLICY_KEY_ID
CMUX_RELAY_POLICY_PRIVATE_KEY_PEM
CMUX_RELAY_JWT_PRIVATE_KEY_PEM
```

The optional RCAN variables are `CMUX_IROH_MINT_URL`,
`CMUX_IROH_MINT_HMAC_SECRET_B64`, and
`CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER` (development only). The web
compatibility deployment uses `CMUX_IROH_SESSION_SIGNING_KEY`, with the exact
same value as the Worker's `IROH_SESSION_SIGNING_KEY`.

## Development

```bash
bun install
bun run relay-catalog:check
bun run typecheck
bun test
bunx wrangler deploy --dry-run --outdir dist
```

For local Worker development, put Stack values in the gitignored `.dev.vars`.
`CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE` can provide a local
Postgres connection for `wrangler dev`; it disables Hyperdrive pooling locally.
Use `wrangler dev --remote` when testing the real Hyperdrive binding.

`./scripts/deploy-dev.sh <slug>` deploys an isolated workers.dev Worker with
its own Durable Object namespace. It must not be used to overwrite the shared
`cmux-presence-dev` or the production custom domain. The script provisions
Stack and observability secrets from the shell or `.dev.vars` without printing
them and prints the resulting URL for the tagged Mac+iOS dogfood build.

## Deploy and rollback

The manual GitHub workflow is `.github/workflows/presence.yml`. It runs the
catalog check, typecheck, tests, and Wrangler dry-run before deploying. The
`prod` target uses `wrangler.toml`; the `dev` target uses
`wrangler.dev.toml`. Hyperdrive and database credentials are one-time account
provisioning, not values committed to this repository.

To roll back application code, deploy the previous known-good Worker version
or use Wrangler rollback. To roll back the database path, set the backend mode
back to `compatibility` and keep `CMUX_WEB_BASE_URL` healthy. Do not delete the
mutation-fence table during rollback; it is harmless to the Vercel advisory-lock
runtime and is needed for the next direct attempt.

Dictionary: a control plane coordinates devices; a data plane carries Iroh
peer/relay traffic; a Durable Object is one Cloudflare-owned stateful object;
Hyperdrive is the pooled bridge to the existing SQL database; an advisory lock
is a Postgres session turnstile; `FOR UPDATE` locks a selected database row;
RCAN is a signed, narrowly scoped capability token.
