import {
  appleAccountTokenResponse,
  requestedAppleBundleId,
  requestedStoreKitEnvironment,
} from "../../../../../services/billing/apple/accountToken";
import { authenticateAppleBillingRequest } from "../../../../../services/billing/apple/routeAuth";
import { captureBillingError } from "../../../../../services/errors";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";

const ROUTE = "/api/billing/apple/account-token";

/**
 * The caller's `appAccountToken` (minted once), whether the App Store may
 * sell them a personal plan, their current plan, and the products to show
 * for the app named by `x-cmux-bundle-id`. `x-cmux-storekit-environment`
 * (`Sandbox` or `Production`) lets a build whose purchases would grant
 * nothing get `purchases_unavailable` instead of products.
 */
export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateAppleBillingRequest(request, ROUTE);
  if (!auth.ok) return auth.response;
  try {
    const body = await appleAccountTokenResponse(auth.user, {
      bundleId: requestedAppleBundleId(request.headers.get("x-cmux-bundle-id")),
      storeKitEnvironment: requestedStoreKitEnvironment(request.headers.get("x-cmux-storekit-environment")),
    });
    return jsonResponse(body, 200, { "cache-control": "no-store" });
  } catch (error) {
    captureBillingError(error, { route: ROUTE, stackUserId: auth.user.id });
    return jsonResponse({ error: "apple_account_token_failed" }, 503, { "cache-control": "no-store" });
  }
}
