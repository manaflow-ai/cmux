import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { isCoderouterHost } from "../../components/auth-host";
import {
  sendSignInCode,
  signInWithPassword,
} from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import { refuseFormPost } from "../../../../services/auth/hexclave/formFailure";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
import {
  completeSignIn,
  failSignIn,
} from "../../../../services/auth/hexclave/completeSignIn";
import {
  formString,
  isSameOriginFormPost,
  looksLikeEmail,
} from "../../../../services/auth/hexclave/formRequest";
import { setOTPNonceCookie } from "../../../../services/auth/hexclave/otpNonce";
import { authPageHref, safeReturnToPath } from "../../../../services/auth/hexclave/returnTo";
import { secureCookiesForRequest } from "../../../../services/auth/hexclave/session";

const SIGN_IN_PATH = "/handler/sign-in";

/**
 * Password sign-in and one-time-code requests share this endpoint because they
 * share a form: the visitor types an address first and only then decides which
 * proof to give. Both branches answer with a redirect, so a refresh after a
 * failure never re-submits credentials.
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
  const password = formString(form, "password");
  const method = formString(form, "method") === "password" &&
      !isCoderouterHost(request.headers.get("host"))
    ? "password"
    : "code";
  const rawReturnTo = formString(form, "after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const fail = (error: string) =>
    failSignIn(origin, SIGN_IN_PATH, {
      error,
      returnTo,
      email: email || null,
      method: method === "password" ? "password" : null,
    });

  if (!looksLikeEmail(email)) return fail("invalidEmail");

  if (method === "password") {
    if (!password) return fail("missingFields");
    const result = await signInWithPassword(config, { email, password });
    if (!result.ok) return fail(authErrorKeyForCode(result.error.code));
    return completeSignIn(request, config, result.value, { origin, returnTo });
  }

  const callbackURL = new URL("/handler/magic-link-callback", origin);
  if (returnTo) callbackURL.searchParams.set("after_auth_return_to", returnTo);
  const sent = await sendSignInCode(config, {
    email,
    callbackURL: callbackURL.toString(),
  });
  if (!sent.ok) return fail(authErrorKeyForCode(sent.error.code));

  const response = NextResponse.redirect(
    new URL(authPageHref("/handler/otp", { returnTo, email }), origin),
  );
  setOTPNonceCookie(response, sent.value.nonce, secureCookiesForRequest(request));
  return response;
}
