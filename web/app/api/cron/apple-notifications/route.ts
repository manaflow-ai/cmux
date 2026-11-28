import { authorizeCronRequest } from "../../../../services/cronAuth";
import { retryAppleNotifications } from "../../../../services/billing/apple/service";
import { captureBillingError } from "../../../../services/errors";

export const maxDuration = 60;

/**
 * Re-applies App Store notifications whose entitlement step failed or never
 * ran, and re-derives the plan of users whose Apple subscription expired
 * without a notification.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  try {
    const result = await retryAppleNotifications();
    const ok = result.notifications.failed === 0 && result.lapsedFailures === 0;
    return Response.json({ ok, ...result }, { status: ok ? 200 : 503 });
  } catch (error) {
    captureBillingError(error, { route: "/api/cron/apple-notifications" });
    return Response.json(
      { error: "apple_notifications_retry_failed", retryable: true },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
}
