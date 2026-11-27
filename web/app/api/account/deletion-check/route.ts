import { accountDeletionCheckForUser } from "../../../../services/billing/apple/accountDeletion";
import { authenticateAppleBillingRequest } from "../../../../services/billing/apple/routeAuth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

/**
 * `GET /api/account/deletion-check` (auth: native bearer + refresh token
 * headers, or the session cookie). What the account deletion screens warn
 * about before `DELETE /api/account`:
 *
 * `{ appStoreSubscriptionRenews, manageSubscriptionsUrl }`. Deleting the
 * account does not cancel an App Store subscription (Guideline 5.1.1(v)), so
 * when one is set to renew the app and dashboard say so and link to Apple's
 * subscription management. The check never blocks deletion.
 */
export async function GET(request: Request): Promise<Response> {
  const auth = await authenticateAppleBillingRequest(request, "account.deletion_check");
  if (!auth.ok) return auth.response;
  try {
    return jsonResponse(await accountDeletionCheckForUser(auth.user.id), 200, { "cache-control": "no-store" });
  } catch (error) {
    console.error("account.deletion_check.failed", {
      errorType: error instanceof Error ? error.name : typeof error,
    });
    return jsonResponse({ error: "deletion_check_unavailable" }, 503, { "cache-control": "no-store" });
  }
}
