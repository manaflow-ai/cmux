import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../lib/request-origin";
import { signInWithCode } from "../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import {
  completeSignIn,
  failSignIn,
} from "../../../services/auth/hexclave/completeSignIn";
import { authErrorKeyForCode } from "../../../services/auth/hexclave/errorCodes";
import {
  clearOTPNonceCookie,
} from "../../../services/auth/hexclave/otpNonce";
import { safeReturnToPath } from "../../../services/auth/hexclave/returnTo";
import { secureCookiesForRequest } from "../../../services/auth/hexclave/session";

/**
 * Redeems the full code carried by an emailed sign-in link.
 *
 * The link works in any browser by design, which is why it carries the whole
 * code and the typed form carries only its visible half.
 */
export async function GET(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });

  const params = request.nextUrl.searchParams;
  const rawReturnTo = params.get("after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const code = params.get("code");
  if (!code) {
    return failSignIn(origin, "/handler/sign-in", {
      error: "invalidCode",
      returnTo,
    });
  }

  const result = await signInWithCode(config, code);
  if (!result.ok) {
    return failSignIn(origin, "/handler/sign-in", {
      error: authErrorKeyForCode(result.error.code, "invalidCode"),
      returnTo,
    });
  }

  const response = completeSignIn(request, config, result.value, {
    origin,
    returnTo,
  });
  clearOTPNonceCookie(response, secureCookiesForRequest(request));
  return response;
}
