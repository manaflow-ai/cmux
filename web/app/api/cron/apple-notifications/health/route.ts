import { authorizeBearerSecret } from "../../../../../services/cronAuth";
import {
  findAppleTestNotification,
  isAppleNotificationUuid,
} from "../../../../../services/billing/apple/notificationHealth";
import { captureBillingError } from "../../../../../services/errors";

export const dynamic = "force-dynamic";

const NO_STORE = { "cache-control": "no-store" };

/**
 * Whether an App Store TEST notification reached the ledger, for the Billing
 * nightly (.github/workflows/billing-nightly.yml): it asks Apple for a TEST
 * notification, waits until Apple reports it delivered, then reads this.
 *
 * `GET ?uuid=<notificationUUID>` with `Authorization: Bearer
 * <APPLE_NOTIFICATIONS_HEALTH_TOKEN>`. Its own token, not CRON_SECRET, so the
 * CI job that holds it can read this and run no cron. Unset, it answers 503.
 * Only TEST rows answer, with booleans, timestamps and the environment;
 * never a payload, transaction or error text.
 */
export async function GET(request: Request): Promise<Response> {
  const auth = authorizeBearerSecret(request, process.env.APPLE_NOTIFICATIONS_HEALTH_TOKEN);
  if (!auth.ok) {
    return auth.reason === "secret_missing"
      ? Response.json({ error: "health_token_missing" }, { status: 503, headers: NO_STORE })
      : Response.json({ error: "unauthorized" }, { status: 401, headers: NO_STORE });
  }
  const uuid = new URL(request.url).searchParams.get("uuid");
  if (!isAppleNotificationUuid(uuid)) {
    return Response.json({ error: "invalid_uuid" }, { status: 400, headers: NO_STORE });
  }
  try {
    const receipt = await findAppleTestNotification(uuid);
    return Response.json({
      found: receipt !== null,
      environment: receipt?.environment ?? null,
      receivedAt: receipt?.receivedAt.toISOString() ?? null,
      processed: receipt?.processedAt != null,
      processedAt: receipt?.processedAt?.toISOString() ?? null,
    }, { headers: NO_STORE });
  } catch (error) {
    captureBillingError(error, { route: "/api/cron/apple-notifications/health" });
    return Response.json(
      { error: "lookup_failed", retryable: true },
      { status: 503, headers: { ...NO_STORE, "retry-after": "60" } },
    );
  }
}
