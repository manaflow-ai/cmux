import { createHash, timingSafeEqual } from "node:crypto";

import {
  coderouterAlertSinkReady,
  runCoderouterAlertChecks,
  type CoderouterAlertSummary,
} from "../../../../services/observability/coderouterAlerts";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const maxDuration = 60;

export type CoderouterAlertCronRunner = () => Promise<CoderouterAlertSummary>;

export async function handleCoderouterAlertsCron(
  request: Request,
  run: CoderouterAlertCronRunner = runCoderouterAlertChecks,
): Promise<Response> {
  const cronSecret = process.env.CRON_SECRET?.trim();
  if (!cronSecret) {
    return jsonResponse({ error: "cron_not_configured" }, 503);
  }
  // Hash both values before comparing so the comparison always has the same
  // length and does not leak a matching prefix through timing.
  const provided = createHash("sha256")
    .update(request.headers.get("authorization") ?? "")
    .digest();
  const expected = createHash("sha256")
    .update(`Bearer ${cronSecret}`)
    .digest();
  if (!timingSafeEqual(provided, expected)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  if (!coderouterAlertSinkReady()) {
    // A successful cron response would make a triggered alert look delivered
    // while it was dropped. Fail closed until an operator records the waiver.
    return jsonResponse({ configured: false, error: "alert_sink_not_configured" }, 503);
  }
  const summary = await run();
  // `configured` at the top level makes a sink-less production deployment
  // visible to anything scraping the cron response.
  const deliveryFailed = summary.alertSink.deliveryFailures > 0;
  return jsonResponse({
    configured: summary.alertSink.configured,
    ...(deliveryFailed ? { error: "alert_delivery_failed" } : {}),
    summary,
  }, deliveryFailed ? 503 : 200);
}

export const GET = (request: Request): Promise<Response> => handleCoderouterAlertsCron(request);
