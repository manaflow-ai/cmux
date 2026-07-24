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
import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";
import { createHash } from "node:crypto";
import { verifyRequest } from "../../../../services/vms/auth";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import { cloudDb } from "../../../../db/client";
import {
  hasBlockingAccountDeletionIdentity,
  withAccountDeletionAnalyticsForwardLease,
} from "../../../../services/account/deletionLock";
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

const POSTHOG_CAPTURE_TIMEOUT_MS = 10_000;

type AnalyticsEventsDependencies = {
  readonly verifyRequest: (
    request: Request,
    options: { readonly allowCookie: false },
  ) => Promise<{ readonly id: string } | null>;
  readonly db: typeof cloudDb;
  readonly postHogFetch: typeof fetch;
  readonly checkRateLimit: typeof checkVercelRateLimit;
};

const defaultDependencies: AnalyticsEventsDependencies = {
  verifyRequest,
  db: cloudDb,
  postHogFetch: fetch,
  checkRateLimit: checkVercelRateLimit,
};

type IncomingEvent = {
  readonly event: string;
  readonly distinctID?: string;
  readonly properties: Record<string, unknown>;
  readonly timestamp?: string;
};

export const POST = makeAnalyticsEventsHandler();

export function makeAnalyticsEventsHandler(dependencies: AnalyticsEventsDependencies = defaultDependencies) {
  return async function POST(request: Request): Promise<Response> {
    if (process.env.VERCEL === "1") {
      const rateLimitId = process.env.CMUX_ANALYTICS_RATE_LIMIT_ID?.trim();
      if (!rateLimitId) {
        console.error("analytics.events.rate_limit_not_configured");
        return jsonResponse({ error: "analytics_unavailable" }, 503);
      }
      const { error, rateLimited } = await dependencies.checkRateLimit(rateLimitId, { request });
      if (rateLimited || error === "blocked") {
        return jsonResponse({ error: "rate_limited" }, 429);
      }
      if (error) {
        console.error("analytics.events.rate_limit_error", error);
        return jsonResponse({ error: "analytics_unavailable" }, 503);
      }
    }

    // Auth is read opportunistically, NOT required: the two-phase identity design
    // depends on pre-auth events (install, sign-in attempts, pairing) flowing while
    // the user is still anonymous. When a Stack session is present we stamp the
    // authoritative `user.id` over the client distinct id; when absent we trust the
    // client-supplied anonymous `client_id`. The event-name allowlist is the abuse
    // gate, not auth. The PostHog key is already public (the web client posts to
    // r.cmux.com directly), so an anonymous proxy is no weaker than today.
    //
    const user = await dependencies.verifyRequest(request, {
      allowCookie: false,
    });

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

    // A queued identified batch can arrive after Stack authentication has been
    // deleted. In that case the old account id becomes client-supplied input, so
    // check both the authenticated identity and every accepted client distinct id
    // against durable deletion tombstones before PostHog can recreate the person.
    const clientIdentityCandidates = [
      ...accepted.flatMap((event) => (event.distinctID ? [event.distinctID] : [])),
      ...accepted.flatMap((event) => {
        const anonymousAlias = event.properties.$anon_distinct_id;
        return typeof anonymousAlias === "string" ? [anonymousAlias] : [];
      }),
    ];
    if (await hasBlockingAccountDeletionIdentity(dependencies.db(), clientIdentityCandidates)) {
      return jsonResponse({ error: "account_deleted" }, 410);
    }

    // Client-supplied identities are useful for rejecting stale queued events,
    // but only the server-authenticated identity may delay account deletion.
    // Otherwise an anonymous caller could reserve a victim's deletion lease.
    const forwardResult = await withAccountDeletionAnalyticsForwardLease(
      dependencies.db(),
      user ? [user.id] : [],
      () => forwardToPostHog(accepted, user?.id ?? null, dependencies.postHogFetch),
      (result) => result.ok || result.delivery === "definitive",
    );
    if (forwardResult.kind === "blocked") {
      return jsonResponse({ error: "account_deleted" }, 410);
    }

    const forwarded = forwardResult.value;
    if (!forwarded.ok) {
      return jsonResponse({ error: "forward_failed" }, forwarded.status);
    }
    return jsonResponse({ ok: true, forwarded: accepted.length });
  };
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
  return typeof value === "string" || typeof value === "number" || typeof value === "boolean";
}

async function forwardToPostHog(
  events: readonly IncomingEvent[],
  userId: string | null,
  postHogFetch: typeof fetch,
): Promise<
  | { readonly ok: true }
  | { readonly ok: false; readonly status: number; readonly delivery: "definitive" | "ambiguous" }
> {
  // When authenticated, the server stamps the authoritative user id as the
  // distinct id so a client cannot attribute events to another user. When
  // anonymous, the install `client_id` is hashed into a server namespace so it
  // cannot collide with an account id. The same transform is applied to an
  // `$anon_distinct_id` alias so authenticated identify calls join that funnel.
  const batch = events.map((event) => {
    // An unauthenticated queued event may contain stale account fields from a
    // session that was deleted after the tombstone preflight. Preserve only its
    // event name and namespaced anonymous id so it cannot recreate account data.
    const properties = userId ? { ...event.properties } : {};
    const anonymousAlias = properties.$anon_distinct_id;
    if (typeof anonymousAlias === "string") {
      properties.$anon_distinct_id = anonymousPostHogDistinctID(anonymousAlias);
    }
    return {
      event: event.event,
      distinct_id: userId ?? anonymousPostHogDistinctID(event.distinctID ?? "anonymous"),
      properties,
      timestamp: event.timestamp,
    };
  });

  try {
    const response = await postHogFetch(`${POSTHOG_HOST}/batch/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: POSTHOG_PROJECT_KEY, batch }),
      signal: AbortSignal.timeout(POSTHOG_CAPTURE_TIMEOUT_MS),
    });
    if (!response.ok) {
      // PostHog 4xx is a permanent client problem; 5xx is transient. Surface the
      // class so the app's uploader can decide drop vs. retry.
      return { ok: false, status: response.status >= 500 ? 502 : 400, delivery: "definitive" };
    }
    return { ok: true };
  } catch {
    return { ok: false, status: 502, delivery: "ambiguous" };
  }
}

function anonymousPostHogDistinctID(clientID: string): string {
  return `ios-anon-sha256:${createHash("sha256").update(clientID).digest("hex")}`;
}
