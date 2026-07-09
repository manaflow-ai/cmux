// Server-to-server proxy for iOS product analytics. The native app posts a batch
// of validated, `ios_`-prefixed events here; the route authenticates the Stack
// user, enforces an event-name allowlist + size bounds, stamps the authenticated
// user id as the distinct id, and forwards the batch to PostHog with the project
// key held server-side. This decouples the app from the PostHog wire format and
// SDK version and lets us resample/drop server-side without an app update.
//
// Auth + bounded-body shape mirrors the proven `web/app/api/device-tokens/route.ts`
// (plain async/await), deliberately not the Effect pattern used elsewhere under
// `web/app/api/**`, to stay structurally identical to that directly-analogous route.

import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { verifyRequest as verifyVmRequest } from "../../../../services/vms/auth";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  MAX_ANALYTICS_BATCH_EVENTS,
  MAX_ANALYTICS_EVENT_PROPERTIES,
  MAX_ANALYTICS_REQUEST_BYTES,
  POSTHOG_HOST,
  POSTHOG_PROJECT_KEY,
  isAllowedAnalyticsEvent,
} from "../../../../services/analytics/iosEventPolicy";
import { recordIOSAnalyticsIdentities } from "../../../../services/analytics/iosAnalyticsIdentities";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type IncomingEvent = {
  readonly event: string;
  readonly distinctID?: string;
  readonly properties: Record<string, unknown>;
  readonly timestamp?: string;
};

type AnalyticsRouteDependencies = {
  readonly verifyRequest: typeof verifyVmRequest;
  readonly recordIOSAnalyticsIdentities: typeof recordIOSAnalyticsIdentities;
  readonly forwardToPostHog: typeof forwardToPostHog;
};

const defaultAnalyticsRouteDependencies: AnalyticsRouteDependencies = {
  verifyRequest: verifyVmRequest,
  recordIOSAnalyticsIdentities,
  forwardToPostHog,
};

export async function POST(request: Request): Promise<Response> {
  return postAnalyticsEvents(request);
}

export async function postAnalyticsEvents(
  request: Request,
  dependencies: AnalyticsRouteDependencies = defaultAnalyticsRouteDependencies,
): Promise<Response> {
  // Auth is read opportunistically, NOT required: the two-phase identity design
  // depends on pre-auth events (install, sign-in attempts, pairing) flowing while
  // the user is still anonymous. When a Stack session is present we stamp the
  // authoritative `user.id` over the client distinct id; when absent we trust the
  // client-supplied anonymous `client_id`. The event-name allowlist is the abuse
  // gate, not auth. The PostHog key is already public (the web client posts to
  // r.cmux.com directly), so an anonymous proxy is no weaker than today.
  //
  // Rate limiting is deferred for Phase A (tracked in
  // https://github.com/manaflow-ai/cmux/issues/5569). The only reusable limiter in
  // the codebase (`services/apns/rateLimit.ts`) is a per-`userId` Postgres-
  // transaction gate, which does not fit an anonymous-first, high-volume telemetry
  // ingest path (no user id pre-auth, and a DB write + advisory lock per analytics
  // batch would defeat a lightweight proxy; in-memory limiting does not work on
  // Vercel's per-instance stateless functions). The shape gate (allowlist + 64 KB
  // body cap + per-batch/per-event bounds below) limits payload abuse; a dedicated
  // anonymous IP/edge rate limit on cmux's own compute is the follow-up. The
  // downstream PostHog quota risk is no worse than the already-public direct
  // r.cmux.com path.
  const hasNativeAuth = request.headers.get("authorization")?.toLowerCase().startsWith("bearer ") === true;
  const user = await dependencies.verifyRequest(request, { allowCookie: false });
  if (!user && hasNativeAuth) {
    return jsonResponse({ ok: true, forwarded: 0 });
  }

  const body = await readBoundedJsonObject(request, MAX_ANALYTICS_REQUEST_BYTES);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }

  const rawBatch = body.value.batch;
  if (!Array.isArray(rawBatch)) {
    return jsonResponse({ error: "missing_batch" }, 400);
  }
  if (rawBatch.length === 0) {
    return jsonResponse({ ok: true, forwarded: 0 });
  }
  if (rawBatch.length > MAX_ANALYTICS_BATCH_EVENTS) {
    return jsonResponse({ error: "batch_too_large" }, 400);
  }

  const accepted: IncomingEvent[] = [];
  for (const candidate of rawBatch) {
    const sanitized = sanitizeEvent(candidate);
    if (sanitized) accepted.push(sanitized);
  }
  if (accepted.length === 0) {
    // Every event was rejected by the allowlist/shape check. Treat as a client
    // bug (4xx): retrying the same payload will not help.
    return jsonResponse({ error: "no_valid_events" }, 400);
  }

  if (user) {
    await dependencies.recordIOSAnalyticsIdentities({
      userId: user.id,
      anonymousIds: anonymousIdsFromEvents(accepted),
    });
  }

  const forwarded = await dependencies.forwardToPostHog(accepted, user?.id ?? null);
  if (!forwarded.ok) {
    return jsonResponse({ error: "forward_failed" }, forwarded.status);
  }
  return jsonResponse({ ok: true, forwarded: accepted.length });
}

function sanitizeEvent(candidate: unknown): IncomingEvent | null {
  if (candidate === null || typeof candidate !== "object" || Array.isArray(candidate)) {
    return null;
  }
  const record = candidate as Record<string, unknown>;
  if (!isAllowedAnalyticsEvent(record.event)) return null;

  const distinctID = typeof record.distinct_id === "string" ? record.distinct_id : undefined;

  const rawProperties =
    record.properties && typeof record.properties === "object" && !Array.isArray(record.properties)
      ? (record.properties as Record<string, unknown>)
      : {};

  // Cap property fan-out so a malformed client can't push an unbounded property
  // bag through the proxy.
  const properties: Record<string, unknown> = {};
  let count = 0;
  for (const [key, value] of Object.entries(rawProperties)) {
    if (count >= MAX_ANALYTICS_EVENT_PROPERTIES) break;
    if (isScalar(value)) {
      properties[key] = value;
      count += 1;
    }
  }

  return {
    event: record.event,
    distinctID,
    properties,
    timestamp: typeof record.timestamp === "string" ? record.timestamp : undefined,
  };
}

function anonymousIdsFromEvents(events: readonly IncomingEvent[]): string[] {
  const ids: string[] = [];
  for (const event of events) {
    const clientId = event.properties.client_id;
    const anonymousId = event.properties.$anon_distinct_id;
    if (typeof clientId === "string") ids.push(clientId);
    if (typeof anonymousId === "string") ids.push(anonymousId);
  }
  return ids;
}

function isScalar(value: unknown): boolean {
  return (
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  );
}

async function forwardToPostHog(
  events: readonly IncomingEvent[],
  userId: string | null,
): Promise<{ readonly ok: true } | { readonly ok: false; readonly status: number }> {
  // When authenticated, the server stamps the authoritative user id as the
  // distinct id so a client cannot attribute events to another user. When
  // anonymous, the client-supplied distinct id (the install `client_id`) is
  // trusted so the pre-auth funnel attaches to the same anonymous person. The
  // client's `$anon_distinct_id` (if present) is preserved for aliasing.
  const batch = events.map((event) => ({
    event: event.event,
    distinct_id: userId ?? event.distinctID ?? "anonymous",
    properties: event.properties,
    timestamp: event.timestamp,
  }));

  try {
    const response = await fetch(`${POSTHOG_HOST}/batch/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: POSTHOG_PROJECT_KEY, batch }),
    });
    if (!response.ok) {
      // PostHog 4xx is a permanent client problem; 5xx is transient. Surface the
      // class so the app's uploader can decide drop vs. retry.
      return { ok: false, status: response.status >= 500 ? 502 : 400 };
    }
    return { ok: true };
  } catch {
    return { ok: false, status: 502 };
  }
}
