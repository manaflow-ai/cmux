import {
  appleAccountTokenResponse,
  requestedAppleBundleId,
  requestedBillingPeriods,
  requestedStoreKitEnvironment,
} from "../../../../services/billing/apple/accountToken";
import { authenticateAppleBillingRequest } from "../../../../services/billing/apple/routeAuth";
import { requestedPaywallLayouts, servedPaywallConfig } from "../../../../services/billing/paywall/iosPaywall";
import { IOS_PAYWALL_CONTROL } from "../../../../services/billing/paywall/iosPaywallV1";
import { captureBillingError } from "../../../../services/errors";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

const ROUTE = "/api/billing/paywall";

/**
 * `{paywall}` for the signed-in user and the app named by the same headers
 * as `POST /api/billing/apple/account-token`; the same resolution, so both
 * routes always agree on the variant. A failure serves control: the paywall
 * must still render when the experiment is broken.
 */
export async function GET(request: Request): Promise<Response> {
  const auth = await authenticateAppleBillingRequest(request, ROUTE);
  if (!auth.ok) return auth.response;
  try {
    const body = await appleAccountTokenResponse(auth.user, {
      bundleId: requestedAppleBundleId(request.headers.get("x-cmux-bundle-id")),
      storeKitEnvironment: requestedStoreKitEnvironment(request.headers.get("x-cmux-storekit-environment")),
      billingPeriods: requestedBillingPeriods(request.headers.get("x-cmux-billing-periods")),
      bundleIdHeader: request.headers.get("x-cmux-bundle-id"),
      paywallLayouts: requestedPaywallLayouts(request.headers.get("x-cmux-paywall-layouts")),
    });
    return jsonResponse({ paywall: body.paywall ?? servedPaywallConfig(IOS_PAYWALL_CONTROL, {}) }, 200, { "cache-control": "no-store" });
  } catch (error) {
    captureBillingError(error, { route: ROUTE, stackUserId: auth.user.id });
    return jsonResponse({ paywall: servedPaywallConfig(IOS_PAYWALL_CONTROL, {}) }, 200, { "cache-control": "no-store" });
  }
}
