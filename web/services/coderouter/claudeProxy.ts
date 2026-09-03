// The Claude leg of coderouter: serves the Anthropic Messages API to a guest
// (Claude Code inside a Cloud VM, or any Anthropic SDK client holding a
// route token) and forwards to the team's configured upstream.
//
// Direct Anthropic upstreams (API key, Claude Code OAuth token) stream the
// body both ways untouched. Bedrock upstreams buffer the request body once
// to rewrite it, sign with SigV4, and convert the AWS event stream back to
// SSE. Usage is read from a bounded head and tail of the response only.
import {
  authenticateRequestRouteToken,
  type RouteTokenAuthResult,
  type RouteTokenIdentity,
} from "./routeTokenAuth";
import { getClaudeUpstream, type ClaudeUpstream } from "./claudeUpstream";
import { captureCoderouterEvent } from "./analytics";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";
import {
  newLedgerRequestId,
  recordRouteEvent,
  recordUsageEvent,
} from "./usageLedger";
import { observeClaudeUsage, type ClaudeUsage } from "./claudeUsage";
import { signAwsRequest } from "./awsSigV4";
import {
  anthropicErrorFromBedrock,
  bedrockEventStreamToSse,
  bedrockInvokeBody,
  bedrockModelCatalog,
  bedrockModelId,
  bedrockRuntimeUrl,
} from "./bedrock";

export const ANTHROPIC_UPSTREAM = "https://api.anthropic.com";
export const OAUTH_BETA = "oauth-2025-04-20";

/** Headers an API-key upstream receives; everything else the guest sent is dropped. */
const API_KEY_FORWARDED_HEADERS = [
  "accept",
  "anthropic-beta",
  "anthropic-version",
  "content-type",
  "user-agent",
] as const;

/**
 * Never forwarded to any upstream: guest credentials, edge routing headers,
 * hop-by-hop and platform headers.
 */
const STRIPPED_HEADERS = new Set([
  "authorization",
  "x-api-key",
  "x-coderouter-route-token",
  "x-cmux-vm-id",
  "host",
  "content-length",
  "connection",
  "keep-alive",
  "transfer-encoding",
  "te",
  "trailer",
  "upgrade",
  "proxy-authorization",
  "cookie",
  "forwarded",
  "via",
]);
const STRIPPED_HEADER_PREFIXES = ["x-forwarded-", "x-vercel-", "x-real-ip", "cf-", "x-cmux-"];

const RESPONSE_HEADERS = ["content-type", "request-id", "x-request-id", "retry-after", "x-should-retry"];
const RESPONSE_HEADER_PREFIXES = ["anthropic-ratelimit-"];

/** Anthropic's own request ceiling; Bedrock bodies are buffered up to this. */
const MAX_BEDROCK_BODY_BYTES = 32 * 1024 * 1024;
const MAX_ERROR_BODY_CHARS = 16 * 1024;
const MODELS_TIMEOUT_MS = 10_000;

type ClaudeSurface = "messages" | "count_tokens" | "models";

export type ClaudeProxyDependencies = {
  readonly authenticate: (request: Request) => Promise<RouteTokenAuthResult>;
  readonly upstream: (teamId: string) => Promise<ClaudeUpstream | null>;
  readonly fetch: typeof fetch;
  readonly now: () => Date;
  readonly capture: typeof captureCoderouterEvent;
};

const defaultDependencies: ClaudeProxyDependencies = {
  authenticate: (request) => authenticateRequestRouteToken(request),
  upstream: getClaudeUpstream,
  fetch: (input, init) => fetch(input, init),
  now: () => new Date(),
  capture: captureCoderouterEvent,
};

export function createClaudeMessagesProxy(
  dependencies: ClaudeProxyDependencies = defaultDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    const startedAt = performance.now();
    const requestId = newLedgerRequestId();
    const route = await resolveRoute(dependencies, request, "messages", { startedAt, requestId });
    if (!route.ok) return route.response;
    const { identity, upstream } = route;
    let response: Response;
    try {
      response = upstream.kind === "bedrock"
        ? await bedrockMessages(dependencies, request, upstream)
        : await anthropicRequest(dependencies, request, upstream, "/v1/messages");
    } catch (error) {
      reportCoderouterFailure("upstream_transport", error, {
        provider: "claude",
        upstream_kind: upstream.kind,
      });
      captureRouteHealth(dependencies, {
        requestId,
        identity,
        request,
        startedAt,
        status: 502,
        outcome: "upstream_error",
        failureStage: "upstream_transport",
        responseStreamed: false,
      });
      return anthropicError(502, "api_error", "coderouter could not reach the Claude upstream. Retry shortly.");
    }
    captureRouteHealth(dependencies, {
      requestId,
      identity,
      request,
      startedAt,
      status: response.status,
      outcome: response.ok ? "success" : "upstream_error",
      failureStage: response.ok ? "none" : "upstream_response",
      responseStreamed: response.body !== null,
    });
    const agent = agentFromUserAgent(request.headers.get("user-agent"));
    const observed = observeClaudeUsage(response.body, (usage) => {
      captureModelUsage(dependencies, identity, upstream.kind, usage, {
        requestId,
        agent,
        status: response.status,
      });
    });
    return new Response(observed, { status: response.status, headers: response.headers });
  };
}

export function createClaudeCountTokensProxy(
  dependencies: ClaudeProxyDependencies = defaultDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    const route = await resolveRoute(dependencies, request, "count_tokens");
    if (!route.ok) return route.response;
    const { upstream } = route;
    try {
      return upstream.kind === "bedrock"
        ? await bedrockCountTokens(dependencies, request, upstream)
        : await anthropicRequest(dependencies, request, upstream, "/v1/messages/count_tokens");
    } catch (error) {
      reportCoderouterFailure("upstream_transport", error, {
        provider: "claude",
        upstream_kind: upstream.kind,
        operation: "count_tokens",
      });
      return anthropicError(502, "api_error", "coderouter could not reach the Claude upstream. Retry shortly.");
    }
  };
}

export function createClaudeModelsProxy(
  dependencies: ClaudeProxyDependencies = defaultDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    const route = await resolveRoute(dependencies, request, "models");
    if (!route.ok) return route.response;
    const { upstream } = route;
    if (upstream.kind === "bedrock") {
      return Response.json(bedrockModelCatalog(upstream.config.modelIds), {
        headers: { "cache-control": "no-store" },
      });
    }
    try {
      return await anthropicRequest(
        dependencies,
        request,
        upstream,
        `/v1/models${new URL(request.url).search}`,
        AbortSignal.timeout(MODELS_TIMEOUT_MS),
      );
    } catch (error) {
      reportCoderouterFailure("upstream_transport", error, {
        provider: "claude",
        upstream_kind: upstream.kind,
        operation: "models",
      });
      return anthropicError(502, "api_error", "coderouter could not reach the Claude upstream. Retry shortly.");
    }
  };
}

export const proxyClaudeMessages = createClaudeMessagesProxy();
export const proxyClaudeCountTokens = createClaudeCountTokensProxy();
export const proxyClaudeModels = createClaudeModelsProxy();

/** True when the request comes from an Anthropic client rather than an OpenAI one. */
export function isAnthropicRequest(request: Request): boolean {
  return request.headers.has("anthropic-version");
}

async function resolveRoute(
  dependencies: ClaudeProxyDependencies,
  request: Request,
  surface: ClaudeSurface,
  /** Present only for the messages surface, which reports route health. */
  health?: { readonly startedAt: number; readonly requestId: string },
): Promise<
  | { ok: true; identity: RouteTokenIdentity; upstream: ClaudeUpstream }
  | { ok: false; response: Response }
> {
  const auth = await dependencies.authenticate(request);
  if (!auth.ok) {
    addCoderouterBreadcrumb("auth", "Route token rejected", { surface, reason: auth.reason }, "warning");
    dependencies.capture({
      event: "coderouter_auth_rejected",
      properties: { surface, reason: auth.reason },
    });
    if (health) {
      captureRouteHealth(dependencies, {
        requestId: health.requestId,
        request,
        startedAt: health.startedAt,
        status: 401,
        outcome: "unauthorized",
        failureStage: "auth",
        responseStreamed: false,
      });
    }
    return {
      ok: false,
      response: anthropicError(401, "authentication_error", authFailureMessage(auth.reason)),
    };
  }
  const identity = auth.identity;
  addCoderouterBreadcrumb("auth", "Route token accepted", { path: surface });
  const upstream = await dependencies.upstream(identity.teamId);
  if (!upstream) {
    addCoderouterBreadcrumb("routing", "No Claude upstream configured", { surface }, "warning");
    if (health) {
      captureRouteHealth(dependencies, {
        requestId: health.requestId,
        identity,
        request,
        startedAt: health.startedAt,
        status: 503,
        outcome: "provider_unavailable",
        failureStage: "provider_config",
        responseStreamed: false,
      });
    }
    return {
      ok: false,
      response: anthropicError(
        503,
        "api_error",
        "No Claude upstream is configured for this team. Set one at coderouter.dev.",
        { "retry-after": "30" },
      ),
    };
  }
  addCoderouterBreadcrumb("routing", "Selected Claude upstream", {
    provider: "claude",
    upstream_kind: upstream.kind,
  });
  return { ok: true, identity, upstream };
}

function authFailureMessage(reason: "missing_route_token" | "invalid_route_token" | "vm_mismatch"): string {
  switch (reason) {
    case "missing_route_token":
      return "Missing coderouter route token. Sign in with `cr login` and retry.";
    case "invalid_route_token":
      return "Your coderouter session expired or was revoked. Run `cr login` and retry.";
    case "vm_mismatch":
      return "This coderouter route token is bound to a different Cloud VM.";
  }
}

// Direct Anthropic upstreams.

async function anthropicRequest(
  dependencies: ClaudeProxyDependencies,
  request: Request,
  upstream: ClaudeUpstream,
  pathAndQuery: string,
  signal?: AbortSignal,
): Promise<Response> {
  const headers = upstream.secret.kind === "anthropic_oauth"
    ? oauthHeaders(request, upstream.secret.token)
    : apiKeyHeaders(request, upstream.secret.kind === "anthropic_api_key" ? upstream.secret.apiKey : "");
  const hasBody = request.method !== "GET" && request.method !== "HEAD";
  const response = await dependencies.fetch(`${ANTHROPIC_UPSTREAM}${pathAndQuery}`, {
    method: request.method,
    headers,
    ...(hasBody ? { body: request.body, duplex: "half" } : {}),
    cache: "no-store",
    ...(signal ? { signal } : {}),
  } as RequestInit & { duplex?: "half" });
  return new Response(response.body, {
    status: response.status,
    headers: responseHeaders(response.headers),
  });
}

function apiKeyHeaders(request: Request, apiKey: string): Headers {
  const headers = new Headers();
  for (const name of API_KEY_FORWARDED_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("x-api-key", apiKey);
  return headers;
}

/**
 * Claude Code relies on its own header set (client identity, betas, system
 * prompt) for the OAuth path, so everything not credential- or transport-
 * related passes through. The OAuth beta flag is added when absent.
 */
function oauthHeaders(request: Request, token: string): Headers {
  const headers = new Headers();
  request.headers.forEach((value, name) => {
    if (isStrippedHeader(name)) return;
    headers.set(name, value);
  });
  headers.set("authorization", `Bearer ${token}`);
  const betas = (headers.get("anthropic-beta") ?? "")
    .split(",")
    .map((beta) => beta.trim())
    .filter(Boolean);
  if (!betas.includes(OAUTH_BETA)) betas.push(OAUTH_BETA);
  headers.set("anthropic-beta", betas.join(","));
  return headers;
}

function isStrippedHeader(name: string): boolean {
  const lower = name.toLowerCase();
  return STRIPPED_HEADERS.has(lower) ||
    STRIPPED_HEADER_PREFIXES.some((prefix) => lower.startsWith(prefix));
}

function responseHeaders(upstream: Headers): Headers {
  const headers = new Headers();
  upstream.forEach((value, name) => {
    const lower = name.toLowerCase();
    if (
      RESPONSE_HEADERS.includes(lower) ||
      RESPONSE_HEADER_PREFIXES.some((prefix) => lower.startsWith(prefix))
    ) {
      headers.set(lower, value);
    }
  });
  headers.set("cache-control", "no-store");
  return headers;
}

// Bedrock upstreams.

type BedrockUpstream = ClaudeUpstream & { secret: { kind: "bedrock" } };

async function readJsonBody(request: Request): Promise<
  | { ok: true; value: Record<string, unknown>; bytes: number }
  | { ok: false; response: Response }
> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BEDROCK_BODY_BYTES) {
    return { ok: false, response: anthropicError(413, "request_too_large", "Request body is too large.") };
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_BEDROCK_BODY_BYTES) {
    return { ok: false, response: anthropicError(413, "request_too_large", "Request body is too large.") };
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return { ok: false, response: anthropicError(400, "invalid_request_error", "Request body is not valid JSON.") };
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ok: false, response: anthropicError(400, "invalid_request_error", "Request body must be a JSON object.") };
  }
  return { ok: true, value: value as Record<string, unknown>, bytes: bytes.byteLength };
}

function bedrockUpstream(upstream: ClaudeUpstream): BedrockUpstream | null {
  return upstream.secret.kind === "bedrock" && upstream.config.region
    ? upstream as BedrockUpstream
    : null;
}

async function bedrockMessages(
  dependencies: ClaudeProxyDependencies,
  request: Request,
  upstream: ClaudeUpstream,
): Promise<Response> {
  const bedrock = bedrockUpstream(upstream);
  if (!bedrock) {
    return anthropicError(503, "api_error", "The team's Bedrock upstream is missing a region. Set it again at coderouter.dev.");
  }
  const parsed = await readJsonBody(request);
  if (!parsed.ok) return parsed.response;
  const invoke = bedrockInvokeBody(parsed.value);
  const modelId = invoke.model ? bedrockModelId(invoke.model, upstream.config.modelIds) : null;
  if (!invoke.model || !modelId) {
    return anthropicError(404, "not_found_error", `model: ${invoke.model ?? "(missing)"}`);
  }
  const region = bedrock.config.region!;
  const url = bedrockRuntimeUrl(region, modelId, invoke.stream ? "invoke-with-response-stream" : "invoke");
  const body = Buffer.from(JSON.stringify(invoke.body), "utf8");
  const response = await bedrockFetch(dependencies, bedrock, url, body, invoke.stream
    ? "application/vnd.amazon.eventstream"
    : "application/json");
  if (!response.ok) return bedrockErrorResponse(response);
  if (invoke.stream) {
    if (!response.body) return anthropicError(502, "api_error", "Bedrock returned an empty stream.");
    return new Response(bedrockEventStreamToSse(response.body, invoke.model), {
      status: 200,
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-store",
        ...requestIdHeader(response.headers),
      },
    });
  }
  const text = await response.text();
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return anthropicError(502, "api_error", "Bedrock returned a malformed response.");
  }
  const rewritten = typeof value === "object" && value !== null && !Array.isArray(value)
    ? { ...(value as Record<string, unknown>), model: invoke.model }
    : value;
  return Response.json(rewritten, {
    status: 200,
    headers: { "cache-control": "no-store", ...requestIdHeader(response.headers) },
  });
}

/**
 * Bedrock's CountTokens API takes the InvokeModel body it would count. When
 * the API is unavailable (older regions, missing IAM permission) the guest
 * gets a `chars / 4` estimate rather than a failure; count_tokens only feeds
 * Claude Code's context meter.
 */
async function bedrockCountTokens(
  dependencies: ClaudeProxyDependencies,
  request: Request,
  upstream: ClaudeUpstream,
): Promise<Response> {
  const bedrock = bedrockUpstream(upstream);
  if (!bedrock) {
    return anthropicError(503, "api_error", "The team's Bedrock upstream is missing a region. Set it again at coderouter.dev.");
  }
  const parsed = await readJsonBody(request);
  if (!parsed.ok) return parsed.response;
  const invoke = bedrockInvokeBody(parsed.value);
  const modelId = invoke.model ? bedrockModelId(invoke.model, upstream.config.modelIds) : null;
  if (!invoke.model || !modelId) {
    return anthropicError(404, "not_found_error", `model: ${invoke.model ?? "(missing)"}`);
  }
  const invokeJson = JSON.stringify(invoke.body);
  const estimate = Math.ceil(invokeJson.length / 4);
  const url = bedrockRuntimeUrl(bedrock.config.region!, modelId, "count-tokens");
  const body = Buffer.from(JSON.stringify({
    input: { invokeModel: { body: Buffer.from(invokeJson, "utf8").toString("base64") } },
  }), "utf8");
  let inputTokens = estimate;
  try {
    const response = await bedrockFetch(dependencies, bedrock, url, body, "application/json");
    if (response.ok) {
      const value: unknown = await response.json();
      const counted = typeof value === "object" && value !== null && !Array.isArray(value)
        ? (value as { inputTokens?: unknown }).inputTokens
        : undefined;
      if (typeof counted === "number" && Number.isInteger(counted) && counted >= 0) {
        inputTokens = counted;
      }
    } else {
      addCoderouterBreadcrumb("routing", "Bedrock CountTokens unavailable, estimating", {
        status: response.status,
      }, "warning");
    }
  } catch (error) {
    reportCoderouterFailure("upstream_transport", error, {
      provider: "claude",
      upstream_kind: "bedrock",
      operation: "count_tokens",
    });
  }
  return Response.json({ input_tokens: inputTokens }, { headers: { "cache-control": "no-store" } });
}

async function bedrockFetch(
  dependencies: ClaudeProxyDependencies,
  upstream: BedrockUpstream,
  url: URL,
  body: Uint8Array<ArrayBuffer>,
  accept: string,
): Promise<Response> {
  const headers = signAwsRequest({
    method: "POST",
    url,
    headers: new Headers({ "content-type": "application/json", accept }),
    body,
    service: "bedrock",
    region: upstream.config.region!,
    credentials: {
      accessKeyId: upstream.secret.accessKeyId,
      secretAccessKey: upstream.secret.secretAccessKey,
      ...(upstream.secret.sessionToken ? { sessionToken: upstream.secret.sessionToken } : {}),
    },
    now: dependencies.now(),
  });
  // `host` is set by the runtime from the URL; sending it explicitly is rejected by fetch.
  headers.delete("host");
  return await dependencies.fetch(url, { method: "POST", headers, body, cache: "no-store" });
}

async function bedrockErrorResponse(response: Response): Promise<Response> {
  const text = (await response.text()).slice(0, MAX_ERROR_BODY_CHARS);
  const mapped = anthropicErrorFromBedrock(
    response.status,
    text,
    response.headers.get("x-amzn-errortype"),
  );
  return Response.json(mapped.body, {
    status: mapped.status,
    headers: {
      "cache-control": "no-store",
      ...requestIdHeader(response.headers),
      ...(response.headers.get("retry-after") ? { "retry-after": response.headers.get("retry-after")! } : {}),
    },
  });
}

function requestIdHeader(headers: Headers): Record<string, string> {
  const id = headers.get("x-amzn-requestid");
  return id ? { "request-id": id } : {};
}

// Errors and analytics.

export function anthropicError(
  status: number,
  type: string,
  message: string,
  headers: Record<string, string> = {},
): Response {
  return Response.json(
    { type: "error", error: { type, message } },
    { status, headers: { "cache-control": "no-store", ...headers } },
  );
}

function captureRouteHealth(dependencies: ClaudeProxyDependencies, input: {
  readonly requestId: string;
  readonly identity?: RouteTokenIdentity;
  readonly request: Request;
  readonly startedAt: number;
  readonly status: number;
  readonly outcome: "success" | "upstream_error" | "provider_unavailable" | "unauthorized";
  readonly failureStage: "none" | "auth" | "provider_config" | "upstream_transport" | "upstream_response";
  readonly responseStreamed: boolean;
}): void {
  const durationMs = Math.round(performance.now() - input.startedAt);
  const agent = agentFromUserAgent(input.request.headers.get("user-agent"));
  addCoderouterBreadcrumb(
    "request",
    "Model request completed",
    {
      provider: "claude",
      status: input.status,
      outcome: input.outcome,
      duration_ms: durationMs,
    },
    input.status >= 500 ? "error" : input.status >= 400 ? "warning" : "info",
  );
  dependencies.capture({
    event: "coderouter_route_health",
    teamId: input.identity?.teamId,
    properties: {
      provider: "claude",
      agent,
      outcome: input.outcome,
      failure_stage: input.failureStage,
      status: input.status,
      attempt_count: 1,
      refresh_retry_count: 0,
      duration_ms: durationMs,
      response_streamed: input.responseStreamed,
      ...(input.identity?.vmId ? { vm_id: input.identity.vmId } : {}),
    },
  });
  recordRouteEvent({
    requestId: input.requestId,
    teamId: input.identity?.teamId,
    vmId: input.identity?.vmId ?? null,
    provider: "claude",
    agent,
    outcome: input.outcome,
    failureStage: input.failureStage,
    status: input.status,
    attemptCount: 1,
    refreshRetryCount: 0,
    durationMs,
    responseStreamed: input.responseStreamed,
  });
}

function captureModelUsage(
  dependencies: ClaudeProxyDependencies,
  identity: RouteTokenIdentity,
  upstreamKind: ClaudeUpstream["kind"],
  usage: ClaudeUsage | null,
  ledger: {
    readonly requestId: string;
    readonly agent: string;
    readonly status: number;
  },
): void {
  if (!usage || usage.totalTokens === 0) return;
  const inputTokens =
    usage.inputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens;
  dependencies.capture({
    event: "coderouter_model_request_completed",
    teamId: identity.teamId,
    properties: {
      provider: "claude",
      upstream_kind: upstreamKind,
      model: usage.model ?? "unknown",
      input_tokens: inputTokens,
      cached_input_tokens: usage.cacheReadInputTokens,
      output_tokens: usage.outputTokens,
      total_tokens: usage.totalTokens,
      ...(identity.vmId ? { vm_id: identity.vmId } : {}),
    },
  });
  recordUsageEvent({
    requestId: ledger.requestId,
    teamId: identity.teamId,
    stackUserId: identity.stackUserId,
    vmId: identity.vmId,
    provider: "claude",
    upstreamKind,
    agent: ledger.agent,
    model: usage.model,
    inputTokens,
    cachedInputTokens: usage.cacheReadInputTokens,
    outputTokens: usage.outputTokens,
    totalTokens: usage.totalTokens,
    status: ledger.status,
  });
}

function agentFromUserAgent(value: string | null): string {
  const normalized = value?.toLowerCase() ?? "";
  if (normalized.includes("claude")) return "claude";
  if (normalized.includes("codex")) return "codex";
  if (normalized.includes("opencode")) return "opencode";
  if (normalized.includes("pi")) return "pi";
  return "other";
}
