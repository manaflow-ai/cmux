import { receiveAppleNotification } from "../../../../../services/billing/apple/service";
import { AppleVerificationError } from "../../../../../services/billing/apple/verifier";
import { captureBillingError } from "../../../../../services/errors";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";

const ROUTE = "/api/billing/apple/notifications";

/**
 * App Store Server Notifications V2 (Production and Sandbox). Public: the
 * signed payload is the authentication. 200 once the ledger row is durable,
 * even when applying the entitlement failed (the retry cron finishes it);
 * 4xx only for a payload that fails verification; 5xx when the ledger write
 * failed, so Apple retries.
 */
export async function POST(request: Request): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const signedPayload = (body as { signedPayload?: unknown } | null)?.signedPayload;
  try {
    const outcome = await receiveAppleNotification(signedPayload);
    return jsonResponse({ ok: true, outcome });
  } catch (error) {
    if (error instanceof AppleVerificationError && error.reason !== "retryable") {
      return jsonResponse({ error: "invalid_notification", reason: error.reason }, 400);
    }
    captureBillingError(error, { route: ROUTE });
    return jsonResponse({ error: "apple_notification_failed" }, 503, { "retry-after": "60" });
  }
}
