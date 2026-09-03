import { runCoderouterAlertChecks } from "../../../../services/observability/coderouterAlerts";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  const cronSecret = process.env.CRON_SECRET?.trim();
  if (!cronSecret) {
    return jsonResponse({ error: "cron_not_configured" }, 503);
  }
  if (request.headers.get("authorization") !== `Bearer ${cronSecret}`) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  const summary = await runCoderouterAlertChecks();
  // `configured` at the top level makes a sink-less production deployment
  // visible to anything scraping the cron response.
  return jsonResponse({ configured: summary.alertSink.configured, summary });
}
