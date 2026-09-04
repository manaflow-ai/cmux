import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { signUpWithPassword } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import {
  completeSignIn,
  failSignIn,
} from "../../../../services/auth/hexclave/completeSignIn";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
import {
  formString,
  isSameOriginFormPost,
  looksLikeEmail,
} from "../../../../services/auth/hexclave/formRequest";
import { safeReturnToPath } from "../../../../services/auth/hexclave/returnTo";

const SIGN_UP_PATH = "/handler/sign-up";
const MINIMUM_PASSWORD_LENGTH = 8;

export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });
  if (!isSameOriginFormPost(request, origin)) {
    return NextResponse.json({ error: "cross_origin" }, { status: 403 });
  }

  const form = await request.formData();
  const email = formString(form, "email");
  const password = formString(form, "password");
  const rawReturnTo = formString(form, "after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const fail = (error: string) =>
    failSignIn(origin, SIGN_UP_PATH, { error, returnTo, email: email || null });

  if (!looksLikeEmail(email)) return fail("invalidEmail");
  // Checked here as well as upstream so an obviously short password costs no
  // round trip; the API stays the authority on the full policy.
  if (password.length < MINIMUM_PASSWORD_LENGTH) return fail("weakPassword");

  const result = await signUpWithPassword(config, {
    email,
    password,
    verificationCallbackURL: new URL(
      "/handler/email-verification",
      origin,
    ).toString(),
  });
  if (!result.ok) return fail(authErrorKeyForCode(result.error.code));
  return completeSignIn(request, config, result.value, { origin, returnTo });
}
