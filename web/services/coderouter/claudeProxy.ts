// The Claude leg of coderouter: serves the Anthropic Messages API to a guest
// (Claude Code inside a Cloud VM, or any Anthropic SDK client holding a
// route token) and forwards to one of the team's Claude upstream accounts.
//
// A team may hold many accounts (API keys, Claude Code OAuth tokens, Bedrock
// credentials). Each request is pinned to one account by its client key (the
// Cloud VM id, else the route token) so Anthropic's per-organization prompt
// cache keeps hitting; a 429, a rejected credential, or an unavailable
// upstream puts that account in cooldown and the same request is retried on
// the next healthy account. The request body is buffered once (Anthropic's
// own 32 MiB ceiling) so it can be replayed; responses stream through
// untouched. Bedrock upstreams rewrite the body, sign with SigV4, and convert
// the AWS event stream back to SSE. Usage is read from a bounded head and
// tail of the response only.
import {
  authenticateRequestRouteToken,
  type RouteTokenAuthResult,
  type RouteTokenIdentity,
} from "./routeTokenAuth";
import {
  markClaudeAccountCooldown,
  selectClaudeUpstream,
  touchClaudeAccountUsed,
  type ClaudeSelection,
  type ClaudeUpstream,
} from "./claudeUpstream";
import { captureCoderouterEvent } from "./analytics";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";
import {
  recordRouteEvent,
  recordUsageEvent,
} from "./usageLedger";
import { observeClaudeUsage, type ClaudeUsage } from "./claudeUsage";
import {
  currentCoderouterRequestId,
  recordCoderouterOutcome,
  recordCoderouterSpan,
} from "./requestTelemetry";
import {
  CoderouterOperationDeadlineError,
  CODEROUTER_UPSTREAM_FAILOVER_BUDGET_MS,
  fetchWithHeadersTimeout,
  remainingUpstreamHeadersTimeoutMs,
  upstreamHeadersTimeoutMs,
  withCoderouterOperationDeadline,
} from "./upstreamFetch";
import { isStreamingResponse } from "./responseUsage";
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

/** Anthropic's own request ceiling; every body is buffered up to this. */
const MAX_REQUEST_BODY_BYTES = 32 * 1024 * 1024;
const MAX_ERROR_BODY_CHARS = 16 * 1024;
const MODELS_TIMEOUT_MS = 10_000;
/** Leave room below the 60-second models/count_tokens route ceiling. */
const SHORT_ROUTE_UPSTREAM_FAILOVER_BUDGET_MS = 45_000;

/**
 * Failover budget per request. Each attempt is one account; the loop stops
 * early when the team runs out of healthy accounts.
 */
export const MAX_UPSTREAM_ATTEMPTS = 4;
/** 429 without a usable reset header. */
const DEFAULT_RATE_LIMIT_COOLDOWN_MS = 60_000;
/** 401/403: the credential is revoked, expired, or lacks access; a human must act. */
export const INVALID_CREDENTIAL_COOLDOWN_MS = 15 * 60_000;
/** 5xx / 529 / transport failure: transient, give the account a short rest. */
export const UPSTREAM_UNAVAILABLE_COOLDOWN_MS = 20_000;

type ClaudeSurface = "messages" | "count_tokens" | "models";

export type ClaudeProxyDependencies = {
  readonly authenticate: (request: Request) => Promise<RouteTokenAuthResult>;
  readonly select: typeof selectClaudeUpstream;
  readonly cooldown: typeof markClaudeAccountCooldown;
  readonly touchUsed: typeof touchClaudeAccountUsed;
  readonly fetch: typeof fetch;
  readonly now: () => Date;
  readonly capture: typeof captureCoderouterEvent;
};

/** Runtime seams used by tests to exercise request-wide timeout behavior. */
export type ClaudeProxyRuntimeOverrides = {
  readonly now?: () => number;
  readonly upstreamHeadersBudgetMs?: number;
  readonly upstreamHeadersTimeoutMs?: number;
};

type ClaudeProxyRuntime = {
  readonly now: () => number;
  readonly upstreamHeadersBudgetMs: number;
  readonly upstreamHeadersTimeoutMs: number;
};

const defaultDependencies: ClaudeProxyDependencies = {
  authenticate: (request) => authenticateRequestRouteToken(request),
  select: selectClaudeUpstream,
  cooldown: markClaudeAccountCooldown,
  touchUsed: touchClaudeAccountUsed,
  fetch: (input, init) => fetch(input, init),
  now: () => new Date(),
  capture: captureCoderouterEvent,
};

function resolveClaudeRuntime(
  surface: ClaudeSurface,
  overrides: ClaudeProxyRuntimeOverrides,
): ClaudeProxyRuntime {
  return {
    now: overrides.now ?? (() => performance.now()),
    upstreamHeadersBudgetMs: overrides.upstreamHeadersBudgetMs ??
      (surface === "messages"
        ? CODEROUTER_UPSTREAM_FAILOVER_BUDGET_MS
        : SHORT_ROUTE_UPSTREAM_FAILOVER_BUDGET_MS),
    upstreamHeadersTimeoutMs: overrides.upstreamHeadersTimeoutMs ?? upstreamHeadersTimeoutMs(),
  };
}

type RouteOutcome = "success" | "upstream_error" | "no_usable_account" | "provider_unavailable" | "unauthorized";
type RouteFailureStage =
  | "none"
  | "auth"
  | "account_selection"
  | "provider_config"
  | "upstream_transport"
  | "upstream_response";

type Health = {
  readonly requestId: string;
  readonly startedAt: number;
};

/** What one attempt against one account produced. */
type Attempt =
  | { readonly kind: "response"; readonly response: Response }
  | { readonly kind: "transport"; readonly error: unknown };

/** The result of the failover loop. */
type Routed =
  | {
    readonly kind: "response";
    readonly response: Response;
    readonly upstream: ClaudeUpstream;
    readonly attempts: number;
    /** True when the response is an upstream failure we could not move past. */
    readonly failed: boolean;
    readonly failureStage: RouteFailureStage;
  }
  | {
    readonly kind: "exhausted";
    readonly response: Response;
    readonly attempts: number;
    readonly outcome: RouteOutcome;
    readonly failureStage: RouteFailureStage;
  };

export function createClaudeMessagesProxy(
  dependencies: ClaudeProxyDependencies = defaultDependencies,
  runtimeOverrides: ClaudeProxyRuntimeOverrides = {},
): (request: Request) => Promise<Response> {
  const runtime = resolveClaudeRuntime("messages", runtimeOverrides);
  return async (request) => {
    const health: Health = { requestId: currentCoderouterRequestId(), startedAt: performance.now() };
    const upstreamHeaderDeadlineAt = runtime.now() + runtime.upstreamHeadersBudgetMs;
    const auth = await authenticateRoute(dependencies, request, "messages", health);
    if (!auth.ok) return auth.response;
    const identity = auth.identity;
    const body = await readRequestBytes(request);
    if (!body.ok) return body.response;
    const routed = await routeWithFailover(dependencies, identity, request, "messages", upstreamHeaderDeadlineAt, runtime, (upstream, headersTimeoutMs) =>
      upstream.kind === "bedrock"
        ? bedrockMessages(dependencies, request, body.bytes, upstream, headersTimeoutMs)
        : anthropicRequest(dependencies, request, body.bytes, upstream, "/v1/messages", request.signal, headersTimeoutMs));
    if (routed.kind === "exhausted") {
      captureRouteHealth(dependencies, {
        ...health,
        identity,
        request,
        status: routed.response.status,
        outcome: routed.outcome,
        failureStage: routed.failureStage,
        responseStreamed: false,
        attemptCount: routed.attempts,
      });
      return routed.response;
    }
    const { response, upstream } = routed;
    const streamed = isStreamingResponse(response);
    captureRouteHealth(dependencies, {
      ...health,
      identity,
      request,
      status: response.status,
      outcome: routed.failed ? "upstream_error" : "success",
      failureStage: routed.failed ? routed.failureStage : "none",
      responseStreamed: streamed,
      attemptCount: routed.attempts,
      upstream,
    });
    const agent = agentFromUserAgent(request.headers.get("user-agent"));
    const observed = observeClaudeUsage(response.body, (usage) => {
      captureModelUsage(dependencies, identity, upstream, usage, {
        requestId: health.requestId,
        agent,
        status: response.status,
        durationMs: Math.round(performance.now() - health.startedAt),
        streamed,
      });
    });
    return new Response(observed, { status: response.status, headers: response.headers });
  };
}

export function createClaudeCountTokensProxy(
  dependencies: ClaudeProxyDependencies = defaultDependencies,
  runtimeOverrides: ClaudeProxyRuntimeOverrides = {},
): (request: Request) => Promise<Response> {
  const runtime = resolveClaudeRuntime("count_tokens", runtimeOverrides);
  return async (request) => {
    const upstreamHeaderDeadlineAt = runtime.now() + runtime.upstreamHeadersBudgetMs;
    const auth = await authenticateRoute(dependencies, request, "count_tokens");
    if (!auth.ok) return auth.response;
    const body = await readRequestBytes(request);
    if (!body.ok) return body.response;
    const routed = await routeWithFailover(dependencies, auth.identity, request, "count_tokens", upstreamHeaderDeadlineAt, runtime, (upstream, headersTimeoutMs) =>
      upstream.kind === "bedrock"
        ? bedrockCountTokens(dependencies, request, body.bytes, upstream, headersTimeoutMs)
        : anthropicRequest(dependencies, request, body.bytes, upstream, "/v1/messages/count_tokens", request.signal, headersTimeoutMs));
    recordRoutedOutcome(routed, request);
    return routed.response;
  };
}

export function createClaudeModelsProxy(
  dependencies: ClaudeProxyDependencies = defaultDependencies,
  runtimeOverrides: ClaudeProxyRuntimeOverrides = {},
): (request: Request) => Promise<Response> {
  const runtime = resolveClaudeRuntime("models", runtimeOverrides);
  return async (request) => {
    const upstreamHeaderDeadlineAt = runtime.now() + runtime.upstreamHeadersBudgetMs;
    const auth = await authenticateRoute(dependencies, request, "models");
    if (!auth.ok) return auth.response;
    const routed = await routeWithFailover(dependencies, auth.identity, request, "models", upstreamHeaderDeadlineAt, runtime, async (upstream, headersTimeoutMs) => {
      if (upstream.kind === "bedrock") {
        return Response.json(bedrockModelCatalog(upstream.config.modelIds), {
          headers: { "cache-control": "no-store" },
        });
      }
      return await anthropicRequest(
        dependencies,
        request,
        null,
        upstream,
        `/v1/models${new URL(request.url).search}`,
        AbortSignal.timeout(MODELS_TIMEOUT_MS),
        headersTimeoutMs,
      );
    });
    recordRoutedOutcome(routed, request);
    return routed.response;
  };
}

export const proxyClaudeMessages = createClaudeMessagesProxy();
export const proxyClaudeCountTokens = createClaudeCountTokensProxy();
export const proxyClaudeModels = createClaudeModelsProxy();

/** True when the request comes from an Anthropic client rather than an OpenAI one. */
export function isAnthropicRequest(request: Request): boolean {
  return request.headers.has("anthropic-version");
}

async function authenticateRoute(
  dependencies: ClaudeProxyDependencies,
  request: Request,
  surface: ClaudeSurface,
  /** Present only for the messages surface, which reports route health. */
  health?: Health,
): Promise<{ ok: true; identity: RouteTokenIdentity } | { ok: false; response: Response }> {
  const auth = await dependencies.authenticate(request);
  if (!auth.ok) {
    addCoderouterBreadcrumb("auth", "Route token rejected", { surface, reason: auth.reason }, "warning");
    dependencies.capture({
      event: "coderouter_auth_rejected",
      properties: { surface, reason: auth.reason },
    });
    if (health) {
      captureRouteHealth(dependencies, {
        ...health,
        request,
        status: 401,
        outcome: "unauthorized",
        failureStage: "auth",
        responseStreamed: false,
        attemptCount: 0,
      });
    } else {
      recordCoderouterOutcome({
        outcome: "unauthorized",
        failureStage: "auth",
        status: 401,
        provider: "claude",
        agent: agentFromUserAgent(request.headers.get("user-agent")),
        attempts: 0,
      });
    }
    return {
      ok: false,
      response: anthropicError(401, "authentication_error", authFailureMessage(auth.reason)),
    };
  }
  addCoderouterBreadcrumb("auth", "Route token accepted", { path: surface });
  return { ok: true, identity: auth.identity };
}

/** The key that pins a client to one account: its Cloud VM, else its token. */
function stickyKey(identity: RouteTokenIdentity): string {
  return identity.vmId ?? identity.token;
}

/**
 * Runs `send` against healthy accounts until one answers with something other
 * than a rate limit, a rejected credential, or an unavailable upstream. Each
 * such failure cools the account down and excludes it for the rest of this
 * request. A response the proxy cannot move past (last account, or attempt
 * budget spent) is returned as-is so the client sees the real upstream error.
 */
async function routeWithFailover(
  dependencies: ClaudeProxyDependencies,
  identity: RouteTokenIdentity,
  request: Request,
  surface: ClaudeSurface,
  upstreamHeaderDeadlineAt: number,
  runtime: ClaudeProxyRuntime,
  send: (upstream: ClaudeUpstream, headersTimeoutMs: number) => Promise<Response>,
): Promise<Routed> {
  const excluded: string[] = [];
  let lastFailure: { response: Response; upstream: ClaudeUpstream; stage: RouteFailureStage } | null = null;
  let attempts = 0;
  while (attempts < MAX_UPSTREAM_ATTEMPTS) {
    throwIfRequestAborted(request);
    if (remainingUpstreamHeadersTimeoutMs(
      upstreamHeaderDeadlineAt,
      runtime.now(),
      runtime.upstreamHeadersTimeoutMs,
    ) === null) {
      return deadlineResult(attempts, lastFailure);
    }
    let selection: ClaudeSelection;
    const selectStartedAt = performance.now();
    try {
      selection = await withCoderouterOperationDeadline(
        request.signal,
        upstreamHeaderDeadlineAt,
        runtime.now,
        (signal) => dependencies.select(identity.teamId, {
          stickyKey: stickyKey(identity),
          excludedAccountIds: excluded,
          signal,
        }),
      );
      recordCoderouterSpan({
        name: "account_selection",
        startedAt: selectStartedAt,
        attributes: { provider: "claude", attempt: attempts + 1, outcome: selection.kind },
      });
    } catch (error) {
      if (request.signal.aborted) throw error;
      recordCoderouterSpan({
        name: "account_selection",
        startedAt: selectStartedAt,
        error: error instanceof CoderouterOperationDeadlineError
          ? "deadline_exceeded"
          : error instanceof Error ? error.name : "select_failed",
        attributes: {
          provider: "claude",
          attempt: attempts + 1,
          ...(error instanceof CoderouterOperationDeadlineError ? { timeout_ms: error.timeoutMs } : {}),
        },
      });
      if (error instanceof CoderouterOperationDeadlineError) {
        return deadlineResult(attempts, lastFailure, "account_selection");
      }
      reportCoderouterFailure("rds", error, {
        provider: "claude",
        operation: "select_claude_account",
        request_id: currentCoderouterRequestId(),
      });
      return {
        kind: "exhausted",
        attempts,
        outcome: "provider_unavailable",
        failureStage: "account_selection",
        response: anthropicError(503, "api_error", "coderouter could not load the team's Claude accounts. Retry shortly.", {
          "retry-after": "5",
        }),
      };
    }
    throwIfRequestAborted(request);
    if (selection.kind === "none") {
      // The team has not added a Claude account: a tenant state, not an
      // outage, so it shares the `no_usable_account` outcome and is told
      // apart by the `provider_config` stage.
      addCoderouterBreadcrumb("routing", "No Claude upstream account configured", { surface }, "warning");
      return {
        kind: "exhausted",
        attempts,
        outcome: "no_usable_account",
        failureStage: "provider_config",
        response: anthropicError(
          503,
          "api_error",
          "No Claude upstream account is configured for this team. Add one with `cmux coderouter claude add` or at coderouter.dev.",
          { "retry-after": "30" },
        ),
      };
    }
    if (selection.kind === "exhausted") {
      // Prefer the last real upstream answer over a synthetic one: the client
      // learns why (rate limit, revoked key) and how long to wait.
      if (lastFailure) {
        return { kind: "response", ...lastFailure, attempts, failed: true, failureStage: lastFailure.stage };
      }
      addCoderouterBreadcrumb("routing", "Every Claude account is cooling down", {
        surface,
        total: selection.total,
      }, "warning");
      return {
        kind: "exhausted",
        attempts,
        outcome: "no_usable_account",
        failureStage: "account_selection",
        response: anthropicError(
          503,
          "overloaded_error",
          "Every Claude upstream account of this team is cooling down or disabled. Retry shortly or add an account.",
          { "retry-after": String(selection.retryAfterSeconds) },
        ),
      };
    }
    const upstream = selection.upstream;
    attempts += 1;
    addCoderouterBreadcrumb("routing", "Selected Claude upstream account", {
      provider: "claude",
      upstream_kind: upstream.kind,
      upstream_account_id: upstream.accountId,
      attempt: attempts,
      healthy: selection.healthy,
      total: selection.total,
    });
    let attempt: Attempt;
    const attemptStartedAt = performance.now();
    const headersTimeoutMs = remainingUpstreamHeadersTimeoutMs(
      upstreamHeaderDeadlineAt,
      runtime.now(),
      runtime.upstreamHeadersTimeoutMs,
    );
    if (headersTimeoutMs === null) return deadlineResult(attempts, lastFailure);
    try {
      attempt = { kind: "response", response: await send(upstream, headersTimeoutMs) };
    } catch (error) {
      if (request.signal.aborted) throw error;
      attempt = { kind: "transport", error };
    }
    const verdict = classifyAttempt(attempt);
    recordCoderouterSpan({
      name: "upstream_attempt",
      startedAt: attemptStartedAt,
      ...(verdict.kind === "failover" ? { error: verdict.failureCode } : {}),
      attributes: {
        provider: "claude",
        upstream_kind: upstream.kind,
        attempt: attempts,
        surface,
        status: attempt.kind === "response" ? attempt.response.status : 0,
        ...(verdict.kind === "failover" ? { failure_code: verdict.failureCode, cooldown_ms: verdict.cooldownMs } : {}),
      },
    });
    if (verdict.kind === "done") {
      void dependencies.touchUsed(upstream.accountId, request.signal).catch(() => undefined);
      return { kind: "response", response: verdict.response, upstream, attempts, failed: false, failureStage: "none" };
    }
    if (attempt.kind === "transport") {
      reportCoderouterFailure("upstream_transport", attempt.error, {
        provider: "claude",
        upstream_kind: upstream.kind,
        operation: surface,
        request_id: currentCoderouterRequestId(),
      });
    }
    addCoderouterBreadcrumb("routing", "Claude account cooled down", {
      upstream_kind: upstream.kind,
      upstream_account_id: upstream.accountId,
      reason: verdict.failureCode,
      cooldown_ms: verdict.cooldownMs,
      status: attempt.kind === "response" ? attempt.response.status : 0,
    }, "warning");
    lastFailure = {
      upstream,
      stage: verdict.stage,
      response: attempt.kind === "response"
        ? attempt.response
        : anthropicError(502, "api_error", "coderouter could not reach the Claude upstream. Retry shortly."),
    };
    try {
      await withCoderouterOperationDeadline(
        request.signal,
        upstreamHeaderDeadlineAt,
        runtime.now,
        (signal) => dependencies.cooldown(upstream.accountId, verdict.cooldownMs, verdict.failureCode, signal),
      );
    } catch (error) {
      if (request.signal.aborted) throw error;
      if (error instanceof CoderouterOperationDeadlineError) {
        return deadlineResult(attempts, lastFailure, "upstream_transport");
      }
      reportCoderouterFailure("rds", error, { provider: "claude", operation: "cooldown_claude_account" });
    }
    excluded.push(upstream.accountId);
  }
  return deadlineResult(attempts, lastFailure);
}

function deadlineResult(
  attempts: number,
  lastFailure: { response: Response; upstream: ClaudeUpstream; stage: RouteFailureStage } | null,
  failureStage: RouteFailureStage = "upstream_transport",
): Routed {
  if (lastFailure) {
    return { kind: "response", ...lastFailure, attempts, failed: true, failureStage: lastFailure.stage };
  }
  return {
    kind: "exhausted",
    attempts,
    outcome: "provider_unavailable",
    failureStage,
    response: anthropicError(503, "api_error", "coderouter could not reach a Claude upstream within the request time limit. Retry shortly.", {
      "retry-after": "5",
    }),
  };
}

function throwIfRequestAborted(request: Request): void {
  if (!request.signal.aborted) return;
  throw request.signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}

type Verdict =
  | { readonly kind: "done"; readonly response: Response }
  | {
    readonly kind: "failover";
    readonly cooldownMs: number;
    readonly failureCode: string;
    readonly stage: RouteFailureStage;
  };

/**
 * Which upstream answers justify moving to another account. Client errors
 * (400, 404, 413, 422) are the guest's problem and are returned untouched.
 */
function classifyAttempt(attempt: Attempt): Verdict {
  if (attempt.kind === "transport") {
    return {
      kind: "failover",
      cooldownMs: UPSTREAM_UNAVAILABLE_COOLDOWN_MS,
      failureCode: "upstream_transport",
      stage: "upstream_transport",
    };
  }
  const { status, headers } = attempt.response;
  if (status === 429) {
    return { kind: "failover", cooldownMs: rateLimitDelay(headers), failureCode: "rate_limited", stage: "upstream_response" };
  }
  if (status === 401 || status === 403) {
    return {
      kind: "failover",
      cooldownMs: INVALID_CREDENTIAL_COOLDOWN_MS,
      failureCode: "invalid_credential",
      stage: "upstream_response",
    };
  }
  if (status === 500 || status === 502 || status === 503 || status === 529) {
    return {
      kind: "failover",
      cooldownMs: UPSTREAM_UNAVAILABLE_COOLDOWN_MS,
      failureCode: "upstream_unavailable",
      stage: "upstream_response",
    };
  }
  return { kind: "done", response: attempt.response };
}

/**
 * How long a rate-limited account rests: Anthropic's `retry-after` seconds,
 * else the earliest `anthropic-ratelimit-*-reset` timestamp, else a minute.
 */
export function rateLimitDelay(headers: Headers, now: Date = new Date()): number {
  const retryAfter = headers.get("retry-after");
  if (retryAfter && /^\d+$/.test(retryAfter)) {
    return Math.max(1_000, Number(retryAfter) * 1_000);
  }
  let soonest: number | null = null;
  headers.forEach((value, name) => {
    if (!name.toLowerCase().startsWith("anthropic-ratelimit-") || !name.toLowerCase().endsWith("-reset")) return;
    const at = Date.parse(value);
    if (!Number.isFinite(at)) return;
    const delta = at - now.getTime();
    if (delta > 0 && (soonest === null || delta < soonest)) soonest = delta;
  });
  return soonest ?? DEFAULT_RATE_LIMIT_COOLDOWN_MS;
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

// Request body.

async function readRequestBytes(request: Request): Promise<
  | { ok: true; bytes: Uint8Array<ArrayBuffer> | null }
  | { ok: false; response: Response }
> {
  if (request.method === "GET" || request.method === "HEAD") return { ok: true, bytes: null };
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_REQUEST_BODY_BYTES) {
    return { ok: false, response: anthropicError(413, "request_too_large", "Request body is too large.") };
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_REQUEST_BODY_BYTES) {
    return { ok: false, response: anthropicError(413, "request_too_large", "Request body is too large.") };
  }
  return { ok: true, bytes };
}

function parseJsonObject(bytes: Uint8Array | null):
  | { ok: true; value: Record<string, unknown> }
  | { ok: false; response: Response } {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(bytes ?? new Uint8Array()));
  } catch {
    return { ok: false, response: anthropicError(400, "invalid_request_error", "Request body is not valid JSON.") };
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ok: false, response: anthropicError(400, "invalid_request_error", "Request body must be a JSON object.") };
  }
  return { ok: true, value: value as Record<string, unknown> };
}

// Direct Anthropic upstreams.

async function anthropicRequest(
  dependencies: ClaudeProxyDependencies,
  request: Request,
  body: Uint8Array<ArrayBuffer> | null,
  upstream: ClaudeUpstream,
  pathAndQuery: string,
  signal?: AbortSignal,
  headersTimeoutMs: number = upstreamHeadersTimeoutMs(),
): Promise<Response> {
  const headers = upstream.secret.kind === "anthropic_oauth"
    ? oauthHeaders(request, upstream.secret.token)
    : apiKeyHeaders(request, upstream.secret.kind === "anthropic_api_key" ? upstream.secret.apiKey : "");
  // Bounded to headers only: a hung upstream fails over to the next account
  // instead of holding the function for the full maxDuration.
  const requestSignal = signal
    ? AbortSignal.any([request.signal, signal])
    : request.signal;
  const response = await fetchWithHeadersTimeout(dependencies.fetch, `${ANTHROPIC_UPSTREAM}${pathAndQuery}`, {
    method: request.method,
    headers,
    ...(body ? { body } : {}),
    cache: "no-store",
    signal: requestSignal,
  }, headersTimeoutMs);
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

function bedrockUpstream(upstream: ClaudeUpstream): BedrockUpstream | null {
  return upstream.secret.kind === "bedrock" && upstream.config.region
    ? upstream as BedrockUpstream
    : null;
}

async function bedrockMessages(
  dependencies: ClaudeProxyDependencies,
  request: Request,
  body: Uint8Array<ArrayBuffer> | null,
  upstream: ClaudeUpstream,
  headersTimeoutMs: number,
): Promise<Response> {
  const bedrock = bedrockUpstream(upstream);
  if (!bedrock) {
    return anthropicError(503, "api_error", "The team's Bedrock account is missing a region. Add it again at coderouter.dev.");
  }
  const parsed = parseJsonObject(body);
  if (!parsed.ok) return parsed.response;
  const invoke = bedrockInvokeBody(parsed.value);
  const modelId = invoke.model ? bedrockModelId(invoke.model, upstream.config.modelIds) : null;
  if (!invoke.model || !modelId) {
    return anthropicError(404, "not_found_error", `model: ${invoke.model ?? "(missing)"}`);
  }
  const region = bedrock.config.region!;
  const url = bedrockRuntimeUrl(region, modelId, invoke.stream ? "invoke-with-response-stream" : "invoke");
  const invokeBytes = Buffer.from(JSON.stringify(invoke.body), "utf8");
  const response = await bedrockFetch(dependencies, bedrock, url, invokeBytes, invoke.stream
    ? "application/vnd.amazon.eventstream"
    : "application/json", request.signal, headersTimeoutMs);
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
  body: Uint8Array<ArrayBuffer> | null,
  upstream: ClaudeUpstream,
  headersTimeoutMs: number,
): Promise<Response> {
  const bedrock = bedrockUpstream(upstream);
  if (!bedrock) {
    return anthropicError(503, "api_error", "The team's Bedrock account is missing a region. Add it again at coderouter.dev.");
  }
  const parsed = parseJsonObject(body);
  if (!parsed.ok) return parsed.response;
  const invoke = bedrockInvokeBody(parsed.value);
  const modelId = invoke.model ? bedrockModelId(invoke.model, upstream.config.modelIds) : null;
  if (!invoke.model || !modelId) {
    return anthropicError(404, "not_found_error", `model: ${invoke.model ?? "(missing)"}`);
  }
  const invokeJson = JSON.stringify(invoke.body);
  const estimate = Math.ceil(invokeJson.length / 4);
  const url = bedrockRuntimeUrl(bedrock.config.region!, modelId, "count-tokens");
  const countBody = Buffer.from(JSON.stringify({
    input: { invokeModel: { body: Buffer.from(invokeJson, "utf8").toString("base64") } },
  }), "utf8");
  let inputTokens = estimate;
  try {
    const response = await bedrockFetch(
      dependencies,
      bedrock,
      url,
      countBody,
      "application/json",
      request.signal,
      headersTimeoutMs,
    );
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
  signal: AbortSignal,
  headersTimeoutMs: number,
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
  return await fetchWithHeadersTimeout(dependencies.fetch, url, {
    method: "POST",
    headers,
    body,
    signal,
    cache: "no-store",
  }, headersTimeoutMs);
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

/**
 * Terminal outcome of a count_tokens or models call for the request context
 * (PostHog trace, Axiom span). These surfaces are not ledger rows.
 */
function recordRoutedOutcome(routed: Routed, request: Request): void {
  const agent = agentFromUserAgent(request.headers.get("user-agent"));
  if (routed.kind === "exhausted") {
    recordCoderouterOutcome({
      outcome: routed.outcome,
      failureStage: routed.failureStage,
      status: routed.response.status,
      provider: "claude",
      agent,
      attempts: routed.attempts,
    });
    return;
  }
  recordCoderouterOutcome({
    outcome: routed.failed ? "upstream_error" : "success",
    failureStage: routed.failed ? routed.failureStage : "none",
    status: routed.response.status,
    provider: "claude",
    agent,
    attempts: routed.attempts,
    upstreamKind: routed.upstream.kind,
    upstreamAccountId: routed.upstream.accountId,
  });
}

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

function captureRouteHealth(dependencies: ClaudeProxyDependencies, input: Health & {
  readonly identity?: RouteTokenIdentity;
  readonly request: Request;
  readonly status: number;
  readonly outcome: RouteOutcome;
  readonly failureStage: RouteFailureStage;
  readonly responseStreamed: boolean;
  readonly attemptCount: number;
  readonly upstream?: ClaudeUpstream;
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
      attempt_count: input.attemptCount,
    },
    input.status >= 500 ? "error" : input.status >= 400 ? "warning" : "info",
  );
  recordCoderouterOutcome({
    outcome: input.outcome,
    failureStage: input.failureStage,
    status: input.status,
    provider: "claude",
    agent,
    attempts: input.attemptCount,
    refreshRetries: 0,
    responseStreamed: input.responseStreamed,
    upstreamKind: input.upstream?.kind,
    upstreamAccountId: input.upstream?.accountId,
  });
  recordRouteEvent({
    requestId: input.requestId,
    teamId: input.identity?.teamId,
    stackUserId: input.identity?.stackUserId,
    vmId: input.identity?.vmId ?? null,
    provider: "claude",
    agent,
    outcome: input.outcome,
    failureStage: input.failureStage,
    status: input.status,
    attemptCount: input.attemptCount,
    refreshRetryCount: 0,
    durationMs,
    responseStreamed: input.responseStreamed,
    upstreamAccountId: input.upstream?.accountId,
  });
}

function captureModelUsage(
  dependencies: ClaudeProxyDependencies,
  identity: RouteTokenIdentity,
  upstream: ClaudeUpstream,
  usage: ClaudeUsage | null,
  ledger: {
    readonly requestId: string;
    readonly agent: string;
    readonly status: number;
    readonly durationMs?: number;
    readonly streamed?: boolean;
  },
): void {
  if (!usage || usage.totalTokens === 0) return;
  const inputTokens =
    usage.inputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens;
  recordUsageEvent({
    requestId: ledger.requestId,
    teamId: identity.teamId,
    stackUserId: identity.stackUserId,
    vmId: identity.vmId,
    provider: "claude",
    upstreamKind: upstream.kind,
    upstreamAccountId: upstream.accountId,
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
