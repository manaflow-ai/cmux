import { AsyncLocalStorage } from "node:async_hooks";
import { SpanStatusCode, type Span } from "@opentelemetry/api";
import { after } from "next/server";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import { runWithCloudDbQueryTags } from "../../db/queryTags";
import { forceFlushTraces, withPrioritySpan, withSpan, withTraceIdHeaders } from "../telemetry";

// Leave room before the provider's 1500ms deadline. These are diagnostic
// thresholds, not permission caches or retries.
const SLOW_REQUEST_MS = 750;
const MAX_OPERATION_RECORDS = 32;
const ROUTE = "/api/freestyle/forward-auth";
type Operation = { operation: string; offset_ms: number; duration_ms: number; failed: boolean };
type RequestState = { now: () => number; startedAt: number; operations: Operation[]; dropped: number };
const requests = new AsyncLocalStorage<RequestState>();
class EffectRequestState extends Context.Tag("cmux/PublicationAuthTrace")<EffectRequestState, RequestState>() {}
const rounded = (value: number) => Math.round(value * 100) / 100;

function recordOperation(state: RequestState, operation: Operation): void {
  if (state.operations.length < MAX_OPERATION_RECORDS) state.operations.push(operation);
  else state.dropped++;
}

function decision(status: number): string {
  if (status >= 500) return "unavailable";
  return ({ 204: "allow", 302: "redirect", 400: "invalid", 401: "unauthorized", 404: "not_found", 429: "rate_limited" } as Record<number, string>)[status] ?? "other";
}

/** Capture at the HTTP boundary; fibers retain their own request state. */
export function withPublicationAuthEffectContext<A, E, R>(program: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> {
  const state = requests.getStore();
  return state ? program.pipe(Effect.provideService(EffectRequestState, state)) : program;
}

export function tracePublicationAuthEffect<A, E, R>(operation: string, program: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> {
  return Effect.gen(function* () {
    const context = yield* Effect.serviceOption(EffectRequestState);
    if (context._tag === "None") return yield* program;
    const state = context.value;
    const startedAt = state.now();
    return yield* program.pipe(Effect.onExit(exit => Effect.sync(() => recordOperation(state, {
      operation,
      offset_ms: rounded(startedAt - state.startedAt),
      duration_ms: rounded(state.now() - startedAt),
      failed: Exit.isFailure(exit),
    }))));
  });
}

/** Operation names come from fixed call sites, never URLs, SQL, or user input. */
export async function tracePublicationAuthOperation<A>(operation: string, run: () => Promise<A>): Promise<A> {
  const state = requests.getStore();
  if (!state) return run();
  const startedAt = state.now();
  // Box failures inside withSpan: generic exception recording can expose SQL
  // parameters or credentials embedded in provider messages. This path records
  // only the failing operation; the original error still reaches its handler.
  const result = await withSpan("cmux-publication-auth", `cmux.publication_auth.${operation}`, {}, async span => {
    let failed = false;
    try {
      return { ok: true as const, value: await run() };
    } catch (error) {
      failed = true;
      span.setStatus({ code: SpanStatusCode.ERROR, message: "authorization operation failed" });
      return { ok: false as const, error };
    } finally {
      const record = { operation, offset_ms: rounded(startedAt - state.startedAt), duration_ms: rounded(state.now() - startedAt), failed };
      span.setAttributes(record);
      recordOperation(state, record);
    }
  });
  if (!result.ok) throw result.error;
  return result.value;
}

/** Sample ordinary traffic; retain an outcome with all measured stages for every slow/5xx request. */
export async function withPublicationAuthRequest(
  request: Request,
  run: () => Promise<Response>,
  options: { readonly now?: () => number } = {},
): Promise<Response> {
  const now = options.now ?? (() => performance.now());
  const state: RequestState = { now, startedAt: now(), operations: [], dropped: 0 };
  return withSpan("cmux-publication-auth", "cmux.publication_auth.request", {
    "http.route": ROUTE,
    "cmux.subsystem": "publication-auth",
  }, async span => {
    const response = await requests.run(state, () => runWithCloudDbQueryTags({ source: "app", route: ROUTE }, async () => {
      try {
        return await run();
      } catch {
        recordOperation(state, { operation: "handler", offset_ms: 0, duration_ms: rounded(now() - state.startedAt), failed: true });
        return new Response(null, { status: 503, headers: { "cache-control": "no-store" } });
      }
    }));
    const durationMs = rounded(now() - state.startedAt);
    const slow = durationMs >= SLOW_REQUEST_MS;
    const failed = response.status >= 500;
    const attributes = {
      "http.route": ROUTE,
      "http.response.status_code": response.status,
      "cmux.subsystem": "publication-auth",
      "cmux.publication_auth.duration_ms": durationMs,
      "cmux.publication_auth.slow": slow,
      "cmux.publication_auth.failed": failed,
      "cmux.publication_auth.decision": decision(response.status),
      "cmux.publication_auth.callback": /^\/_cmux\/auth\/callback(?:\?|$)/u.test(request.headers.get("x-forwarded-uri") ?? ""),
      "cmux.publication_auth.dropped_operations": state.dropped,
    };
    const annotate = (target: Span) => {
      target.setAttributes(attributes);
      for (const operation of state.operations) target.addEvent("authorization.operation", operation);
      const totals = new Map<string, number>();
      for (const operation of state.operations) totals.set(operation.operation, (totals.get(operation.operation) ?? 0) + operation.duration_ms);
      for (const [operation, duration] of totals) target.setAttribute(`cmux.publication_auth.stage_ms.${operation}`, rounded(duration));
      if (failed) target.setStatus({ code: SpanStatusCode.ERROR, message: "authorization unavailable" });
    };
    annotate(span);
    let result = withTraceIdHeaders(response, span);
    if (slow || failed) {
      // A root rejected by head sampling cannot be promoted. The priority
      // outcome retains stage offsets/durations and links back to that root.
      result = await withPrioritySpan("cmux-publication-auth", "cmux.publication_auth.outcome", attributes, async retained => {
        annotate(retained);
        return withTraceIdHeaders(response, retained);
      });
    }
    if (slow || failed || span.isRecording()) {
      try { after(() => forceFlushTraces()); } catch { /* Standalone test/script, no request lifecycle. */ }
    }
    return result;
  });
}
