/**
 * Cloudflare Worker entry. Secrets arrive as Worker secrets and are wrapped in
 * Redacted immediately; they are never logged or returned.
 */
import { Layer, Redacted } from "effect";
import { makeWebHandler } from "./app.ts";
import { stackLayers } from "./auth/credentials.ts";
import { hyperdriveSqlLayer } from "./db/sql.ts";
import { sqlStoresLayer } from "./db/stores.ts";
import { makeUpstreamClient, UpstreamClient } from "./upstream/client.ts";
import { sqlAuditLogLayer } from "./db/audit.ts";
import { sqlIdempotencyStoreLayer } from "./db/idempotency.ts";
import { sqlSnapshotStoreLayer } from "./db/snapshots.ts";
import { entitlementsDenyAllLayer } from "./proofs/tenant-may-create.ts";
import { makeUpstreamSnapshots, UpstreamSnapshots } from "./upstream/snapshots.ts";
import { makeUpstreamTerminals, UpstreamTerminals } from "./upstream/terminals.ts";

export interface Env {
  readonly HYPERDRIVE: Hyperdrive;
  readonly UPSTREAM_API_URL: string;
  readonly UPSTREAM_API_KEY: string;
  readonly STACK_API_URL: string;
  readonly STACK_PROJECT_ID: string;
  readonly STACK_SECRET_SERVER_KEY: string;
}

const liveServices = (env: Env) =>
  Layer.mergeAll(
    sqlStoresLayer.pipe(Layer.provide(hyperdriveSqlLayer(env.HYPERDRIVE.connectionString))),
    Layer.succeed(
      UpstreamClient,
      makeUpstreamClient({ baseUrl: env.UPSTREAM_API_URL, apiKey: Redacted.make(env.UPSTREAM_API_KEY) }),
    ),
    stackLayers({
      apiUrl: env.STACK_API_URL,
      projectId: env.STACK_PROJECT_ID,
      serverKey: Redacted.make(env.STACK_SECRET_SERVER_KEY),
    }),
    s3aServices(env),
  );

/** Snapshots and terminals (slice S3a). Creates stay refused until the billing hook replaces the deny-all entitlements. */
const s3aServices = (env: Env) => {
  const upstream = { baseUrl: env.UPSTREAM_API_URL, apiKey: Redacted.make(env.UPSTREAM_API_KEY) };
  return Layer.mergeAll(
    Layer.mergeAll(sqlSnapshotStoreLayer, sqlAuditLogLayer, sqlIdempotencyStoreLayer).pipe(
      Layer.provide(hyperdriveSqlLayer(env.HYPERDRIVE.connectionString)),
    ),
    entitlementsDenyAllLayer,
    Layer.succeed(UpstreamSnapshots, makeUpstreamSnapshots(upstream)),
    Layer.succeed(UpstreamTerminals, makeUpstreamTerminals(upstream)),
  );
};

let cached: { readonly env: Env; readonly handler: (request: Request) => Promise<Response> } | undefined;

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    if (cached === undefined || cached.env !== env) {
      const { handler } = makeWebHandler(liveServices(env));
      cached = { env, handler: (incoming) => handler(incoming) };
    }
    return cached.handler(request);
  },
} satisfies ExportedHandler<Env>;
