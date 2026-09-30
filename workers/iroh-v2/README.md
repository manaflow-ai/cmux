# IROH v2 Worker

The Worker owns `/v2/` control routes. Each team and environment maps to one
Durable Object with Drizzle SQLite storage. The shared ownership adapter uses
the existing production PlanetScale PostgreSQL database. Its only v2 tables are
the global EndpointID ownership map and the corresponding owner counts. Device
registrations, challenges, permissions, directory state and rate limits remain
in Durable Object SQLite. Credentials do not create a row per issuance.

The shared development Worker is `cmux-v2-development`. For isolated
branch work, deploy a suffixed Worker:

```sh
./scripts/deploy-dev.sh my-branch
```

The current account uses the `debussy.workers.dev` subdomain.

Put the required secrets in the shell environment or `.dev.vars`. Set either
`DATABASE_URL` or `PLANETSCALE_DATABASE_URL`; deployment publishes the chosen
value as the canonical `DATABASE_URL` Worker secret. Scope records by
environment, project, team and user. Development Durable Objects remain
isolated by Worker environment. The script never prints secret values.

For local CLI work, select PlanetScale without changing application code:

```sh
cd web
CMUX_DB_PROVIDER=planetscale bun db:migrate
```

Set `PLANETSCALE_DATABASE_URL` in the environment or a local ignored env file.
`bun db:test` refuses to run against PlanetScale and always uses an isolated
Docker database. The PlanetScale CLI accepts a service token through its secure
credential store or flags; never commit credentials.

The September 15 cutover copied 44 ownership entries from the temporary v2
databases into the existing production database and switched all three Workers
to it. Existing legacy tables were preserved. See the deployment receipt in
`docs/iroh-v2/IMPLEMENTATION.md`. No new database is required.

The ownership adapter sets its five-second statement timeout inside each
transaction because the shared database pool rejects that setting during
connection startup. An opt-in live regression reuses an existing reservation,
checks repeated writes and rejects a conflicting identity without adding rows:
`IROH_V2_OWNERSHIP_SMOKE_DATABASE_URL` selects the database for
`bun test ./live/ownership-database.test.ts`. Supply the URL through a private
environment file. Keep this live check separate from the local workerd suite.

## Guarded rollout and client rule dependencies

Canonical Workers are `cmux-v2`, `cmux-v2-staging`, and `cmux-v2-development`.
The old `cmux-iroh-v2*` hosts are forwarding aliases for existing Mac and iOS
clients. Deploy to the canonical Worker in place; never deploy a full Worker
onto an alias or create replacement Durable Object namespaces. PR #13768 owns
the broader client-origin rename and alias tooling; this follow-up adopts its
deployment names so rollout cannot overwrite those existing aliases.

Mac-to-Mac links require `directory.rules` to contain
`cmux.mac-peer-inbound.v1`. An `inboundPeers` field alone is insufficient:
production's older iOS-only service also returns it. The Mac displays the
existing service-update message until the rule is live. Once the directory
advertises the rule, discovery refreshes even if the peer records did not change.
The host still checks the authenticated peer's explicit permission independently.

### Reader-first SQLite upgrade

`STORAGE_SCHEMA_VERSION` is the maximum reader version (7).
`STORAGE_WRITE_SCHEMA_VERSION` is the version normal activation creates (6).
The first deployment retains schema 6 and supports both 6 and 7. Existing v6
migration statements and hashes are unchanged; the v7 migration remains intact
and is not applied implicitly. Audit retention uses the existing bounded SQL
count on v6 and its counter on already-upgraded v7 databases.

This matters because the currently deployed v6 Worker rejects a v7 history.
Rolling its code back after a v7 write does not roll SQLite back. Cloudflare's
Durable Object migration tag is separate from this application SQLite schema.
The guarded script checks both, plus the active namespaces. It permits only a
candidate whose write version the previous reader supports, and refuses reader
downgrades. A 404 health route proves no compatibility. Only the exact audited
legacy production and staging version IDs in `scripts/rollout-policy.ts` qualify
for the first v6-preserving deployment; unknown versions fail closed. Do not add
an ID without inspecting that immutable version's migration reader.

From a clean, committed checkout, using Bun 1.4.2 and the authorized Cloudflare
account, first deploy staging through the same guards:

```sh
bun install --frozen-lockfile
CLOUDFLARE_ACCOUNT_ID=0c1675e0def6de1ab3a50a4e17dc5656 bun run deploy:staging
curl -sS https://cmux-v2-staging.debussy.workers.dev/v2/health
```

Confirm the exact source revision, `storage` reader 7/writer 6, and Mac rule.
Exercise existing iOS-to-Mac connectivity and opted-in same-account Mac-to-Mac
connectivity on staging, including revocation and reconnect. Then promote the
same revision:

```sh
CLOUDFLARE_ACCOUNT_ID=0c1675e0def6de1ab3a50a4e17dc5656 bun run deploy:production
curl -sS https://cmux-v2.debussy.workers.dev/v2/health
bun run drift:check
```

The production script requires the revision to be on fetched `origin/main`,
verifies staging has the same revision and schema policy,
checks authenticated deployment metadata around the live probes, retains remote
variables and secrets, and checks unchanged namespace IDs and the live rule after
deployment. It rolls back only while its own deployment is still current and the
preflight has established reader compatibility. It refuses a dirty source tree.
Health/protocol probes do not establish a signed-device end-to-end test.

Only after that reader-first version has been deployed and verified should a
separate reviewed change raise `STORAGE_WRITE_SCHEMA_VERSION` to 7. Its rollback
target must be the reader-first version, never the former v6-only binary. No SQL
downgrade, namespace replacement, or deletion of existing device data is part of
this rollout. Deploying the Worker can reconnect existing sockets; verify recovery.

The storage runtime suite covers retained devices and revocation across v6 and
v7, including the expected failure of the frozen v6 reader after a v7 upgrade and
successful reopen by the compatible reader. Deployment tests use mocked external
commands: they do not deploy or alter Cloudflare.

The unauthenticated health endpoint reports provenance and storage compatibility;
ordinary Mac/iOS protocol responses are unchanged. `bun run drift:check` compares
the canonical production Worker with `origin/main`. Missing health, wrong scope,
unknown provenance and missing rules fail. The scheduled production-drift workflow
reports drift; merging code does not deploy production.
