import { authorizeCronRequest } from "../../../../services/cronAuth";
import { runVmAlertChecks } from "../../../../services/observability/vmAlerts";
import { jsonResponse } from "../../../../services/vms/routeHelpers";


export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") {
    return jsonResponse({ error: "cron_not_configured" }, 503);
  }
  if (!auth.ok) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const checks = await runVmAlertChecks();
  // Top-level `configured` makes a sink-less production deployment visible to
  // anything scraping the cron response, not only readers of the summary.
  return jsonResponse({ configured: checks.alertSink.configured, checks });
}
