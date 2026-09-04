import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { signInWithCode } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import {
  completeSignIn,
  failSignIn,
} from "../../../../services/auth/hexclave/completeSignIn";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
import {
  formString,
  isSameOriginFormPost,
} from "../../../../services/auth/hexclave/formRequest";
import { clearOTPNonceCookie } from "../../../../services/auth/hexclave/otpNonce";
import { safeReturnToPath } from "../../../../services/auth/hexclave/returnTo";
import { secureCookiesForRequest } from "../../../../services/auth/hexclave/session";

const CALLBACK_PATH = "/handler/magic-link-callback";

/**
 * Redeems the full code an emailed sign-in link carries.
 *
 * Reached only from the confirmation page on this origin, so no cross-site
 * navigation and no mail scanner can spend the code or plant a session.
 */
export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });
  if (!isSameOriginFormPost(request, origin)) {
    return NextResponse.json({ error: "cross_origin" }, { status: 403 });
  }

  const form = await request.formData();
  const rawReturnTo = formString(form, "after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const code = formString(form, "code");
  if (!code) {
    return failSignIn(origin, "/handler/sign-in", {
      error: "invalidCode",
      returnTo,
    });
  }

  const result = await signInWithCode(config, code);
  if (!result.ok) {
    // Back to the confirmation page rather than sign-in: the visitor came from
    // their inbox and the message should name what went wrong with the link.
    const url = new URL(CALLBACK_PATH, origin);
    url.searchParams.set("code", code);
    if (returnTo) url.searchParams.set("after_auth_return_to", returnTo);
    url.searchParams.set(
      "error",
      authErrorKeyForCode(result.error.code, "invalidCode"),
    );
    return NextResponse.redirect(url);
  }

  const response = completeSignIn(request, config, result.value, {
    origin,
    returnTo,
  });
  clearOTPNonceCookie(response, secureCookiesForRequest(request));
  return response;
}
