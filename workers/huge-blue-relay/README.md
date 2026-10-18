# Huge Blue staging relay

The web control plane issues a fresh opaque `hba_` capability from authenticated
`POST /api/workspaces/:id` with `{"action":"attach"}` or `{"action":"rotate"}`.
PlanetScale stores only its SHA-256 hash, runtime, owner, tenant, host, daemon
session, expiry, and revocation timestamp. Rotation locks the owned running
workspace and atomically revokes previous tokens. Create/get/replay views never
mint credentials. Attach responses use `Cache-Control: no-store` and
`Referrer-Policy: no-referrer`; treat the returned URL as a bearer secret.

The loopback relay checks the ledger before upgrading. It rejects browser
Origin headers, duplicate token parameters, expired/revoked tokens, mismatched
hosts/sessions/owners, and non-running runtimes. It rechecks connected peers each
second and closes denied sessions, including on database outages. Queues, frames,
and concurrent connections are bounded. Tokens last at most five minutes; there
is no static relay bearer or signing key to rotate. A subsequent attach issues a
new token without changing relay configuration. Suspend/stop revoke tokens in
the workspace transaction so resume cannot revive old credentials.

This deployment is for explicitly allowlisted internal operators only. A token
admits a link to the entire dedicated `huge-blue-staging` daemon, not a sandboxed
workspace RPC namespace. Do not enable multi-tenant customer access without
per-tenant daemons or daemon-enforced workspace authorization. Logical workspace
suspend/stop revoke access; they do not pause the shared Linux machine or kill
background processes. The soak explicitly closes its own guest workspace.

## Deploy

Keep the existing Huge Blue daemon and acpmux sessions running. This slice owns
only `cmux-staging-relay.service`, `cmux-staging-relay-proxy.service`, their isolated
state, and the Huge Blue Tailscale Serve 443 listener configured for staging.
It never enables Funnel or public ingress. Both the cmux listener on 1337 and
relay on 1338 bind only `127.0.0.1`. TLS is validated by clients through Tailscale
Serve at `wss://huge-blue.tail137216.ts.net/v1/link`.

1. Sync a committed snapshot into `/home/leo/Projects/cmux-huge-blue-relay` on
   Huge Blue. Install web runtime dependencies with the frozen lockfile.
2. Apply `20261017140000_huge_blue_attach_tokens` only on a confirmed disposable
   `cmux-broker-staging-*` PlanetScale branch. When a previous migration role
   expired, reassign its objects on that branch using `pscale role reassign`.
3. Write owner-only `staging.env` with a **read-only** role URL in `DATABASE_URL`,
   `HUGE_BLUE_VM_ID=huge-blue-staging`, and
   `HUGE_BLUE_CMUX_REMOTE_SESSION=huge-blue-staging`. Never commit it.
4. Run `bash workers/huge-blue-relay/scripts/deploy-huge-blue.sh` on Huge Blue.
   Confirm both units are active and listeners are loopback only.
5. On Big Red, use `/etc/cmux/workspace-api-staging.env` with the staging writer
   URL, the SSH host/key/proxy settings, `CMUX_VM_HUGE_BLUE_ENABLED=1`, an explicit
   `HUGE_BLUE_ALLOWED_OWNER_IDS`, the credential-free relay URL,
   `HUGE_BLUE_CMUX_REMOTE_SESSION=huge-blue-staging`, and
   `HUGE_BLUE_CMUX_SOCKET=/run/user/1001/cmux-tui-1001/huge-blue-staging.sock`.
   Source revision receipts use `CMUX_SOURCE_SHA`. Keep broker-container SSH key
   paths separate from the host API's paths.

## Route-driven staging gate

`staging-api.ts` binds loopback on Big Red port 1340 and executes the same
`workspaceHttp` mutation handler, DB store, broker receipts, SSH lease adapter,
and provider composition as the Next routes. It uses an owner-only disposable
service-principal bearer file and fixed internal identity. It never installs an
auth bypass into Next. The harness requires `CMUX_STAGING_API=1`,
`CMUX_STAGING_BRANCH`, `CMUX_STAGING_API_TOKEN_FILE`, `CMUX_STAGING_OWNER_ID`, and
`CMUX_STAGING_TENANT_ID`. Its unit skips unrelated Stack environment validation.
**This gate does not verify Stack login, Vercel deployment, or billing admission.**
The production Next routes retain their existing Stack/entitlement checks.

Run `soak.ts` on Huge Blue with a loopback SSH reverse forward to the Big Red API,
`CMUX_SOAK_TOKEN_FILE`, a unique `CMUX_SOAK_STATE`, and `CMUX_SOAK_CYCLES=3`.
Use a 30-second `HUGE_BLUE_ATTACH_TTL_MS` on the staging API for bounded expiry
proof. The gate checks route auth, idempotency, create/replay, real Noise attach,
terminal execution on Huge Blue, client SIGKILL and reconnect with retained
output, rotation, stale-token rejection, suspend/resume, expiry, stop/replay, and
guest cleanup. Receipts contain identifiers and outcomes, never attach URLs or
tokens. A short soak is a staging regression gate, not a production load test.

Local checks: `bun test --isolate tests/huge-blue-relay.test.ts
 tests/huge-blue-provider.test.ts tests/persistent-workspace.test.ts
 tests/persistent-workspace-route.test.ts`; `bun run typecheck`;
`bun run lint:complexity`. DB gate: on the disposable branch,
`CMUX_DB_TEST=1 bun test --isolate tests/huge-blue-attach-db.test.ts`.

## Operations and rollback

`GET /healthz` on the loopback relay returns connection count. Inspect
`systemctl --user show -p ActiveState -p NRestarts -p ExecMainStatus` for both
Huge Blue units and `systemctl show` for Big Red's API/broker units. Credential
expiry on the disposable DB roles is independent of attach-token expiry; renew
or replace DB roles before their recorded deadline. An expired DB role closes
access rather than bypassing authorization.

To roll back, disable Huge Blue admission on the API, stop the staging API and
relay proxy, and turn off only Huge Blue's staging Serve 443 listener. Existing
primary Huge Blue/acpmux sessions are outside this deployment. The additive DB
migration can remain until the disposable branch is removed. Do not delete a
branch while a deployed worker still references it. Before customer production,
add tenant isolation, actual Stack/Vercel journey verification, deployment
secrets/role renewal, readiness/metrics/alerts, and a longer failure/load soak.
