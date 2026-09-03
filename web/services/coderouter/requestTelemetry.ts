// One coderouter request as telemetry sees it.
//
// Every coderouter route runs inside `withCoderouterRoute`, which owns one
// request context (AsyncLocalStorage), one OpenTelemetry route span (Axiom),
// and one PostHog trace in the isolated coderouter project. The proxies and
// the auth helper enrich the context as the request proceeds: the identity
// once the route token is verified, one span per upstream attempt, and the
// terminal outcome when the route result is known. After the response the
// wrapper ships one batch to PostHog:
//
// - `$ai_trace` (root) with the outcome, status, latency, provider, agent,
//   attempts and the Axiom trace id, so the LLM analytics waterfall shows the
//   request end to end;
// - one `$ai_span` per recorded step (auth, account selection, each upstream
//   attempt, credential refresh);
// - `$exception` (Error Tracking) for every failure that is not the caller's
//   fault, fingerprinted by outcome, stage and provider, `error` level when the
//   fault is ours (RDS, config, crash), `warning` when an upstream provider or
//   the tenant's account state caused it.
//
// The ledger request id (`x-coderouter-request-id` on every response) is the
// PostHog `$ai_trace_id` and the ClickHouse `request_id`, so one id joins the
// customer's report, the PostHog trace, the ClickHouse row and, via the
// `trace_id` property, the Axiom span. No prompt, output, header, credential,
// email or account label ever enters this module.
import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import { after } from "next/server";
import { trace, type Span } from "@opentelemetry/api";

// Namespace import: test suites replace `./analytics` with partial mocks, and a
// missing named export must degrade to "no PostHog leg", not a link error.
import * as analytics from "./analytics";
import type { CoderouterRawEvent } from "./analytics";
import { errorSummary, exceptionEvent, scrubTelemetryText } from "./exceptionEvent";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";
import type { RouteTokenIdentity } from "./routeTokenAuth";
import {
  forceFlushTraces,
  setSpanAttributes,
  spanTraceIds,
  withApiRouteSpan,
} from "../telemetry";

/** Ledger request id, echoed on every coderouter response. */
export const CODEROUTER_REQUEST_ID_HEADER = "x-coderouter-request-id";
/** Marker for proxy helpers invoked outside a route context, such as tests. */
export const UNSCOPED_CODEROUTER_REQUEST_ID = "unscoped";

export type CoderouterSurface =
  | "responses"
  | "messages"
  | "count_tokens"
  | "models"
  | "opencode_config"
  | "opencode_proxy"
  | "accounts"
  | "session"
  | "claude_upstream"
  | "vm_usage"
  | "analytics"
  | "health";

export type CoderouterOutcome = {
  readonly outcome: string;
  readonly failureStage: string;
  readonly status: number;
  readonly provider?: string;
  readonly agent?: string;
  readonly attempts?: number;
  readonly refreshRetries?: number;
  readonly upstreamKind?: string;
  readonly upstreamAccountId?: string;
  readonly responseStreamed?: boolean;
};

export type CoderouterSpanInput = {
  readonly name: string;
  /** `performance.now()` when the step started. */
  readonly startedAt: number;
  /** `performance.now()` when the step ended; defaults to now. */
  readonly endedAt?: number;
  readonly error?: string;
  readonly attributes?: Readonly<Record<string, string | number | boolean | null | undefined>>;
};

type RecordedSpan = {
  readonly id: string;
  readonly name: string;
  readonly startedAtEpochMs: number;
  readonly durationMs: number;
  readonly error?: string;
  readonly attributes: Record<string, string | number | boolean>;
};

export type CoderouterRequestContext = {
  readonly requestId: string;
  readonly surface: CoderouterSurface;
  readonly method: string;
  readonly route: string;
  readonly startedAt: number;
  readonly startedAtEpochMs: number;
  readonly vercelRequestId?: string;
  identity?: Pick<RouteTokenIdentity, "teamId" | "stackUserId" | "vmId">;
  /** Stack user id for control-plane routes (no route token). */
  userId?: string;
  outcome?: CoderouterOutcome;
  readonly spans: RecordedSpan[];
  traceId?: string;
  spanId?: string;
};

const storage = new AsyncLocalStorage<CoderouterRequestContext>();
const MAX_SPANS_PER_REQUEST = 64;
const ATTRIBUTE_VALUE_MAX = 200;
const SPAN_ATTRIBUTE_SENSITIVE = /account.?id|authorization|body|content|cookie|credential|email|header|key|prompt|response|secret|session|token/i;
let traceFlushScheduled = false;

export function currentCoderouterRequest(): CoderouterRequestContext | undefined {
  return storage.getStore();
}

/** Runs `fn` inside a fresh request context; tests use it without a Response. */
export function runWithCoderouterRequest<T>(
  context: CoderouterRequestContext,
  fn: () => T,
): T {
  return storage.run(context, fn);
}

export function newCoderouterRequestContext(input: {
  readonly request: Request;
  readonly surface: CoderouterSurface;
  readonly route: string;
  readonly requestId?: string;
}): CoderouterRequestContext {
  return {
    // Same grammar as `newLedgerRequestId` (a UUID); minted here so this
    // module has no dependency on the ledger.
    requestId: input.requestId ?? randomUUID(),
    surface: input.surface,
    method: input.request.method,
    route: input.route,
    startedAt: performance.now(),
    startedAtEpochMs: Date.now(),
    vercelRequestId: input.request.headers.get("x-vercel-id")?.slice(0, 120) ?? undefined,
    spans: [],
  };
}

/** The ledger request id of the active request, or an explicit non-joinable marker. */
export function currentCoderouterRequestId(): string {
  return storage.getStore()?.requestId ?? UNSCOPED_CODEROUTER_REQUEST_ID;
}

export function recordCoderouterIdentity(
  identity: Pick<RouteTokenIdentity, "teamId" | "stackUserId" | "vmId">,
): void {
  const context = storage.getStore();
  if (!context) return;
  context.identity = { teamId: identity.teamId, stackUserId: identity.stackUserId, vmId: identity.vmId };
  const span = trace.getActiveSpan();
  if (span) {
    setSpanAttributes(span, {
      "cmux.coderouter.bound_to_vm": identity.vmId !== null,
      "cmux.coderouter.vm_id": identity.vmId ?? undefined,
    });
  }
}

export function recordCoderouterUser(userId: string): void {
  const context = storage.getStore();
  if (context) context.userId = userId;
}

/**
 * The terminal route result. Proxies call this from their route-health
 * capture, so the PostHog trace, the ClickHouse row and the response share
 * one outcome vocabulary.
 */
export function recordCoderouterOutcome(outcome: CoderouterOutcome): void {
  const context = storage.getStore();
  if (context) context.outcome = outcome;
  const span = trace.getActiveSpan();
  if (span) {
    setSpanAttributes(span, {
      "cmux.coderouter.outcome": outcome.outcome,
      "cmux.coderouter.failure_stage": outcome.failureStage,
      "cmux.coderouter.provider": outcome.provider,
      "cmux.coderouter.agent": outcome.agent,
      "cmux.coderouter.attempts": outcome.attempts,
      "cmux.coderouter.refresh_retries": outcome.refreshRetries,
      "cmux.coderouter.upstream_kind": outcome.upstreamKind,
      "cmux.coderouter.response_streamed": outcome.responseStreamed,
    });
  }
}

/**
 * One step of the request for the PostHog waterfall. Bounded per request;
 * attribute keys that could carry a secret or an identifier are dropped.
 */
export function recordCoderouterSpan(input: CoderouterSpanInput): void {
  const context = storage.getStore();
  if (!context || context.spans.length >= MAX_SPANS_PER_REQUEST) return;
  const endedAt = input.endedAt ?? performance.now();
  const attributes: Record<string, string | number | boolean> = {};
  for (const [key, value] of Object.entries(input.attributes ?? {})) {
    if (value === null || value === undefined) continue;
    if (SPAN_ATTRIBUTE_SENSITIVE.test(key) && key !== "upstream_kind") continue;
    attributes[key] = typeof value === "string" ? value.slice(0, ATTRIBUTE_VALUE_MAX) : value;
  }
  context.spans.push({
    id: randomUUID(),
    name: input.name.slice(0, 80),
    startedAtEpochMs: context.startedAtEpochMs + Math.max(0, Math.round(input.startedAt - context.startedAt)),
    durationMs: Math.max(0, Math.round((endedAt - input.startedAt) * 100) / 100),
    ...(input.error ? { error: scrubTelemetryText(input.error).slice(0, ATTRIBUTE_VALUE_MAX) } : {}),
    attributes,
  });
}

/**
 * Times an async step and records it as a span. The step's rejection is
 * recorded, then rethrown unchanged.
 */
export async function spanned<T>(
  name: string,
  fn: () => Promise<T>,
  attributes?: CoderouterSpanInput["attributes"],
): Promise<T> {
  const startedAt = performance.now();
  try {
    const value = await fn();
    recordCoderouterSpan({ name, startedAt, attributes });
    return value;
  } catch (error) {
    recordCoderouterSpan({ name, startedAt, attributes, error: errorSummary(error) });
    throw error;
  }
}

// Fault classification.

export type CoderouterFault = "none" | "caller" | "tenant" | "upstream" | "operator";

/**
 * Whose fault a terminal outcome is. Only `operator` pages anyone: RDS, KMS,
 * config and crashes are ours. `upstream` is a provider outage, rate limit or
 * bad provider catalog we failed over on and still lost. `tenant` is a team
 * with no usable account (none added, all cooling down). `caller` is a bad
 * token or a client error the guest must fix.
 */
export function classifyCoderouterFault(outcome: CoderouterOutcome): CoderouterFault {
  const { status } = outcome;
  if (status < 400) return "none";
  if (outcome.outcome === "unauthorized" || (status < 500 && status !== 429)) return "caller";
  switch (outcome.outcome) {
    case "route_crash":
      return "operator";
    case "provider_unavailable":
      return outcome.failureStage === "upstream_transport" ||
          outcome.failureStage === "upstream_response"
        ? "upstream"
        : "operator";
    case "no_usable_account":
      return outcome.failureStage === "credential_refresh" || outcome.failureStage === "upstream_transport"
        ? "upstream"
        : "tenant";
    case "upstream_error":
      return "upstream";
    case "invalid_provider":
    case "unknown_provider":
      return "upstream";
    default:
      return status >= 500 ? "operator" : "caller";
  }
}

// PostHog event builders.

/**
 * The PostHog batch for one finished request: the `$ai_trace` root, its
 * `$ai_span` children, and an `$exception` when the outcome was a failure the
 * caller did not cause. Exported for tests; `withCoderouterRoute` sends it.
 */
export function traceEvents(
  context: CoderouterRequestContext,
  input: { readonly status: number; readonly durationMs: number; readonly error?: unknown },
): CoderouterRawEvent[] {
  const outcome: CoderouterOutcome = input.error !== undefined || context.outcome === undefined
    ? derivedOutcome(context, input)
    : context.outcome;
  const fault = classifyCoderouterFault(outcome);
  const isError = fault !== "none" && fault !== "caller";
  const teamId = context.identity?.teamId;
  const userId = context.identity?.stackUserId ?? context.userId;
  const common = {
    coderouter_request_id: context.requestId,
    coderouter_surface: context.surface,
    coderouter_provider: outcome.provider ?? "unknown",
    coderouter_agent: outcome.agent ?? "unknown",
    coderouter_outcome: outcome.outcome,
    coderouter_failure_stage: outcome.failureStage,
    coderouter_fault: fault,
    coderouter_status: input.status,
    ...(context.traceId ? { trace_id: context.traceId } : {}),
    ...(context.vercelRequestId ? { vercel_request_id: context.vercelRequestId } : {}),
    ...(context.identity?.vmId ? { coderouter_vm_id: context.identity.vmId } : {}),
  };
  const events: CoderouterRawEvent[] = [
    {
      event: "$ai_trace",
      userId,
      teamId,
      timestamp: new Date(context.startedAtEpochMs).toISOString(),
      properties: {
        ...common,
        $ai_trace_id: context.requestId,
        $ai_span_name: `coderouter ${context.method} ${context.route}`,
        $ai_latency: input.durationMs / 1_000,
        $ai_http_status: input.status,
        $ai_is_error: isError,
        ...(isError ? { $ai_error: `${outcome.outcome}/${outcome.failureStage}` } : {}),
        coderouter_attempts: outcome.attempts ?? 0,
        coderouter_refresh_retries: outcome.refreshRetries ?? 0,
        coderouter_response_streamed: outcome.responseStreamed === true,
        ...(outcome.upstreamKind ? { upstream_kind: outcome.upstreamKind } : {}),
        ...(outcome.upstreamAccountId ? { upstream_account_id: outcome.upstreamAccountId } : {}),
      },
    },
  ];
  for (const span of context.spans) {
    events.push({
      event: "$ai_span",
      userId,
      teamId,
      timestamp: new Date(span.startedAtEpochMs).toISOString(),
      properties: {
        ...span.attributes,
        coderouter_request_id: context.requestId,
        $ai_trace_id: context.requestId,
        $ai_parent_id: context.requestId,
        $ai_span_id: span.id,
        $ai_span_name: span.name,
        $ai_latency: span.durationMs / 1_000,
        $ai_is_error: span.error !== undefined,
        ...(span.error ? { $ai_error: span.error } : {}),
      },
    });
  }
  if (isError) {
    const summary = input.error !== undefined
      ? errorSummary(input.error)
      : `coderouter ${outcome.outcome} (${outcome.failureStage}) HTTP ${input.status}`;
    events.push(exceptionEvent({
      type: input.error instanceof Error ? input.error.name : `coderouter_${outcome.outcome}`,
      value: summary,
      fingerprint: `coderouter:${outcome.outcome}:${outcome.failureStage}:${outcome.provider ?? "unknown"}`,
      level: fault === "operator" ? "error" : "warning",
      error: input.error,
      handled: input.error === undefined,
      userId,
      teamId,
      properties: { ...common, $ai_trace_id: context.requestId },
    }));
  }
  return events;
}

function derivedOutcome(
  context: CoderouterRequestContext,
  input: { readonly status: number; readonly error?: unknown },
): CoderouterOutcome {
  if (input.error !== undefined) {
    return { outcome: "route_crash", failureStage: "handler", status: input.status };
  }
  const { status } = input;
  const outcome = status < 400
    ? "success"
    : status === 401 || status === 403
    ? "unauthorized"
    : status < 500
    ? "client_error"
    : "server_error";
  return {
    outcome,
    failureStage: status < 400 ? "none" : status < 500 ? "request" : "handler",
    status,
  };
}

// Route wrapper.

export type CoderouterRouteHandler<Context> = (request: Request, context: Context) => Promise<Response>;

export type CoderouterRouteOptions = {
  readonly surface: CoderouterSurface;
  /** Route pattern for the span name and PostHog, e.g. `/v1/messages`. */
  readonly route: string;
  /**
   * The response for an unhandled throw, in the surface's own error shape
   * (Anthropic clients need `{type:"error",...}`). Always a 503.
   */
  readonly unavailable: (request: Request) => Response;
};

/** The generic 503 body every non-Anthropic coderouter surface uses. */
export function coderouterUnavailable(): Response {
  return Response.json(
    { error: "coderouter_unavailable", message: "coderouter is temporarily unavailable. Retry shortly.", retryable: true },
    { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } },
  );
}

/** `withCoderouterRoute` for control-plane routes with the generic 503. */
export function coderouterControlRoute<Context = unknown>(
  surface: CoderouterSurface,
  route: string,
  handler: CoderouterRouteHandler<Context>,
): (request: Request, context?: Context) => Promise<Response> {
  return withCoderouterRoute({ surface, route, unavailable: coderouterUnavailable }, handler);
}

/**
 * Wraps a route handler so every request has a ledger request id, a route
 * span, a request context, trace and request-id response headers, and a
 * post-response PostHog batch. An unhandled throw is reported with its real
 * stack (Sentry via `reportCoderouterFailure`, PostHog `$exception`) and
 * answered with the surface's 503, never swallowed.
 */
export function withCoderouterRoute<Context = unknown>(
  options: CoderouterRouteOptions,
  handler: CoderouterRouteHandler<Context>,
): (request: Request, context?: Context) => Promise<Response> {
  return async (request, routeContext) => {
    const context = newCoderouterRequestContext({ request, surface: options.surface, route: options.route });
    return runWithCoderouterRequest(context, () =>
      withApiRouteSpan(
        request,
        options.route,
        { "cmux.subsystem": "coderouter", "cmux.coderouter.request_id": context.requestId },
        async (span) => {
          const ids = spanTraceIds(span);
          if (ids) {
            context.traceId = ids.traceId;
            context.spanId = ids.spanId;
          }
          let response: Response;
          let thrown: unknown;
          try {
            response = await handler(request, routeContext as Context);
          } catch (error) {
            thrown = error;
            reportCoderouterFailure("route_crash", error, {
              surface: options.surface,
              route: options.route,
              request_id: context.requestId,
            });
            response = options.unavailable(request);
          }
          response = withRequestIdHeader(response, context.requestId);
          finalize(context, span, response, thrown);
          return response;
        },
      ));
  };
}

function withRequestIdHeader(response: Response, requestId: string): Response {
  try {
    response.headers.set(CODEROUTER_REQUEST_ID_HEADER, requestId);
    return response;
  } catch {
    const headers = new Headers(response.headers);
    headers.set(CODEROUTER_REQUEST_ID_HEADER, requestId);
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  }
}

function finalize(context: CoderouterRequestContext, span: Span, response: Response, thrown: unknown): void {
  const durationMs = Math.round((performance.now() - context.startedAt) * 100) / 100;
  const status = response.status;
  const outcome = thrown !== undefined || context.outcome === undefined
    ? derivedOutcome(context, { status, error: thrown })
    : context.outcome;
  const fault = classifyCoderouterFault(outcome);
  setSpanAttributes(span, {
    "cmux.coderouter.surface": context.surface,
    "cmux.coderouter.request_success": status < 400,
    "cmux.coderouter.request_duration_ms": durationMs,
    "cmux.coderouter.fault": fault,
    "cmux.coderouter.outcome": outcome.outcome,
    "cmux.coderouter.failure_stage": outcome.failureStage,
    "cmux.coderouter.team_id": context.identity?.teamId,
    "cmux.user_id": context.identity?.stackUserId ?? context.userId,
    "cmux.vercel.request_id": context.vercelRequestId,
  });
  addCoderouterBreadcrumb("request", "Route finished", {
    surface: context.surface,
    status,
    outcome: outcome.outcome,
    fault,
    duration_ms: durationMs,
  }, fault === "operator" ? "error" : fault === "none" || fault === "caller" ? "info" : "warning");
  analytics.captureCoderouterRawBatch?.(traceEvents(context, { status, durationMs, error: thrown }));
  if (fault !== "none" && fault !== "caller") {
    // An error-heavy instance can lose its deferred span export; flush now
    // so the Axiom trace behind the request id exists when someone looks.
    scheduleTraceFlush();
  }
}

/** Coalesces outage-time exporter flushes to one callback per runtime turn. */
function scheduleTraceFlush(): void {
  if (traceFlushScheduled) return;
  traceFlushScheduled = true;
  const flush = async () => {
    try {
      await forceFlushTraces();
    } catch {
      // Exporter failure must never become an unhandled rejection or alter the
      // response path. Sentry records the request failure separately.
    } finally {
      traceFlushScheduled = false;
    }
  };
  try {
    after(flush);
  } catch {
    void flush();
  }
}
