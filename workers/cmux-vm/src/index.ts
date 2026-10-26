/**
 * Cloudflare Worker entry. Secrets arrive as Worker secrets and are wrapped in
 * Redacted immediately; they are never logged or returned.
 */
import { Effect, Layer, Redacted } from "effect";
import { makeWebHandler } from "./app.ts";
import { stackLayers } from "./auth/credentials.ts";
import { serviceKeysLayer } from "./auth/service-keys.ts";
import { checkSchema, makeSchemaGate } from "./db/schema-check.ts";
import { hyperdriveSqlLayer, withRequestConnection } from "./db/sql.ts";
import { sqlStoresLayer } from "./db/stores.ts";
import type { TenantLimitsObject } from "./limits/durable-object.ts";
import { durableObjectLimitsLayer } from "./limits/service.ts";
import { parseEnvironment, parseTenantList, parseVmQuotas, tenantPolicyLayer } from "./policy.ts";
import { parseHttpsProxyOrigins } from "./network-origin.ts";
import { entitlementsFromPolicyLayer } from "./proofs/tenant-may-create.ts";
import { upstreamLayer } from "./upstream/live.ts";
import { vmImagesLayer } from "./upstream/live-images.ts";
import { sqlSnapshotStoreLayer } from "./db/snapshots.ts";
import { sqlApiKeyAdminStoreLayer } from "./db/api-keys.ts";
import { sqlAgentStoreLayer } from "./db/agents.ts";
import { stackTeamAdminLayer } from "./auth/team-admin.ts";
import { upstreamSnapshotsLayer } from "./upstream/live-snapshots.ts";
import { upstreamTerminalsLayer } from "./upstream/live-terminals.ts";
import { sqlMeshStoreLayer } from "./db/mesh.ts";
import { meshConfigLayer, parseMeshExperiment } from "./mesh/config.ts";
import { upstreamMeshLayer } from "./upstream/live-mesh.ts";
import { sqlMembershipCacheLayer, sqlWebhookDeliveryStoreLayer } from "./db/identity.ts";
import { sqlDomainStoreLayer } from "./db/domains.ts";
import { domainPolicyLayer } from "./domain/domains.ts";
import { upstreamDomainsLayer } from "./upstream/live-domains.ts";

/** The per-tenant counters Durable Object; wrangler binds it as TENANT_LIMITS. */
export { TenantLimitsObject } from "./limits/durable-object.ts";

export interface Env {
  /** Approved service boot images; provider snapshot ids stay server-side. Default: none. */
  readonly VM_BOOT_IMAGES?: string;
  /** JSON array of exact HTTPS origins approved for creation-time proxies. Default: none. */
  readonly VM_HTTPS_PROXY_ORIGINS?: string;
  readonly HYPERDRIVE: Hyperdrive;
  readonly UPSTREAM_API_URL: string;
  readonly UPSTREAM_API_KEY: string;
  readonly STACK_API_URL: string;
  readonly STACK_PROJECT_ID: string;
  readonly STACK_SECRET_SERVER_KEY: string;
  readonly TENANT_LIMITS: DurableObjectNamespace<TenantLimitsObject>;
  /** local, preview, staging or production; anything else counts as production. */
  readonly ENVIRONMENT?: string;
  /** Production tenants (Stack team ids) treated as dev/test: comma or space separated. */
  readonly DEV_TEST_TENANT_IDS?: string;
  /** The manaflow-team flag (cx-b4h.16): Stack team ids entitled without billing; comma or space separated. */
  readonly MANAFLOW_TEAM_TENANT_IDS?: string;
  /** JSON object of Stack team id to live VM limit, overriding the default. */
  readonly TENANT_VM_QUOTAS?: string;
  /** Mesh experiment (cx-0op): "1" turns it on for the tenants in CMUX_VM_MESH_TENANT_IDS; anything else is off. */
  readonly CMUX_VM_MESH_EXPERIMENT?: string;
  /** Stack team ids allowed into the mesh experiment: comma or space separated. */
  readonly CMUX_VM_MESH_TENANT_IDS?: string;
  /** Stack Auth webhook signing secret (whsec_...); optional, the webhook answers 503 without it (G1, cx-0op.6). */
  readonly STACK_WEBHOOK_SECRET?: string;
  /** Service keys (cx-b4h.13): JSON array of { id, sha256, scopes, labels, teams? }; hashes only. See src/auth/service-keys.ts. */
  readonly CMUX_VM_SERVICE_KEYS?: string;
  /** Domains (cx-b4h.6): the zone managed hostnames (`<name>--<tenant tag>.<zone>`) live under. Default: none (managed hostnames off). */
  readonly CMUX_VM_MANAGED_DOMAIN_ZONE?: string;
  /** The hostname custom domains CNAME to, shown in domain DNS instructions. Default: not shown. */
  readonly CMUX_VM_DOMAIN_EDGE_HOST?: string;
  /** The nameserver `_acme-challenge.<domain>` is delegated to for wildcard certificates. Default: not shown. */
  readonly CMUX_VM_CERTIFICATE_NAMESERVER?: string;
}

const liveServices = (env: Env) => {
  const sql = hyperdriveSqlLayer(env.HYPERDRIVE.connectionString);
  const policy = tenantPolicyLayer({
    httpsProxyOrigins: parseHttpsProxyOrigins(env.VM_HTTPS_PROXY_ORIGINS),
    environment: parseEnvironment(env.ENVIRONMENT),
    devTestTenantIds: parseTenantList(env.DEV_TEST_TENANT_IDS),
    manaflowTenantIds: parseTenantList(env.MANAFLOW_TEAM_TENANT_IDS),
    vmQuotas: parseVmQuotas(env.TENANT_VM_QUOTAS),
  });
  return Layer.mergeAll(
    // Snapshot rows and API key management (slice S3a) share the request's connection with the other stores.
    Layer.mergeAll(sqlStoresLayer, sqlSnapshotStoreLayer, sqlApiKeyAdminStoreLayer, sqlAgentStoreLayer, sqlMeshStoreLayer, sqlWebhookDeliveryStoreLayer, sqlDomainStoreLayer).pipe(
      Layer.provide(sql),
    ),
    policy,
    vmImagesLayer(env.VM_BOOT_IMAGES),
    serviceKeysLayer(env.CMUX_VM_SERVICE_KEYS),
    // TODO(cx-b4h, owner: Lawrence Chen): the real billing source; see Entitlements.
    entitlementsFromPolicyLayer.pipe(Layer.provide(policy)),
    durableObjectLimitsLayer(env.TENANT_LIMITS),
    upstreamLayer({ baseUrl: env.UPSTREAM_API_URL, apiKey: env.UPSTREAM_API_KEY, environment: parseEnvironment(env.ENVIRONMENT) }),
    // The shared positive membership cache (mesh M4) lives in Postgres, so the webhook revokes it for every isolate.
    Layer.provideMerge(
      stackLayers({
        apiUrl: env.STACK_API_URL,
        projectId: env.STACK_PROJECT_ID,
        serverKey: Redacted.make(env.STACK_SECRET_SERVER_KEY),
      }),
      sqlMembershipCacheLayer.pipe(Layer.provide(sql)),
    ),
    s3aServices(env),
    meshServices(env),
    upstreamDomainsLayer({ baseUrl: env.UPSTREAM_API_URL, apiKey: env.UPSTREAM_API_KEY, environment: parseEnvironment(env.ENVIRONMENT) }),
    domainPolicyLayer({
      managedZone: env.CMUX_VM_MANAGED_DOMAIN_ZONE,
      edgeHost: env.CMUX_VM_DOMAIN_EDGE_HOST,
      certificateNameserver: env.CMUX_VM_CERTIFICATE_NAMESERVER,
    }),
    stackTeamAdminLayer({
      apiUrl: env.STACK_API_URL,
      projectId: env.STACK_PROJECT_ID,
      serverKey: Redacted.make(env.STACK_SECRET_SERVER_KEY),
    }),
  );
};

/** The provider snapshot and terminal clients (slice S3a). */
const s3aServices = (env: Env) => {
  const upstream = { baseUrl: env.UPSTREAM_API_URL, apiKey: env.UPSTREAM_API_KEY, environment: parseEnvironment(env.ENVIRONMENT) };
  return Layer.mergeAll(upstreamSnapshotsLayer(upstream), upstreamTerminalsLayer(upstream));
};

/** The mesh experiment's provider client and its gate (off unless both vars say otherwise). */
const meshServices = (env: Env) =>
  Layer.mergeAll(
    upstreamMeshLayer({ baseUrl: env.UPSTREAM_API_URL, apiKey: env.UPSTREAM_API_KEY, environment: parseEnvironment(env.ENVIRONMENT) }),
    meshConfigLayer({
      experiment: parseMeshExperiment(env.CMUX_VM_MESH_EXPERIMENT),
      tenantIds: parseTenantList(env.CMUX_VM_MESH_TENANT_IDS),
    }),
  );

interface Served {
  readonly handler: (request: Request) => Promise<Response>;
  /** One agent reaper run, or nothing when the service is not configured or its schema is not applied. */
  readonly reap: () => Promise<void>;
}

let cached: ({ readonly env: Env } & Served) | undefined;

/** A missing secret or binding answers 503 instead of crashing every request. */
const notConfigured = (): Promise<Response> =>
  Promise.resolve(
    Response.json({ _tag: "ServiceUnavailable", message: "The cmux VM service is not configured" }, { status: 503 }),
  );

const unconfigured: Served = { handler: notConfigured, reap: () => Promise.resolve() };

const makeServed = (env: Env): Served => {
  try {
    if (!env.HYPERDRIVE || !env.TENANT_LIMITS || !env.UPSTREAM_API_KEY || !env.STACK_PROJECT_ID || !env.STACK_SECRET_SERVER_KEY) {
      return unconfigured;
    }
    const secret = env.STACK_WEBHOOK_SECRET?.trim();
    const { handler, reap } = makeWebHandler(liveServices(env), {
      perRequest: withRequestConnection,
      perWebhook: withRequestConnection,
      ...(secret === undefined || secret.length === 0 ? {} : { stackWebhookSecret: Redacted.make(secret) }),
    });
    // A deploy must never run ahead of its migration: 503 "schema not applied" until the tables this build needs exist.
    const check = () => Effect.runPromise(Effect.provide(checkSchema, hyperdriveSqlLayer(env.HYPERDRIVE.connectionString)));
    return {
      handler: makeSchemaGate(check, (incoming) => handler(incoming)),
      // The reaper deletes VMs: it runs only against the schema this build was written for.
      reap: async () => {
        const problems = await check();
        if (problems.length > 0) {
          console.error(JSON.stringify({ event: "cmux_vm_reaper_skipped", reason: "schema", problems }));
          return;
        }
        await reap();
      },
    };
  } catch {
    console.error("cmux-vm configuration invalid");
    return unconfigured;
  }
};

const served = (env: Env): Served => {
  if (cached === undefined || cached.env !== env) cached = { env, ...makeServed(env) };
  return cached;
};

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return served(env).handler(request);
  },
  /** Cron (wrangler.jsonc triggers): the agent reaper. */
  scheduled(_controller: ScheduledController, env: Env, context: ExecutionContext): void {
    context.waitUntil(
      served(env)
        .reap()
        .catch(() => console.error(JSON.stringify({ event: "cmux_vm_reaper_failed" }))),
    );
  },
} satisfies ExportedHandler<Env>;
