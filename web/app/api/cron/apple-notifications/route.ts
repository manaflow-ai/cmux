import { authorizeCronRequest } from "../../../../services/cronAuth";
import { retryAppleNotifications } from "../../../../services/billing/apple/service";
import { defaultTrialLifecycleDependencies, settlePendingTrials } from "../../../../services/billing/apple/trial";
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
    // Trials whose device check failed stay pending (no grant) until this retry settles them.
    const trials = await settlePendingTrials(defaultTrialLifecycleDependencies());
    const ok = result.notifications.failed === 0 && result.lapsedFailures === 0;
    return Response.json({ ok, ...result, trials }, { status: ok ? 200 : 503 });
  } catch (error) {
    captureBillingError(error, { route: "/api/cron/apple-notifications" });
    return Response.json(
      { error: "apple_notifications_retry_failed", retryable: true },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
}
