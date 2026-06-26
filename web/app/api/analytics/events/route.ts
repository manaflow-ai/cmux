// Server-to-server proxy for iOS product analytics. The native app posts a batch
// of validated, `ios_`-prefixed events here; the route applies an anonymous
// Vercel Firewall rate limit, opportunistically reads the Stack user, enforces
// an event-name allowlist + size bounds, stamps the authenticated user id as the
// distinct id, and forwards the batch to PostHog with the project key held
// server-side. This decouples the app from the PostHog wire format and SDK
// version and lets us resample/drop server-side without an app update.
//
// Auth + bounded-body shape mirrors the proven `web/app/api/device-tokens/route.ts`
// (plain async/await), deliberately not the Effect pattern used elsewhere under
// `web/app/api/**`, to stay structurally identical to that directly-analogous route.

import { checkRateLimit } from "@vercel/firewall";

import { env } from "../../../env";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { verifyRequest } from "../../../../services/vms/auth";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  MAX_ANALYTICS_BATCH_EVENTS,
  MAX_ANALYTICS_EVENT_PROPERTIES,
  MAX_ANALYTICS_REQUEST_BYTES,
  POSTHOG_HOST,
  POSTHOG_PROJECT_KEY,
  isAllowedAnalyticsEvent,
} from "../../../../services/analytics/iosEventPolicy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type IncomingEvent = {
  readonly event: string;
  readonly distinctID?: string;
  readonly properties: Record<string, unknown>;
  readonly timestamp?: string;
};

export async function POST(request: Request): Promise<Response> {
  const rateLimitResponse = await anonymousRateLimitResponse(request);
  if (rateLimitResponse) return rateLimitResponse;

  // Auth is read opportunistically, NOT required: the two-phase identity design
  // depends on pre-auth events (install, sign-in attempts, pairing) flowing while
  // the user is still anonymous. When a Stack session is present we stamp the
  // authoritative `user.id` over the client distinct id; when absent we trust the
  // client-supplied anonymous `client_id`. The event-name allowlist is the abuse
  // gate, not auth. The PostHog key is already public (the web client posts to
  // r.cmux.com directly), so an anonymous proxy is no weaker than today.
  //
  // The Vercel Firewall limit above gates repeated anonymous requests before the
  // route spends auth/body-parse/PostHog work. The shape gate (allowlist + 64 KB
  // body cap + per-batch/per-event bounds below) still limits payload abuse inside
  // a single allowed request.
  const user = await verifyRequest(request, { allowCookie: false });

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

  const forwarded = await forwardToPostHog(accepted, user?.id ?? null);
  if (!forwarded.ok) {
    return jsonResponse({ error: "forward_failed" }, forwarded.status);
  }
  return jsonResponse({ ok: true, forwarded: accepted.length });
}

async function anonymousRateLimitResponse(request: Request): Promise<Response | null> {
  if (process.env.VERCEL !== "1") return null;

  const rateLimitId = env.CMUX_ANALYTICS_RATE_LIMIT_ID;
  if (!rateLimitId) {
    console.error("analytics.events.rate_limit_not_configured");
    return jsonResponse({ error: "rate_limit_unavailable" }, 503);
  }

  try {
    const result = await checkRateLimit(rateLimitId, { request });
    const rateLimitError = result.error as string | undefined;
    if (result.rateLimited || rateLimitError === "blocked") {
      return jsonResponse({ error: "rate_limited" }, 429);
    }
    if (rateLimitError === "not-found") {
      console.error("analytics.events.rate_limit_not_found", rateLimitId);
      return jsonResponse({ error: "rate_limit_unavailable" }, 503);
    }
    if (rateLimitError) {
      console.error("analytics.events.rate_limit_error_unknown", rateLimitError);
      return jsonResponse({ error: "rate_limit_unavailable" }, 503);
    }
  } catch (error) {
    console.error("analytics.events.rate_limit_error", error);
    return jsonResponse({ error: "rate_limit_unavailable" }, 503);
  }

  return null;
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
