import { PoolCoordinator } from "./do";
import {
  buildUpstreamUrl,
  injectCredentialHeaders,
  isUsageLimitResponse,
  matchRoute,
  MAX_BUFFERED_BODY_BYTES,
  sanitizeResponseHeaders,
} from "./families";
import { extractCallerKey, verifyCallerKey } from "./keys";
import { PRICING_CATALOG } from "./pricing";
import { bodyWithinReplayLimit } from "./requestBody";
import { extractConversationKey } from "./sessionKey";
import { drainSseUsage, parseJsonUsage, ZERO_ESTIMATED_USAGE } from "./sse";
import { verifyInternalRequest } from "./internalAuth";
import type { Env } from "./do";
import type { AcquireSuccess, ReportRequest, SeedOauth, Usage } from "./types";

export { PoolCoordinator };

function json(body: unknown, status = 200, headers?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") return json({ ok: true, service: "cmux-coderouter" });
    if (url.pathname === "/v1/models" && request.method === "GET") return json({ data: Object.keys(PRICING_CATALOG).sort() });

    if (url.pathname.startsWith("/internal/")) return handleInternal(request, env, url);

    const route = matchRoute(url);
    if (!route) return json({ error: "not_found" }, 404);

    const callerKey = extractCallerKey(request.headers);
    if (!callerKey) return json({ error: "unauthorized" }, 401);
    const caller = await verifyCallerKey(callerKey, env.CODEROUTER_KEY_SIGNING_SECRET);
    if (!caller) return json({ error: "unauthorized" }, 401);

    const rawBody = await readRawBody(request);
    const parsedJson = parseJsonBody(request.headers, rawBody);
    const model = extractModel(parsedJson);
    const conversationKey = await extractConversationKey({
      endpointClass: route.endpointClass,
      family: route.family,
      headers: request.headers,
      url,
      parsedJson,
      ip: request.headers.get("cf-connecting-ip"),
    });

    const pool = env.POOL.get(env.POOL.idFromName(`${caller.team}:${route.family}`)) as DurableObjectStub<PoolCoordinator>;
    const excludeCredentialIds: string[] = [];
    let lastResponse: Response | null = null;
    const attempts = bodyWithinReplayLimit(rawBody?.byteLength ?? null) ? 3 : 1;

    for (let attempt = 0; attempt < attempts; attempt += 1) {
      const acquired = await pool.acquire({
        kid: caller.kid,
        teamId: caller.team,
        family: route.family,
        endpointClass: route.endpointClass,
        conversationKey,
        model,
        excludeCredentialIds,
      });
      if (!acquired.ok) return mapAcquireError(acquired);

      const startedAt = Date.now();
      const upstreamHeaders = injectCredentialHeaders(route.endpointClass, acquired.class, request.headers, acquired.authHeaders);
      const upstreamResponse = await fetch(buildUpstreamUrl(route, url), {
        method: request.method,
        headers: upstreamHeaders,
        body: rawBody && request.method !== "GET" && request.method !== "HEAD" ? rawBody.slice(0) : undefined,
        redirect: "manual",
      });
      const latencyMs = Date.now() - startedAt;
      const sniffText = await sniffErrorBody(upstreamResponse);
      const usageLimited = isUsageLimitResponse(
        route.endpointClass,
        acquired.class,
        upstreamResponse.status,
        upstreamResponse.headers.get("content-type"),
        sniffText,
      );
      if (usageLimited && attempt < attempts - 1) {
        ctx.waitUntil(report(pool, acquired, caller.kid, conversationKey, route.endpointClass, model, upstreamResponse, latencyMs, ZERO_ESTIMATED_USAGE, true));
        excludeCredentialIds.push(acquired.credentialId);
        void upstreamResponse.body?.cancel().catch(() => {});
        lastResponse = upstreamResponse;
        continue;
      }
      return passThroughWithReport(
        upstreamResponse,
        pool,
        acquired,
        caller.kid,
        conversationKey,
        route.endpointClass,
        model,
        latencyMs,
        usageLimited,
        ctx,
      );
    }

    return lastResponse ?? json({ error: "no_response" }, 502);
  },
} satisfies ExportedHandler<Env>;

async function handleInternal(request: Request, env: Env, url: URL): Promise<Response> {
  if (!verifyInternalRequest(request, env.CODEROUTER_INTERNAL_TOKEN)) return json({ error: "unauthorized" }, 401);
  const syncMatch = /^\/internal\/pools\/([^/]+)\/sync$/.exec(url.pathname);
  const seedMatch = /^\/internal\/pools\/([^/]+)\/seed-oauth$/.exec(url.pathname);
  if (!syncMatch && !seedMatch) return json({ error: "not_found" }, 404);
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const poolId = decodeURIComponent((syncMatch?.[1] ?? seedMatch?.[1]) as string);
  const pool = env.POOL.get(env.POOL.idFromName(poolId)) as DurableObjectStub<PoolCoordinator>;
  const body = (await request.json().catch(() => null)) as unknown;
  if (!body || typeof body !== "object") return json({ error: "invalid_request" }, 400);
  if (syncMatch) return json(await pool.syncConfig(body as Parameters<PoolCoordinator["syncConfig"]>[0]));
  return json(await pool.seedOauth(body as SeedOauth));
}

async function passThroughWithReport(
  response: Response,
  pool: DurableObjectStub<PoolCoordinator>,
  acquired: AcquireSuccess,
  kid: string,
  conversationKey: string,
  endpointClass: ReportRequest["endpointClass"],
  model: string | undefined,
  latencyMs: number,
  usageLimited: boolean,
  ctx: ExecutionContext,
): Promise<Response> {
  const headers = sanitizeResponseHeaders(response.headers);
  headers.set("x-coderouter-credential", acquired.class);
  const contentType = response.headers.get("content-type") ?? "";
  if (response.body && contentType.toLowerCase().includes("text/event-stream")) {
    const [clientBody, reportBody] = response.body.tee();
    ctx.waitUntil(
      drainSseUsage(endpointClass, reportBody).then((usage) =>
        report(pool, acquired, kid, conversationKey, endpointClass, model, response, latencyMs, usage, usageLimited),
      ),
    );
    return new Response(clientBody, { status: response.status, statusText: response.statusText, headers });
  }
  if (contentType.toLowerCase().includes("json")) {
    const clone = response.clone();
    ctx.waitUntil(
      clone
        .json()
        .then((payload) => parseJsonUsage(endpointClass, payload))
        .catch(() => ({ ...ZERO_ESTIMATED_USAGE }))
        .then((usage) => report(pool, acquired, kid, conversationKey, endpointClass, model, response, latencyMs, usage, usageLimited)),
    );
  } else {
    ctx.waitUntil(report(pool, acquired, kid, conversationKey, endpointClass, model, response, latencyMs, ZERO_ESTIMATED_USAGE, usageLimited));
  }
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

async function report(
  pool: DurableObjectStub<PoolCoordinator>,
  acquired: AcquireSuccess,
  kid: string,
  conversationKey: string,
  endpointClass: ReportRequest["endpointClass"],
  model: string | undefined,
  response: Response,
  latencyMs: number,
  usage: Usage,
  usageLimited: boolean,
): Promise<void> {
  await pool.report({
    credentialId: acquired.credentialId,
    kid,
    conversationKey,
    endpointClass,
    model,
    status: response.status,
    latencyMs,
    usage,
    rateLimitHeaders: headersRecord(response.headers),
    usageLimited,
  });
}

function mapAcquireError(error: Exclude<Awaited<ReturnType<PoolCoordinator["acquire"]>>, { ok: true }>): Response {
  if (error.error === "key_revoked") return json({ error: "key_revoked" }, 401);
  if (error.error === "config_unavailable") return json({ error: "config_unavailable" }, 503, { "retry-after": "5" });
  if (error.error === "no_credentials") return json({ error: "no_credentials", message: "No usable credential is configured." }, 403);
  if (error.error === "all_exhausted") {
    return json(
      { error: "all_exhausted", message: "All matching credentials are temporarily limited." },
      429,
      error.soonestResetSeconds ? { "retry-after": String(error.soonestResetSeconds) } : undefined,
    );
  }
  if (error.error === "insufficient_credits") return json({ error: "insufficient_credits" }, 402);
  return json({ error: "model_not_priced" }, 400);
}

async function readRawBody(request: Request): Promise<ArrayBuffer | null> {
  if (request.method === "GET" || request.method === "HEAD") return null;
  return await request.arrayBuffer();
}

function parseJsonBody(headers: Headers, rawBody: ArrayBuffer | null): unknown | undefined {
  if (!rawBody || rawBody.byteLength > MAX_BUFFERED_BODY_BYTES) return undefined;
  const contentType = headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.includes("json")) return undefined;
  try {
    return JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return undefined;
  }
}

function extractModel(payload: unknown): string | undefined {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return undefined;
  const model = (payload as Record<string, unknown>).model;
  return typeof model === "string" ? model : undefined;
}

async function sniffErrorBody(response: Response): Promise<string | null> {
  const contentType = response.headers.get("content-type") ?? "";
  if (response.status < 400 || !contentType.toLowerCase().includes("json")) return null;
  return await response
    .clone()
    .text()
    .catch(() => null);
}

function headersRecord(headers: Headers): Record<string, string> {
  const record: Record<string, string> = {};
  for (const [key, value] of headers) record[key] = value;
  return record;
}
