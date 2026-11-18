// GET /api/admin/subscriptions/analytics, built by a factory so tests can
// inject the report loader and the clock. route.ts exports the default wiring.

import type { NextRequest } from "next/server";

import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";
import {
  loadSubscriptionAnalytics,
  parseAnalyticsQuery,
  type SubscriptionAnalyticsLoader,
} from "../../../../../services/billing/analytics/query";
import { appleServerApiStatus } from "../../../../../services/billing/apple/config";
import {
  probeAppleProductionApi,
  type AppleProductionApiHealth,
} from "../../../../../services/billing/apple/productionAccess";
import { captureBillingError } from "../../../../../services/errors";

export type SubscriptionAnalyticsRouteDependencies = {
  readonly load: SubscriptionAnalyticsLoader;
  readonly now?: () => Date;
  /** Configuration source for `billingHealth`; defaults to `process.env`. */
  readonly env?: Record<string, string | undefined>;
  /**
   * Live Production App Store Server API access for
   * `billingHealth.appleServerApiProduction`. Without it a configured key
   * reports `unknown` (tests never reach Apple).
   */
  readonly productionApiAccess?: () => Promise<AppleProductionApiHealth>;
};

/** The probe answer is reused this long, so admin reloads do not hit Apple each time. */
const PRODUCTION_PROBE_TTL_MS = 5 * 60 * 1000;

/** probeAppleProductionApi with a short in-process cache. */
export function cachedProductionApiProbe(
  probe: () => Promise<AppleProductionApiHealth> = () => probeAppleProductionApi(),
  nowMs: () => number = Date.now,
): () => Promise<AppleProductionApiHealth> {
  let cached: { readonly at: number; readonly value: AppleProductionApiHealth } | null = null;
  return async () => {
    if (cached && nowMs() - cached.at < PRODUCTION_PROBE_TTL_MS) return cached.value;
    const value = await probe();
    cached = { at: nowMs(), value };
    return value;
  };
}

export function createSubscriptionAnalyticsHandlers(deps: SubscriptionAnalyticsRouteDependencies) {
  /**
   * Subscription metrics for the admin dashboard. Query: `source`
   * (apple|stripe|all), `plan`, `environment` (production|sandbox|all,
   * default production), `from`/`to` (ISO date or timestamp, default the
   * last 180 days), `granularity` (day|week|month). 401/403 before any read
   * for a caller who is not an admin. `billingHealth.appleServerApi` says
   * whether the App Store Server API key is configured (`configured` or
   * `missing`, with the missing env names), checkable without the cron.
   * `billingHealth.appleServerApiProduction` is the live Production access of
   * the App Store app: `ok`, `locked_until_release` (Production 401 while the
   * Sandbox accepts the key: no App Store release yet), `unauthorized` (both
   * refuse it), `not_configured`, or `unknown` (Apple could not be asked).
   */
  async function GET(request: NextRequest) {
    const gate = await requireAdmin(request);
    if (!gate.ok) return gate.response;
    const now = deps.now?.() ?? new Date();
    const query = parseAnalyticsQuery(request.nextUrl.searchParams, now);
    if (!query) return adminJsonResponse({ error: "invalid_query" }, 400);
    try {
      const report = await deps.load(query, now);
      const status = appleServerApiStatus(deps.env ?? process.env);
      return adminJsonResponse({
        ...report,
        billingHealth: { ...status, appleServerApiProduction: await productionHealth(status.appleServerApi) },
      });
    } catch (error) {
      captureBillingError(error, {
        route: "/api/admin/subscriptions/analytics",
        stackUserId: gate.admin.id,
      });
      return adminJsonResponse({ error: "analytics_unavailable" }, 503);
    }
  }

  async function productionHealth(key: "configured" | "missing"): Promise<AppleProductionApiHealth> {
    if (key === "missing") return "not_configured";
    if (!deps.productionApiAccess) return "unknown";
    try {
      return await deps.productionApiAccess();
    } catch {
      return "unknown";
    }
  }

  return { GET };
}

export const defaultSubscriptionAnalyticsDependencies: SubscriptionAnalyticsRouteDependencies = {
  load: loadSubscriptionAnalytics,
  productionApiAccess: cachedProductionApiProbe(),
};
