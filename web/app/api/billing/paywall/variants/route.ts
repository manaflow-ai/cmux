import type { NextRequest } from "next/server";

import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";
import { IOS_PAYWALL_EXPERIMENT } from "../../../../../services/billing/paywall/iosPaywallV1";
import { databasePaywallExperimentLog } from "../../../../../services/billing/paywall/store";
import { staffVariantsView } from "../../../../../services/billing/paywall/variantsView";
import { captureBillingError } from "../../../../../services/errors";

/**
 * GET /api/billing/paywall/variants[?experiment=<key>] (staff only): every
 * live and retired variant of one experiment (default `ios-paywall-v1`) with
 * its copy, layout, traffic share, exposures and conversions from the latest
 * optimizer run, and the change log. The iOS Paywall Lab and the staff page
 * read it.
 */
export async function GET(request: NextRequest): Promise<Response> {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const experiment = request.nextUrl.searchParams.get("experiment")?.trim() || IOS_PAYWALL_EXPERIMENT;
  try {
    const view = await staffVariantsView(experiment, databasePaywallExperimentLog());
    if (!view) return adminJsonResponse({ error: "unknown_experiment" }, 404);
    return adminJsonResponse(view);
  } catch (error) {
    captureBillingError(error, { route: "/api/billing/paywall/variants", experiment });
    return adminJsonResponse({ error: "paywall_variants_unavailable" }, 503);
  }
}
