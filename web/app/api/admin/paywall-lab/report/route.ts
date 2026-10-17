import type { NextRequest } from "next/server";

import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";
import { databasePaywallExperimentLog } from "../../../../../services/billing/paywall/store";
import { latestPaywallReport } from "../../../../../services/billing/pricingExperiment/lab";
import { captureBillingError } from "../../../../../services/errors";

/**
 * GET /api/admin/paywall-lab/report?experiment=<key>: the optimizer's newest
 * daily report as Markdown, linked from the Paywall Lab. Staff only.
 */
export async function GET(request: NextRequest): Promise<Response> {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const experiment = request.nextUrl.searchParams.get("experiment")?.trim() ?? "";
  try {
    const report = await latestPaywallReport(experiment, databasePaywallExperimentLog());
    if (!report) return adminJsonResponse({ error: "no_report" }, 404);
    return new Response(report.markdown, {
      headers: {
        "content-type": "text/markdown; charset=utf-8",
        "cache-control": "no-store",
        "content-disposition": `inline; filename="${experiment}-${report.ranAt.toISOString().slice(0, 10)}.md"`,
      },
    });
  } catch (error) {
    captureBillingError(error, { route: "/api/admin/paywall-lab/report", experiment });
    return adminJsonResponse({ error: "paywall_lab_unavailable" }, 503);
  }
}
