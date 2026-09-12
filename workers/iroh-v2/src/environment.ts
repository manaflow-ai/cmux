import { z } from "zod";
import { StackAuthority } from "./auth";
import { identifier, relayURL } from "./contracts/common";
import { OperationError } from "./errors";
import { PlanetScaleOwnership } from "./ownership/planetscale";
import { RELAY_TOKEN_AUDIENCE, RELAY_TOKEN_ISSUER, RelayIssuer } from "./relay";
export type Environment = Cloudflare.Env & {
  /** Hyperdrive is the production database path; direct URLs remain for local fixtures only. */
  HYPERDRIVE_CONNECTED_WORKSPACES?: { readonly connectionString: string };
  PLANETSCALE_DATABASE_URL?: string;
  DASHBOARD_ALLOWED_ORIGINS?: string;
  AXIOM_TOKEN?: string; AXIOM_DATASET?: string; AXIOM_INGEST_URL?: string;
  SENTRY_DSN?: string; SENTRY_ENVIRONMENT?: string;
};

export function environmentScope(env: Environment) {
  return { environment: identifier.parse(env.ENVIRONMENT), projectId: identifier.parse(env.STACK_PROJECT_ID) };
}

const runtimes = new WeakMap<object, ReturnType<typeof createRuntime>>();
export function runtime(env: Environment) {
  let value = runtimes.get(env);
  if (!value) { value = createRuntime(env); runtimes.set(env, value); }
  return value;
}

function createRuntime(env: Environment) {
  try {
    const scope = environmentScope(env);
    const keys = z.record(identifier, z.string().regex(/^[A-Za-z0-9_-]{43,}$/)).parse(JSON.parse(env.API_TICKET_KEYS));
    const currentKeyId = identifier.parse(env.API_TICKET_CURRENT_KEY_ID);
    const currentKey = keys[currentKeyId];
    if (!currentKey) throw new Error("Missing current key");
    const relayURLs = z.array(relayURL).min(1).max(16).parse(JSON.parse(env.RELAY_URLS));
    const allowedOrigins = z.array(z.url().max(2048).refine(value => {
      const url = new URL(value);
      return url.origin === value && (url.protocol === "https:" || (scope.environment !== "production"
        && url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname)));
    })).max(32).parse(JSON.parse(env.DASHBOARD_ALLOWED_ORIGINS ?? '["https://cmux.com","https://www.cmux.com"]'));
    return {
      ...scope, keys, currentKeyId, currentKey, allowedOrigins,
      stack: new StackAuthority({ ...scope, apiURL: env.STACK_API_URL, publishableKey: env.STACK_PUBLISHABLE_KEY, serverKey: env.STACK_SERVER_KEY }),
      ownership: new PlanetScaleOwnership(
        env.HYPERDRIVE_CONNECTED_WORKSPACES?.connectionString ?? env.PLANETSCALE_DATABASE_URL ?? "",
        scope.environment,
        scope.projectId,
      ),
      relays: new RelayIssuer({
        ...scope, relayURLs, issuer: RELAY_TOKEN_ISSUER, audience: RELAY_TOKEN_AUDIENCE,
        keyId: env.RELAY_KEY_ID, privateKeyPem: env.RELAY_SIGNING_KEY,
      }),
    };
  } catch { throw new OperationError("upstream_unavailable", 503, true, 5000); }
}
