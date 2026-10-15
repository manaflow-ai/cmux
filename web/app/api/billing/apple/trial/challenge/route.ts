import { authenticateAppleBillingRequest } from "../../../../../../services/billing/apple/routeAuth";
import { issueTrialChallenge } from "../../../../../../services/billing/apple/trial";
import { databaseTrialStore } from "../../../../../../services/billing/apple/trialStore";
import { captureBillingError } from "../../../../../../services/errors";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";

const ROUTE = "/api/billing/apple/trial/challenge";

/** A single-use App Attest challenge for the trial check, valid for 5 minutes. */
export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateAppleBillingRequest(request, ROUTE);
  if (!auth.ok) return auth.response;
  try {
    const challenge = await issueTrialChallenge(auth.user.id, { store: databaseTrialStore(), now: () => new Date() });
    return jsonResponse({ challenge }, 200, { "cache-control": "no-store" });
  } catch (error) {
    captureBillingError(error, { route: ROUTE, stackUserId: auth.user.id });
    return jsonResponse({ error: "trial_challenge_failed" }, 503, { "cache-control": "no-store" });
  }
}
