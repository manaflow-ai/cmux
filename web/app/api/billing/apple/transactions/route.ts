import {
  AppleTransactionRejectedError,
  recordClientAppleTransaction,
} from "../../../../../services/billing/apple/service";
import { authenticateAppleBillingRequest } from "../../../../../services/billing/apple/routeAuth";
import { AppleVerificationError } from "../../../../../services/billing/apple/verifier";
import { captureBillingError } from "../../../../../services/errors";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";

const ROUTE = "/api/billing/apple/transactions";
const NO_STORE = { "cache-control": "no-store" } as const;

/**
 * Records a StoreKit 2 transaction (`jwsRepresentation`) for the signed-in
 * user and applies its plan. Idempotent: posting the same transaction again
 * returns the current state.
 */
export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateAppleBillingRequest(request, ROUTE);
  if (!auth.ok) return auth.response;
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400, NO_STORE);
  }
  const signedTransactionInfo = (body as { signedTransactionInfo?: unknown } | null)?.signedTransactionInfo;
  try {
    const result = await recordClientAppleTransaction({ userId: auth.user.id, signedTransactionInfo });
    return jsonResponse(result, 200, NO_STORE);
  } catch (error) {
    return transactionErrorResponse(error, auth.user.id);
  }
}

function transactionErrorResponse(error: unknown, stackUserId: string): Response {
  if (error instanceof AppleTransactionRejectedError) {
    return jsonResponse({ error: error.reason }, error.reason === "account_mismatch" ? 403 : 400, NO_STORE);
  }
  if (error instanceof AppleVerificationError) {
    if (error.reason === "retryable") {
      return jsonResponse({ error: "verification_unavailable" }, 503, { ...NO_STORE, "retry-after": "30" });
    }
    return jsonResponse({ error: "invalid_transaction", reason: error.reason }, 400, NO_STORE);
  }
  captureBillingError(error, { route: ROUTE, stackUserId });
  return jsonResponse({ error: "apple_transaction_failed" }, 503, NO_STORE);
}
