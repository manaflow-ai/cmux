// Scheduled (vercel.json): emails the owners of coderouter accounts that
// became broken or expired since the last run, one email per recipient,
// one notice per account, ever. See services/coderouter/accountHealthEmail.ts.
import { runAccountHealthNotifications } from "../../../../services/coderouter/accountHealthEmail";
import { reportCoderouterFailure } from "../../../../services/coderouter/observability";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export async function GET(request: Request): Promise<Response> {
  const cronSecret = process.env.CRON_SECRET?.trim();
  if (!cronSecret) {
    return jsonResponse({ error: "cron_not_configured" }, 503);
  }
  if (request.headers.get("authorization") !== `Bearer ${cronSecret}`) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  try {
    const result = await runAccountHealthNotifications();
    return jsonResponse(result);
  } catch (error) {
    reportCoderouterFailure("account_health_email", error, { operation: "cron" });
    return jsonResponse({ error: "coderouter_account_health_failed", retryable: true }, 500);
  }
}
