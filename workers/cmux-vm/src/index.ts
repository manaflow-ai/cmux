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
  );

let cached: { readonly env: Env; readonly handler: (request: Request) => Promise<Response> } | undefined;

/** A missing secret or binding answers 503 instead of crashing every request. */
const notConfigured = (): Promise<Response> =>
  Promise.resolve(
    Response.json({ _tag: "ServiceUnavailable", message: "The cmux VM service is not configured" }, { status: 503 }),
  );

const makeHandler = (env: Env): ((request: Request) => Promise<Response>) => {
  try {
    if (!env.HYPERDRIVE || !env.UPSTREAM_API_KEY || !env.STACK_PROJECT_ID || !env.STACK_SECRET_SERVER_KEY) {
      return notConfigured;
    }
    const { handler } = makeWebHandler(liveServices(env));
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
