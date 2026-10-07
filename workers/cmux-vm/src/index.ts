/**
 * Cloudflare Worker entry. Secrets arrive as Worker secrets and are wrapped in
 * Redacted immediately; they are never logged or returned.
 */
import { Layer, Redacted } from "effect";
import { makeWebHandler } from "./app.ts";
import { stackLayers } from "./auth/credentials.ts";
import { hyperdriveSqlLayer, withRequestConnection } from "./db/sql.ts";
import { sqlStoresLayer } from "./db/stores.ts";
import type { TenantLimitsObject } from "./limits/durable-object.ts";
import { durableObjectLimitsLayer } from "./limits/service.ts";
import { parseEnvironment, parseTenantList, parseVmQuotas, tenantPolicyLayer } from "./policy.ts";
import { entitlementsFromPolicyLayer } from "./proofs/tenant-may-create.ts";
import { upstreamLayer } from "./upstream/live.ts";

/** The per-tenant counters Durable Object; wrangler binds it as TENANT_LIMITS. */
export { TenantLimitsObject } from "./limits/durable-object.ts";

export interface Env {
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
  /** JSON object of Stack team id to live VM limit, overriding the default. */
  readonly TENANT_VM_QUOTAS?: string;
}

const liveServices = (env: Env) => {
  const policy = tenantPolicyLayer({
    environment: parseEnvironment(env.ENVIRONMENT),
    devTestTenantIds: parseTenantList(env.DEV_TEST_TENANT_IDS),
    vmQuotas: parseVmQuotas(env.TENANT_VM_QUOTAS),
  });
  return Layer.mergeAll(
    sqlStoresLayer.pipe(Layer.provide(hyperdriveSqlLayer(env.HYPERDRIVE.connectionString))),
    policy,
    // TODO(cx-b4h, owner: Lawrence Chen): the real billing source; see Entitlements.
    entitlementsFromPolicyLayer.pipe(Layer.provide(policy)),
    durableObjectLimitsLayer(env.TENANT_LIMITS),
    upstreamLayer({ baseUrl: env.UPSTREAM_API_URL, apiKey: env.UPSTREAM_API_KEY }),
    stackLayers({
      apiUrl: env.STACK_API_URL,
      projectId: env.STACK_PROJECT_ID,
      serverKey: Redacted.make(env.STACK_SECRET_SERVER_KEY),
    }),
  );
};

let cached: { readonly env: Env; readonly handler: (request: Request) => Promise<Response> } | undefined;

/** A missing secret or binding answers 503 instead of crashing every request. */
const notConfigured = (): Promise<Response> =>
  Promise.resolve(
    Response.json({ _tag: "ServiceUnavailable", message: "The cmux VM service is not configured" }, { status: 503 }),
  );

const makeHandler = (env: Env): ((request: Request) => Promise<Response>) => {
  try {
    if (!env.HYPERDRIVE || !env.TENANT_LIMITS || !env.UPSTREAM_API_KEY || !env.STACK_PROJECT_ID || !env.STACK_SECRET_SERVER_KEY) {
      return notConfigured;
    }
    const { handler } = makeWebHandler(liveServices(env), { perRequest: withRequestConnection });
    return (incoming) => handler(incoming);
  } catch {
    console.error("cmux-vm configuration invalid");
    return notConfigured;
  }
};

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    if (cached === undefined || cached.env !== env) cached = { env, handler: makeHandler(env) };
    return cached.handler(request);
  },
} satisfies ExportedHandler<Env>;
