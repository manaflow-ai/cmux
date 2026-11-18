import { authorizeCronRequest } from "../../../../services/cronAuth";
import { runAppleIapCron } from "../../../../services/billing/apple/cron";
import { captureBillingError } from "../../../../services/errors";

// Budgets in the service bound the work (150 status lookups, 5 history pages
// per history, and the backfill stops requesting pages after 200 s).
export const maxDuration = 300;

/**
 * Backfills App Store notifications from Apple's history, re-applies those
 * whose entitlement step failed or never ran, re-checks renewals with Apple
 * before access ends, and re-derives the plan of users whose Apple
 * subscription expired without a notification.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  try {
    const result = await runAppleIapCron();
    reportProblems(result);
    return Response.json(result, { status: result.ok ? 200 : 503 });
  } catch (error) {
    captureBillingError(error, { route: "/api/cron/apple-notifications" });
    return Response.json(
      { error: "apple_notifications_retry_failed", retryable: true },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
}

function reportProblems(result: Awaited<ReturnType<typeof runAppleIapCron>>): void {
  const route = "/api/cron/apple-notifications";
  if (result.serverApi.missingInProduction) {
    captureBillingError(new Error("App Store Server API key is not configured in production"), {
      route,
      missingEnv: result.serverApi.missingEnv.join(","),
    });
  }
  if (result.deadLettered > 0) {
    captureBillingError(new Error("Apple notifications were dead-lettered after their last retry"), {
      route,
      deadLettered: result.deadLettered,
    });
  }
  if (result.history.failures > 0) {
    captureBillingError(new Error("Apple notification history backfill failed"), {
      route,
      failures: result.history.failures,
    });
  }
}
