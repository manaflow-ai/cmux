import { bearerToken, decimal, verifyActionsToken, type JsonObject } from "./actions-oidc";

// A separately deployed Worker (wrangler.r2-credentials.jsonc), never the
// artifact broker's entrypoint. It trades a GitHub Actions OIDC token for
// 15-minute R2 credentials scoped to one bucket prefix, so a job that uploads
// to R2 needs no long-lived R2 key in GitHub. Only the grants below exist; each
// names the exact repository, workflow file, ref, environment and events
// allowed to use it. The Worker holds the one parent R2 token the temporary
// credentials derive from and never returns it.

export const R2_CREDENTIALS_AUDIENCE = "cmux-r2-credentials";
export const CREDENTIAL_TTL_SECONDS = 900;
const PATH = "/v1/r2-credentials";
const CLOUDFLARE_API = "https://api.cloudflare.com/client/v4";
const MAX_BODY_BYTES = 4096;
const MAX_PREFIX_LENGTH = 512;
const AUTH_TIMEOUT_MS = 5_000;
const MINT_TIMEOUT_MS = 10_000;

type Permission = "object-read-write" | "object-read-only";

export type Grant = {
  repository: string;
  repositoryId: string;
  ownerId: string;
  // Exact workflow_ref (the top-level workflow file @ its ref). GitHub's OIDC
  // docs define job_workflow_ref only "for jobs using a reusable workflow", so
  // an ordinary job's token may lack it: when present it must equal this too,
  // which keeps a reusable workflow from borrowing the grant.
  workflowRef: string;
  ref: string;
  environment: string;
  events: readonly string[];
  bucket: string;
  // Every credential is scoped to this prefix or a narrower one the caller asks for.
  prefix: string;
  permission: Permission;
  // The requested prefix must end in a folder named "<anything>-<run_id>-<run_attempt>/",
  // so one run's credentials cannot write another run's objects.
  runScoped: boolean;
};

export const GRANTS: Readonly<Record<string, Grant>> = {
  // cmuxterm-hq nightly-next-linux.yml, build job, "Keep the dSYM on R2":
  // nightly-next/next/dsyms/<commit>/<build>-<run>-<attempt>/cmux.dSYM.tar.gz.
  "nightly-next-dsyms": {
    repository: "manaflow-ai/cmuxterm-hq",
    repositoryId: "1162953520",
    ownerId: "171392238",
    workflowRef: "manaflow-ai/cmuxterm-hq/.github/workflows/nightly-next-linux.yml@refs/heads/main",
    ref: "refs/heads/main",
    environment: "nightly-next-linux",
    events: ["schedule", "workflow_dispatch"],
    bucket: "cmux-nightly-next",
    prefix: "nightly-next/next/dsyms/",
    permission: "object-read-write",
    runScoped: true,
  },
};

export type R2CredentialsEnv = {
  CLOUDFLARE_API_TOKEN?: string;
  R2_ACCOUNT_ID?: string;
  R2_PARENT_ACCESS_KEY_ID?: string;
};

type Identity = {
  repository: string;
  workflowRef: string;
  ref: string;
  environment: string;
  eventName: string;
  runId: string;
  runAttempt: string;
};

function reply(status: number, body: string | JsonObject): Response {
  const headers = { "Cache-Control": "no-store" };
  return typeof body === "string" ? new Response(body, { status, headers }) : Response.json(body, { status, headers });
}

function matchesGrant(claims: JsonObject, grant: Grant): Identity | undefined {
  if (claims.repository !== grant.repository
      || String(claims.repository_id ?? "") !== grant.repositoryId
      || String(claims.repository_owner_id ?? "") !== grant.ownerId
      || claims.workflow_ref !== grant.workflowRef
      || (claims.job_workflow_ref !== undefined && claims.job_workflow_ref !== grant.workflowRef)
      || claims.ref !== grant.ref
      || claims.environment !== grant.environment
      || typeof claims.event_name !== "string" || !grant.events.includes(claims.event_name)) {
    return undefined;
  }
  try {
    return {
      repository: grant.repository,
      workflowRef: grant.workflowRef,
      ref: grant.ref,
      environment: grant.environment,
      eventName: claims.event_name,
      runId: decimal(claims.run_id),
      runAttempt: decimal(claims.run_attempt),
    };
  } catch {
    return undefined;
  }
}

export function scopedPrefix(requested: unknown, grant: Grant, identity: Identity): string | undefined {
  const prefix = requested === undefined ? grant.prefix : requested;
  if (typeof prefix !== "string" || prefix.length > MAX_PREFIX_LENGTH
      || !prefix.startsWith(grant.prefix) || !prefix.endsWith("/")
      || !/^[A-Za-z0-9._\-/]+$/.test(prefix)) {
    return undefined;
  }
  const segments = prefix.slice(0, -1).split("/");
  if (segments.some((segment) => segment === "" || segment === "." || segment === "..")) return undefined;
  if (grant.runScoped) {
    const last = segments[segments.length - 1];
    if (prefix === grant.prefix || !last.endsWith(`-${identity.runId}-${identity.runAttempt}`)) return undefined;
  }
  return prefix;
}

async function readBody(request: Request): Promise<JsonObject | undefined> {
  const length = Number(request.headers.get("Content-Length") || "0");
  if (length > MAX_BODY_BYTES) return undefined;
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return undefined;
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : undefined;
  } catch {
    return undefined;
  }
}

async function mint(
  env: Required<R2CredentialsEnv>,
  grant: Grant,
  prefix: string,
  fetcher: typeof fetch,
): Promise<{ accessKeyId: string; secretAccessKey: string; sessionToken: string }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), MINT_TIMEOUT_MS);
  try {
    const response = await fetcher(`${CLOUDFLARE_API}/accounts/${env.R2_ACCOUNT_ID}/r2/temp-access-credentials`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.CLOUDFLARE_API_TOKEN}`,
        "Content-Type": "application/json",
        "User-Agent": "cmux-ci-r2-credentials",
      },
      body: JSON.stringify({
        bucket: grant.bucket,
        parentAccessKeyId: env.R2_PARENT_ACCESS_KEY_ID,
        permission: grant.permission,
        ttlSeconds: CREDENTIAL_TTL_SECONDS,
        prefixes: [prefix],
      }),
      redirect: "error",
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`temporary credentials refused (${response.status})`);
    const document = await response.json() as JsonObject;
    const result = document.result as JsonObject | undefined;
    if (document.success !== true || !result
        || typeof result.accessKeyId !== "string" || !result.accessKeyId
        || typeof result.secretAccessKey !== "string" || !result.secretAccessKey
        || typeof result.sessionToken !== "string" || !result.sessionToken) {
      throw new Error("temporary credentials response incomplete");
    }
    return {
      accessKeyId: result.accessKeyId,
      secretAccessKey: result.secretAccessKey,
      sessionToken: result.sessionToken,
    };
  } finally {
    clearTimeout(timer);
  }
}

function configured(env: R2CredentialsEnv): env is Required<R2CredentialsEnv> {
  return Boolean(env.CLOUDFLARE_API_TOKEN)
    && /^[0-9a-f]{32}$/.test(env.R2_ACCOUNT_ID || "")
    && Boolean(env.R2_PARENT_ACCESS_KEY_ID);
}

export async function handleCredentialRequest(
  request: Request,
  env: R2CredentialsEnv,
  fetcher: typeof fetch = fetch,
  now: number = Date.now(),
): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== PATH || url.search) return reply(404, "Not found");
  if (request.method !== "POST") return reply(405, "Use POST");
  if (!configured(env)) return reply(503, "R2 credential broker not configured; use the static R2 secrets");

  let claims: JsonObject;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), AUTH_TIMEOUT_MS);
  try {
    claims = await verifyActionsToken(bearerToken(request), R2_CREDENTIALS_AUDIENCE, fetcher, now, controller.signal);
  } catch {
    return reply(401, "Untrusted Actions identity");
  } finally {
    clearTimeout(timer);
  }

  const body = await readBody(request);
  if (!body || typeof body.grant !== "string") return reply(400, "Body must be JSON with a grant name");
  const grant = Object.hasOwn(GRANTS, body.grant) ? GRANTS[body.grant] : undefined;
  if (!grant) return reply(403, "Unknown grant");
  const identity = matchesGrant(claims, grant);
  if (!identity) return reply(403, "Actions identity is not allowed this grant");
  const prefix = scopedPrefix(body.prefix, grant, identity);
  if (!prefix) return reply(400, "Prefix outside the grant");

  let credentials: Awaited<ReturnType<typeof mint>>;
  try {
    credentials = await mint(env, grant, prefix, fetcher);
  } catch (error) {
    console.error(`r2-credentials: mint failed for ${body.grant}: ${error instanceof Error ? error.message : "unknown"}`);
    return reply(502, "R2 temporary credentials unavailable; use the static R2 secrets");
  }
  const expiresAt = new Date(Math.floor(now / 1000) * 1000 + CREDENTIAL_TTL_SECONDS * 1000).toISOString();
  console.log(`r2-credentials: issued ${body.grant} ${grant.bucket}/${prefix} to run ${identity.runId}/${identity.runAttempt} until ${expiresAt}`);
  return reply(200, {
    ...credentials,
    expiresAt,
    ttlSeconds: CREDENTIAL_TTL_SECONDS,
    grant: body.grant,
    bucket: grant.bucket,
    prefix,
    permission: grant.permission,
    identity,
  });
}

export default {
  fetch(request: Request, env: R2CredentialsEnv): Promise<Response> {
    return handleCredentialRequest(request, env);
  },
} satisfies ExportedHandler<R2CredentialsEnv>;
