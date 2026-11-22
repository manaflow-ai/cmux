// GET /api/admin/subscriptions/double-billing, built by a factory so tests can
// inject the incident store. route.ts exports the default wiring.

import type { NextRequest } from "next/server";

import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";
import { databaseDoubleBillingStore, type DoubleBillingStore } from "../../../../../services/billing/doubleBilling";
import { captureBillingError } from "../../../../../services/errors";

export type DoubleBillingRouteDependencies = {
  readonly store: Pick<DoubleBillingStore, "listIncidents">;
};

const MAX_LIMIT = 500;

export function createDoubleBillingHandlers(deps: DoubleBillingRouteDependencies) {
  /**
   * Accounts paying for a personal plan through both Stripe and the App
   * Store, newest detection first. Query: `status` (`open`, default, or
   * `all`), `limit` (1-500, default 100). 401/403 before any read for a
   * caller who is not an admin.
   */
  async function GET(request: NextRequest) {
    const gate = await requireAdmin(request);
    if (!gate.ok) return gate.response;
    const status = request.nextUrl.searchParams.get("status") ?? "open";
    const rawLimit = request.nextUrl.searchParams.get("limit");
    const limit = rawLimit === null ? 100 : Number(rawLimit);
    if ((status !== "open" && status !== "all") || !Number.isInteger(limit) || limit < 1 || limit > MAX_LIMIT) {
      return adminJsonResponse({ error: "invalid_query" }, 400);
    }
    try {
      const incidents = await deps.store.listIncidents({ includeResolved: status === "all", limit });
      return adminJsonResponse({
        status,
        incidents: incidents.map((incident) => ({
          ...incident,
          firstDetectedAt: incident.firstDetectedAt.toISOString(),
          detectedAt: incident.detectedAt.toISOString(),
          resolvedAt: incident.resolvedAt?.toISOString() ?? null,
        })),
      });
    } catch (error) {
      captureBillingError(error, {
        route: "/api/admin/subscriptions/double-billing",
        stackUserId: gate.admin.id,
      });
      return adminJsonResponse({ error: "double_billing_unavailable" }, 503);
    }
  }

  return { GET };
}

export const defaultDoubleBillingRouteDependencies: DoubleBillingRouteDependencies = {
  get store() {
    return databaseDoubleBillingStore();
  },
};
