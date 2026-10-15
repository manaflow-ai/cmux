import {
  appleAccountTokenResponse,
  requestedBillingPeriods,
  requestedStoreKitEnvironment,
} from "../../../../../../services/billing/apple/accountToken";
import { authenticateAppleBillingRequest } from "../../../../../../services/billing/apple/routeAuth";
import {
  defaultDeviceCheck,
  introductoryOfferSigner,
  parseTrialVerifyRequest,
  verifyTrialEligibility,
} from "../../../../../../services/billing/apple/trial";
import { TRIAL_BUNDLE_ID } from "../../../../../../services/billing/apple/trialConfig";
import { databaseTrialStore } from "../../../../../../services/billing/apple/trialStore";
import { readBoundedJsonObject } from "../../../../../../services/apns/routePolicy";
import { captureBillingError } from "../../../../../../services/errors";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";

const ROUTE = "/api/billing/apple/trial/verify";
const MAX_BODY_BYTES = 32 * 1024;

/**
 * Device proof for the 7-day Pro trial: App Attest (attestation the first
 * time for a key, an assertion after), then the device's DeviceCheck trial
 * bit. `{eligible, introductoryOfferJWS, reason, legacyTrialAllowed}`; 409
 * `attest_key_unknown` asks the app to attest a new key once.
 */
export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateAppleBillingRequest(request, ROUTE);
  if (!auth.ok) return auth.response;
  const body = await readBoundedJsonObject(request, MAX_BODY_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  const parsed = parseTrialVerifyRequest(body.value);
  if (!parsed) return jsonResponse({ error: "invalid_request" }, 400, { "cache-control": "no-store" });
  const user = auth.user;
  try {
    const outcome = await verifyTrialEligibility(user.id, parsed, {
      store: databaseTrialStore(),
      env: process.env,
      now: () => new Date(),
      // The same decision as the account-token `trial` field.
      accountOffered: async () => {
        const account = await appleAccountTokenResponse(user, {
          bundleId: TRIAL_BUNDLE_ID,
          storeKitEnvironment: requestedStoreKitEnvironment(request.headers.get("x-cmux-storekit-environment")),
          billingPeriods: requestedBillingPeriods(request.headers.get("x-cmux-billing-periods")),
          bundleIdHeader: request.headers.get("x-cmux-bundle-id"),
        });
        return account.trial?.offered === true;
      },
      deviceCheck: defaultDeviceCheck(process.env),
      signIntroductoryOffer: introductoryOfferSigner(process.env),
    });
    return jsonResponse(outcome.body, outcome.status, { "cache-control": "no-store" });
  } catch (error) {
    captureBillingError(error, { route: ROUTE, stackUserId: user.id });
    return jsonResponse({ error: "trial_verify_failed" }, 503, { "cache-control": "no-store" });
  }
}
