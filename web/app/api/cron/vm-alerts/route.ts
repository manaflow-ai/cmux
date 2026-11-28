import { makeStripeWebhookReplayer } from "../../../../services/billing/stripeWebhook";
import { authorizeCronRequest } from "../../../../services/cronAuth";
import { runBillingAlertChecks } from "../../../../services/observability/billingAlerts";
import { runCronAlertChecks } from "../../../../services/observability/cronAlerts";
import { runVmAlertChecks } from "../../../../services/observability/vmAlerts";
import { captureBillingError } from "../../../../services/errors";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

const replayFailedStripeWebhookEvents = makeStripeWebhookReplayer();


export async function GET(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") {
    return jsonResponse({ error: "cron_not_configured" }, 503);
  }
  if (!auth.ok) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const checks = await runVmAlertChecks();
  // Replay before the billing check so a cleared contention never pages.
  const stripeWebhookReplay = await replayFailedStripeWebhookEvents().catch((error: unknown) => {
    captureBillingError(error, { operation: "stripe_webhook_replay" });
    return null;
  });
  const billing = await runBillingAlertChecks();
  const cron = await runCronAlertChecks();
  // Top-level `configured` makes a sink-less production deployment visible to
  // anything scraping the cron response, not only readers of the summary.
  return jsonResponse({ configured: checks.alertSink.configured, checks, stripeWebhookReplay, billing, cron });
}
