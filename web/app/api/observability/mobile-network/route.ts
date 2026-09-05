import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";

import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  emitMobileNetworkOutcomes,
  MAX_MOBILE_NETWORK_OUTCOME_BATCH_EVENTS,
  MAX_MOBILE_NETWORK_OUTCOME_REQUEST_BYTES,
  parseMobileNetworkOutcome,
  type MobileNetworkOutcome,
} from "../../../../services/observability/mobileNetworkOutcome";
import { reportMissingRateLimitRule } from "../../../../services/rateLimitObservability";
import { forceFlushTraces, setSpanAttributes, withApiRouteSpan } from "../../../../services/telemetry";
import { verifyRequest } from "../../../../services/vms/auth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

const ROUTE = "/api/observability/mobile-network";

export type MobileNetworkOutcomeRouteDependencies = {
  readonly verifyRequest: (
    request: Request,
    options: { readonly allowCookie: false },
  ) => Promise<{ readonly id: string } | null>;
  readonly checkRateLimit: typeof checkVercelRateLimit;
  readonly emitOutcomes: (userId: string, batch: readonly MobileNetworkOutcome[]) => Promise<void>;
  readonly flushTraces: (timeoutMs?: number) => Promise<boolean>;
};

const defaultDependencies: MobileNetworkOutcomeRouteDependencies = {
  verifyRequest,
  checkRateLimit: checkVercelRateLimit,
  emitOutcomes: emitMobileNetworkOutcomes,
  flushTraces: forceFlushTraces,
};

export const POST = makeMobileNetworkOutcomeHandler();

export function makeMobileNetworkOutcomeHandler(
  dependencies: MobileNetworkOutcomeRouteDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    return withApiRouteSpan(
      request,
      ROUTE,
      { "cmux.subsystem": "mobile-network" },
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

        const body = await readBoundedJsonObject(
          request,
          MAX_MOBILE_NETWORK_OUTCOME_REQUEST_BYTES,
        );
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
        if (body.value.batch.length > MAX_MOBILE_NETWORK_OUTCOME_BATCH_EVENTS) {
          return jsonResponse({ error: "batch_too_large" }, 400, { "cache-control": "no-store" });
        }

        const accepted = body.value.batch
          .map(parseMobileNetworkOutcome)
          .filter((outcome): outcome is MobileNetworkOutcome => outcome !== null);
        if (accepted.length !== body.value.batch.length) {
          return jsonResponse({ error: "invalid_outcome" }, 400, { "cache-control": "no-store" });
        }
        if (accepted.length === 0) {
          return jsonResponse({ ok: true, accepted: 0 }, 200, { "cache-control": "no-store" });
        }

        const failureCount = accepted.filter(
          (outcome) => outcome.outcome === "failure" || outcome.outcome === "timeout",
        ).length;
        setSpanAttributes(span, {
          "cmux.user_id": user.id,
          "cmux.mobile.outcome_count": accepted.length,
          "cmux.mobile.failure_count": failureCount,
        });
        try {
          await dependencies.emitOutcomes(user.id, accepted);
        } catch {
          return jsonResponse(
            { error: "observability_unavailable" },
            503,
            { "cache-control": "no-store" },
          );
        }
        // Serverless instances can be torn down after the response. Bound
        // every batch flush so successful latency denominators are not lost.
        // The batch is already accepted once emission succeeds. Do not turn
        // an ambiguous flush result into a retry, which would duplicate spans.
        try {
          await dependencies.flushTraces(1_000);
        } catch {
          // Best effort after emission. A retry here could duplicate spans.
        }
        return jsonResponse(
          { ok: true, accepted: accepted.length },
          200,
          { "cache-control": "no-store" },
        );
      },
      { priority: true },
    );
  };
}

async function enforceRateLimit(
  request: Request,
  dependencies: MobileNetworkOutcomeRouteDependencies,
): Promise<Response | null> {
  const rateLimitId = process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID?.trim();
  if (process.env.VERCEL !== "1") return null;
  if (!rateLimitId) {
    void reportMissingRateLimitRule({ route: ROUTE, reason: "unset" });
    return jsonResponse(
      { error: "observability_unavailable" },
      503,
      { "cache-control": "no-store" },
    );
  }
  try {
    const { error, rateLimited } = await dependencies.checkRateLimit(rateLimitId, { request });
    if (rateLimited || error === "blocked") {
      return jsonResponse({ error: "rate_limited" }, 429, { "cache-control": "no-store" });
    }
    if (error === "not-found") {
      void reportMissingRateLimitRule({ route: ROUTE, reason: "not-found" });
      return jsonResponse(
        { error: "observability_unavailable" },
        503,
        { "cache-control": "no-store" },
      );
    }
    if (error) {
      return jsonResponse(
        { error: "observability_unavailable" },
        503,
        { "cache-control": "no-store" },
      );
    }
  } catch {
    return jsonResponse(
      { error: "observability_unavailable" },
      503,
      { "cache-control": "no-store" },
    );
  }
  return null;
}
