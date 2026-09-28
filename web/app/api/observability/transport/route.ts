import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";

import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  emitTransportJournalEvents,
  MAX_TRANSPORT_JOURNAL_BATCH_EVENTS,
  MAX_TRANSPORT_JOURNAL_REQUEST_BYTES,
  parseTransportJournalEvent,
  type TransportJournalEvent,
} from "../../../../services/observability/transportJournal";
import { reportMissingRateLimitRule } from "../../../../services/rateLimitObservability";
import { forceFlushTraces, setSpanAttributes, withApiRouteSpan } from "../../../../services/telemetry";
import { verifyRequest } from "../../../../services/vms/auth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

const ROUTE = "/api/observability/transport";

export type TransportJournalRouteDependencies = {
  readonly verifyRequest: (
    request: Request,
    options: { readonly allowCookie: false },
  ) => Promise<{ readonly id: string } | null>;
  readonly checkRateLimit: typeof checkVercelRateLimit;
  readonly emitEvents: (userId: string, batch: readonly TransportJournalEvent[]) => Promise<void>;
  readonly flushTraces: (timeoutMs?: number) => Promise<boolean>;
};

const defaultDependencies: TransportJournalRouteDependencies = {
  verifyRequest,
  checkRateLimit: checkVercelRateLimit,
  emitEvents: emitTransportJournalEvents,
  flushTraces: forceFlushTraces,
};

export const POST = makeTransportJournalHandler();

export function makeTransportJournalHandler(
  dependencies: TransportJournalRouteDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    return withApiRouteSpan(
      request,
      ROUTE,
      { "cmux.subsystem": "transport-journal" },
      async (span) => {
        const rateLimitResponse = await enforceRateLimit(request, dependencies);
        if (rateLimitResponse) return rateLimitResponse;

        let user: { readonly id: string } | null;
        try {
          user = await dependencies.verifyRequest(request, { allowCookie: false });
        } catch {
          return jsonResponse({ error: "auth_unavailable" }, 503, { "cache-control": "no-store" });
        }
        if (!user) {
          return jsonResponse({ error: "unauthorized" }, 401, { "cache-control": "no-store" });
        }

        const body = await readBoundedJsonObject(request, MAX_TRANSPORT_JOURNAL_REQUEST_BYTES);
        if (!body.ok) {
          return jsonResponse(
            { error: body.error },
            body.error === "request_too_large" ? 413 : 400,
            { "cache-control": "no-store" },
          );
        }
        if (!Array.isArray(body.value.batch)) {
          return jsonResponse({ error: "missing_batch" }, 400, { "cache-control": "no-store" });
        }
        if (body.value.batch.length > MAX_TRANSPORT_JOURNAL_BATCH_EVENTS) {
          return jsonResponse({ error: "batch_too_large" }, 400, { "cache-control": "no-store" });
        }

        const accepted = body.value.batch
          .map(parseTransportJournalEvent)
          .filter((entry): entry is TransportJournalEvent => entry !== null);
        if (accepted.length !== body.value.batch.length) {
          return jsonResponse({ error: "invalid_event" }, 400, { "cache-control": "no-store" });
        }
        if (accepted.length === 0) {
          return jsonResponse({ ok: true, accepted: 0 }, 200, { "cache-control": "no-store" });
        }

        setSpanAttributes(span, {
          "cmux.user_id": user.id,
          "cmux.transport.event_count": accepted.length,
        });
        try {
          await dependencies.emitEvents(user.id, accepted);
        } catch {
          return jsonResponse({ error: "observability_unavailable" }, 503, { "cache-control": "no-store" });
        }
        // Serverless instances can be torn down after the response, and the
        // batch is already accepted once emission succeeds; an ambiguous
        // flush must not turn into a client retry that duplicates spans.
        try {
          await dependencies.flushTraces(1_000);
        } catch {
          // Best effort after emission.
        }
        return jsonResponse({ ok: true, accepted: accepted.length }, 200, { "cache-control": "no-store" });
      },
      { priority: true },
    );
  };
}

async function enforceRateLimit(
  request: Request,
  dependencies: TransportJournalRouteDependencies,
): Promise<Response | null> {
  // Shares the client-observability firewall rule with the mobile-network
  // route so this lane works without a separate Vercel rule rollout.
  const rateLimitId = process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID?.trim();
  if (process.env.VERCEL !== "1") return null;
  if (!rateLimitId) {
    void reportMissingRateLimitRule({ route: ROUTE, reason: "unset" });
    return jsonResponse({ error: "observability_unavailable" }, 503, { "cache-control": "no-store" });
  }
  try {
    const { error, rateLimited } = await dependencies.checkRateLimit(rateLimitId, { request });
    if (rateLimited || error === "blocked") {
      return jsonResponse(
        { error: "rate_limited" },
        429,
        { "cache-control": "no-store", "retry-after": "60" },
      );
    }
    if (error === "not-found") {
      void reportMissingRateLimitRule({ route: ROUTE, reason: "not-found" });
      return jsonResponse({ error: "observability_unavailable" }, 503, { "cache-control": "no-store" });
    }
    if (error) {
      return jsonResponse({ error: "observability_unavailable" }, 503, { "cache-control": "no-store" });
    }
    return null;
  } catch {
    return jsonResponse({ error: "observability_unavailable" }, 503, { "cache-control": "no-store" });
  }
}
