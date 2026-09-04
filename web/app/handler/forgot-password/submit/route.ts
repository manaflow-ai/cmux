import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { sendPasswordResetCode } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import { failSignIn } from "../../../../services/auth/hexclave/completeSignIn";
import { refuseFormPost } from "../../../../services/auth/hexclave/formFailure";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
import {
  formString,
  isSameOriginFormPost,
  looksLikeEmail,
} from "../../../../services/auth/hexclave/formRequest";
import { safeReturnToPath } from "../../../../services/auth/hexclave/returnTo";

const FORGOT_PATH = "/handler/forgot-password";

/**
 * Requests a reset link. An unknown address answers exactly like a known one,
 * so this endpoint cannot be used to test whether someone has a cmux account.
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

  if (!looksLikeEmail(email)) {
    return failSignIn(origin, FORGOT_PATH, {
      error: "invalidEmail",
      returnTo,
      email: email || null,
    });
  }

  const callbackURL = new URL("/handler/password-reset", origin);
  if (returnTo) callbackURL.searchParams.set("after_auth_return_to", returnTo);
  const result = await sendPasswordResetCode(config, {
    email,
    callbackURL: callbackURL.toString(),
  });

  if (!result.ok && authErrorKeyForCode(result.error.code) !== "userNotFound") {
    return failSignIn(origin, FORGOT_PATH, {
      error: authErrorKeyForCode(result.error.code),
      returnTo,
      email,
    });
  }

  const confirmation = new URL(FORGOT_PATH, origin);
  confirmation.searchParams.set("sent", "1");
  if (returnTo) confirmation.searchParams.set("after_auth_return_to", returnTo);
  return NextResponse.redirect(confirmation);
}
