// GET /api/admin/subscriptions/analytics, built by a factory so tests can
// inject the report loader and the clock. route.ts exports the default wiring.

import type { NextRequest } from "next/server";

import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";
import {
  loadSubscriptionAnalytics,
  parseAnalyticsQuery,
  type SubscriptionAnalyticsLoader,
} from "../../../../../services/billing/analytics/query";
import { captureBillingError } from "../../../../../services/errors";

export type SubscriptionAnalyticsRouteDependencies = {
  readonly load: SubscriptionAnalyticsLoader;
  readonly now?: () => Date;
};

export function createSubscriptionAnalyticsHandlers(deps: SubscriptionAnalyticsRouteDependencies) {
  /**
   * Subscription metrics for the admin dashboard. Query: `source`
   * (apple|stripe|all), `plan`, `environment` (production|sandbox|all,
   * default production), `from`/`to` (ISO date or timestamp, default the
   * last 180 days), `granularity` (day|week|month). 401/403 before any read
   * for a caller who is not an admin.
   */
  async function GET(request: NextRequest) {
    const gate = await requireAdmin(request);
    if (!gate.ok) return gate.response;
    const now = deps.now?.() ?? new Date();
    const query = parseAnalyticsQuery(request.nextUrl.searchParams, now);
    if (!query) return adminJsonResponse({ error: "invalid_query" }, 400);
    try {
      return adminJsonResponse(await deps.load(query, now));
    } catch (error) {
      captureBillingError(error, {
        route: "/api/admin/subscriptions/analytics",
        stackUserId: gate.admin.id,
      });
      return adminJsonResponse({ error: "analytics_unavailable" }, 503);
    }
  }

  return { GET };
}

export const defaultSubscriptionAnalyticsDependencies: SubscriptionAnalyticsRouteDependencies = {
  load: loadSubscriptionAnalytics,
};
