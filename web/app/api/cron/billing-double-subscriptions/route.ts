import { authorizeCronRequest } from "../../../../services/cronAuth";
import { scanDoubleBilling } from "../../../../services/billing/doubleBilling";
import { captureBillingError } from "../../../../services/errors";

export const maxDuration = 60;

/**
 * Daily: finds accounts paying for a personal plan through both Stripe and
 * the App Store, opens an incident (logged, alerted, sent to analytics) for
 * each new pair, and resolves incidents that no longer bill twice.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  try {
    const result = await scanDoubleBilling();
    const ok = result.failedUsers === 0;
    return Response.json({ ok, ...result }, { status: ok ? 200 : 503 });
  } catch (error) {
    captureBillingError(error, { route: "/api/cron/billing-double-subscriptions" });
    return Response.json(
      { error: "double_billing_scan_failed", retryable: true },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
}
