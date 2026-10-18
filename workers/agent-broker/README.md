# cmux agent broker worker

This is the first independently deployable broker slice. It runs as a separate
Bun process, claims durable `agent_broker_jobs` rows, dispatches the serialized
payload to a configured adapter, and commits a fenced receipt to the shared
PlanetScale PostgreSQL ledger.

The web runtime may continue using the in-process lifecycle broker while
provider operations are being moved behind this boundary. The worker contract
is versioned in `web/services/agent-broker/adapterBoundary.ts`; a future
private adapter repository can implement that contract without moving the
ledger or changing runtime callers.

## Run

From the repository root:

```sh
DATABASE_URL='postgres://…' \
CMUX_BROKER_WORKER_ID='broker-huge-blue-1' \
CMUX_BROKER_HOST_CLASS='huge-blue' \
CMUX_BROKER_ADAPTER_MODULE='/run/secrets/cmux-broker-adapters.mjs' \
bun web/scripts/agent-broker-worker.ts
```

Use `CMUX_BROKER_ONCE=1` for a one-job smoke run. `DATABASE_URL` is the normal
PlanetScale connection; migrations remain owned by `web` and are not run by
the worker.

Big Red staging uses `scripts/build-big-red-staging.sh` and
`systemd/cmux-agent-broker-staging.service`. The script builds the image on Big
Red as `localhost/cmux-agent-broker:staging`, then installs the unit only when
`CMUX_BROKER_INSTALL=1` is set. Write the staging branch URL and adapter module path into
`/etc/cmux/agent-broker-staging.env`; keep that file root-readable only. The
unit runs the container as `leo` and restarts it if the worker exits.

The adapter module must export:

```ts
export async function createAgentBrokerAdapters(input: {
  env: Readonly<Record<string, string | undefined>>;
}): Promise<readonly AgentBrokerEffectAdapter[]>;
```

Adapters receive only the versioned, credential-free job envelope and return a
JSON object. Provider credentials stay in the worker's secret manager and are
never placed in broker payloads or receipts. Unknown host classes fail closed.

The built-in `workers/agent-broker/adapters/host-lease-adapters.ts` module
implements the provider-neutral lease gateway for Huge Blue and Freestyle. It
registers `huge-blue`, `freestyle`, and the compatibility alias `freestyle-vm`
only when the corresponding gateway URL and token are present:

```text
HUGE_BLUE_HOST_LEASE_URL / HUGE_BLUE_HOST_LEASE_TOKEN / HUGE_BLUE_HOST_ID
FREESTYLE_HOST_LEASE_URL / FREESTYLE_HOST_LEASE_TOKEN / FREESTYLE_HOST_ID
```

The lease payload is `{ operation, leaseId, hostId?, generation, ttlMs? }`.
Provider tokens are resolved from deployment environment only; they never cross
the broker envelope or receipt boundary.

For a container deployment, use the repository root as the build context:

```sh
docker build -f workers/agent-broker/Dockerfile -t cmux-agent-broker .
docker run --rm --env-file .env.broker cmux-agent-broker
```

Keep the adapter module outside the image or inject it through the deployment's
secret/configuration mechanism.
