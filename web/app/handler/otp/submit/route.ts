import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { signInWithCode } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import {
  completeSignIn,
  failSignIn,
} from "../../../../services/auth/hexclave/completeSignIn";
import { refuseFormPost } from "../../../../services/auth/hexclave/formFailure";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
import {
  formString,
  isSameOriginFormPost,
} from "../../../../services/auth/hexclave/formRequest";
import {
  clearOTPNonceCookie,
  readOTPNonce,
} from "../../../../services/auth/hexclave/otpNonce";
import { safeReturnToPath } from "../../../../services/auth/hexclave/returnTo";
import { secureCookiesForRequest } from "../../../../services/auth/hexclave/session";

const OTP_PATH = "/handler/otp";

/**
 * Redeems a typed sign-in code. The API expects the six emailed characters
 * concatenated with the nonce this browser was issued, so a code read over
 * someone's shoulder is useless in another browser.
 */
export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return refuseFormPost(origin, "not_configured");
  if (!isSameOriginFormPost(request, origin)) {
    return refuseFormPost(origin, "cross_origin");
  }

  const form = await request.formData();
  const email = formString(form, "email");
  const rawReturnTo = formString(form, "after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const secure = secureCookiesForRequest(request);
  const typed = formString(form, "code").toUpperCase();
  const nonce = readOTPNonce(request, secure);
  const fail = (error: string) =>
    failSignIn(origin, OTP_PATH, { error, returnTo, email: email || null });

  if (!nonce) return fail("expiredCode");
  if (!/^[A-Z0-9]{6}$/u.test(typed)) return fail("invalidCode");

  const result = await signInWithCode(config, `${typed}${nonce}`);
  if (!result.ok) return fail(authErrorKeyForCode(result.error.code, "invalidCode"));

  const response = completeSignIn(request, config, result.value, {
    origin,
    returnTo,
  });
  clearOTPNonceCookie(response, secure);
  return response;
}
