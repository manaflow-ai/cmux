import type { NextRequest } from "next/server";

import { adminJsonResponse, requireAdmin } from "../../../../services/admin/routeAuth";
import { databasePaywallExperimentLog } from "../../../../services/billing/paywall/store";
import { paywallLabView, setExperimentPaused } from "../../../../services/billing/pricingExperiment/lab";
import { captureBillingError } from "../../../../services/errors";
import { browserMutationOriginAllowed } from "../../../../services/vms/routeHelpers";

/**
 * GET /api/admin/paywall-lab: every paywall and pricing experiment with its
 * live and retired variants, traffic, exposures, conversions, P(best), SRM
 * status, flag state and change log. Staff only (401 signed out, 403 for
 * everyone else). Reads stored optimizer runs; computes no statistics.
 */
export async function GET(request: NextRequest): Promise<Response> {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  try {
    return adminJsonResponse(await paywallLabView({ log: databasePaywallExperimentLog() }));
  } catch (error) {
    captureBillingError(error, { route: "/api/admin/paywall-lab" });
    return adminJsonResponse({ error: "paywall_lab_unavailable" }, 503);
  }
}

/**
 * POST /api/admin/paywall-lab `{ experiment, paused }`: the kill switch.
 * Pausing sends every visitor of that experiment to control; resuming
 * restores the flag's split. Staff only, same-origin JSON only.
 */
export async function POST(request: NextRequest): Promise<Response> {
  if (!browserMutationOriginAllowed(request)) return adminJsonResponse({ error: "forbidden" }, 403);
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  let body: { experiment?: unknown; paused?: unknown };
  try {
    body = await request.json() as typeof body;
  } catch {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  if (typeof body.experiment !== "string" || typeof body.paused !== "boolean") {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  try {
    const result = await setExperimentPaused({
      experiment: body.experiment,
      paused: body.paused,
      actorEmail: gate.admin.primaryEmail,
      log: databasePaywallExperimentLog(),
    });
    if (result.ok) return adminJsonResponse(result);
    const status = result.error === "unknown_experiment" || result.error === "not_found" ? 404 : 503;
    return adminJsonResponse({ error: result.error }, status);
  } catch (error) {
    captureBillingError(error, { route: "/api/admin/paywall-lab", experiment: body.experiment });
    return adminJsonResponse({ error: "paywall_lab_unavailable" }, 503);
  }
}
