// Per-request verbose diagnostics for server-flagged accounts (App Review).
//
// When `verifyRequest` resolves a user whose Stack `clientReadOnlyMetadata`
// carries `cmuxVerboseDiagnostics: true` (services/account/verboseDiagnostics.ts),
// this module emits one structured `[cmux-verbose-diag]` console line per
// authenticated request into the Vercel runtime logs, annotates the active
// OTel span so sampled Axiom traces are filterable, and, for routes wrapped
// in `withApiRouteSpan`, emits a completion line carrying the response
// status and duration. Routes without the span wrapper still get the request
// line plus a fallback end line scheduled through `next/server`'s `after`.
//
// Ordinary users never reach any of this: the only caller is the
// `verifyRequest` success path, gated on the resolved user's flag, so the
// per-request cost for unflagged accounts is one boolean check.

import { after } from "next/server";
import { trace } from "@opentelemetry/api";

/**
 * Stable marker prefixing every verbose-diagnostics log line, so one filter
 * (`"[cmux-verbose-diag]"` in the Vercel log search, or
 * `message contains "[cmux-verbose-diag]"` in a drained sink) returns the
 * whole reviewer session.
 */
export const VERBOSE_DIAGNOSTICS_LOG_MARKER = "[cmux-verbose-diag]";

/** Span attribute stamped on flagged requests for Axiom trace filtering. */
export const VERBOSE_DIAGNOSTICS_SPAN_ATTRIBUTE = "cmux.verbose_diagnostics";

export type VerboseDiagnosticsAuthedUser = {
  readonly id: string;
  readonly verboseDiagnostics?: boolean;
};

type RequestLogEntry = {
  readonly userId: string;
  readonly startedAt: number;
  finished: boolean;
};

// Keyed by the exact Request instance, which flows unchanged from the route
// handler into `verifyRequest` and `withApiRouteSpan`, so the completion hook
// can attribute status and duration without any global request id plumbing.
const trackedRequests = new WeakMap<Request, RequestLogEntry>();

/**
 * Emits one `[cmux-verbose-diag]` line. All values are produced server-side
 * (never raw client input), so no scrubbing pass is applied here; callers must
 * not forward request bodies or credential material.
 */
export function emitVerboseDiagnosticsLog(
  kind: string,
  fields: Record<string, string | number | boolean | null | undefined>,
): void {
  const payload: Record<string, string | number | boolean> = { kind };
  for (const [key, value] of Object.entries(fields)) {
    if (value !== null && value !== undefined) payload[key] = value;
  }
  payload.at = new Date().toISOString();
  console.log(`${VERBOSE_DIAGNOSTICS_LOG_MARKER} ${JSON.stringify(payload)}`);
}

/**
 * Records an authenticated request from a verbose-diagnostics-flagged user.
 *
 * Called from every `verifyRequest` success return (fresh native, cached
 * native, and cookie paths). No-ops unless the resolved user's server-set
 * flag is the literal `true`, so this is the single gate deciding whether a
 * request produces verbose logs. Emits the `request` line immediately (the
 * handler may still throw), annotates the active span, and schedules a
 * fallback `request_end` line for routes that never reach
 * `completeVerboseDiagnosticsRequest`.
 */
export function recordVerboseDiagnosticsRequest(
  request: Request,
  user: VerboseDiagnosticsAuthedUser,
): void {
  if (user.verboseDiagnostics !== true) return;
  if (trackedRequests.has(request)) return;
  const entry: RequestLogEntry = {
    userId: user.id,
    startedAt: Date.now(),
    finished: false,
  };
  trackedRequests.set(request, entry);

  const url = safeUrl(request.url);
  emitVerboseDiagnosticsLog("request", {
    method: request.method,
    path: url?.pathname,
    // Parameter names only: query values on some routes carry identifiers
    // that must not be copied into a log sink verbatim.
    queryKeys: url ? [...url.searchParams.keys()].sort().join(",") || undefined : undefined,
    userId: user.id,
    userAgent: request.headers.get("user-agent") ?? undefined,
  });

  const activeSpan = trace.getActiveSpan();
  if (activeSpan) {
    activeSpan.setAttribute(VERBOSE_DIAGNOSTICS_SPAN_ATTRIBUTE, true);
    activeSpan.setAttribute("cmux.verbose_diagnostics_user", user.id);
  }

  // Fallback closure for routes not wrapped in `withApiRouteSpan`: emit an
  // end line (duration only; the response status is not observable here) once
  // the response has finished. `after` throws outside a request scope
  // (tests); the request line above already covers that case.
  try {
    after(() => {
      if (entry.finished) return;
      entry.finished = true;
      emitVerboseDiagnosticsLog("request_end", {
        method: request.method,
        path: url?.pathname,
        userId: entry.userId,
        durationMs: Date.now() - entry.startedAt,
      });
    });
  } catch {
    // Outside a request scope there is nothing to schedule.
  }
}

/**
 * Completion hook, called by `withApiRouteSpan` for every wrapped route.
 * Emits the rich `response` line (route, method, status, duration, user id,
 * error details) only when the request was recorded as a
 * verbose-diagnostics request; for everyone else this is one WeakMap miss.
 */
export function completeVerboseDiagnosticsRequest(
  request: Request,
  outcome: {
    readonly route: string;
    readonly status?: number;
    readonly errorName?: string;
    readonly errorMessage?: string;
  },
): void {
  const entry = trackedRequests.get(request);
  if (!entry || entry.finished) return;
  entry.finished = true;
  emitVerboseDiagnosticsLog("response", {
    method: request.method,
    route: outcome.route,
    path: safeUrl(request.url)?.pathname,
    status: outcome.status,
    userId: entry.userId,
    durationMs: Date.now() - entry.startedAt,
    errorName: outcome.errorName,
    errorMessage: outcome.errorMessage,
  });
}

function safeUrl(raw: string): URL | null {
  try {
    return new URL(raw);
  } catch {
    return null;
  }
}
