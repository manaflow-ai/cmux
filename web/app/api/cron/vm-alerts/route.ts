import { runVmAlertChecks } from "../../../../services/observability/vmAlerts";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const cronSecret = process.env.CRON_SECRET?.trim();
  if (!cronSecret) {
    return jsonResponse({ error: "cron_not_configured" }, 503);
  }

  const expected = `Bearer ${cronSecret}`;
  if (request.headers.get("authorization") !== expected) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const checks = await runVmAlertChecks();
  return jsonResponse({ checks });
}
