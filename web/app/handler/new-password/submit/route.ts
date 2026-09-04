import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { resetPassword } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
import { refuseFormPost } from "../../../../services/auth/hexclave/formFailure";
import {
  formString,
  isSameOriginFormPost,
} from "../../../../services/auth/hexclave/formRequest";
import {
  clearResetCodeCookie,
  readResetCodeCookie,
} from "../../../../services/auth/hexclave/resetCode";
import { safeReturnToPath } from "../../../../services/auth/hexclave/returnTo";
import { secureCookiesForRequest } from "../../../../services/auth/hexclave/session";

const FORM_PATH = "/handler/new-password";
const MINIMUM_PASSWORD_LENGTH = 8;

export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return refuseFormPost(origin, "not_configured");
  if (!isSameOriginFormPost(request, origin)) {
    return refuseFormPost(origin, "cross_origin");
  }

  const form = await request.formData();
  const password = formString(form, "password");
  const confirmation = formString(form, "password_confirmation");
  const rawReturnTo = formString(form, "after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const secure = secureCookiesForRequest(request);
  const code = readResetCodeCookie(request.cookies);

  const back = (params: Record<string, string>) => {
    const url = new URL(FORM_PATH, origin);
    for (const [key, value] of Object.entries(params)) {
      url.searchParams.set(key, value);
    }
    if (returnTo) url.searchParams.set("after_auth_return_to", returnTo);
    return NextResponse.redirect(url);
  };

  // No cookie means the link expired or was opened in another browser. The
  // page renders that as a dead link rather than asking for a password it
  // could not use.
  if (!code) return back({});
  if (password !== confirmation) return back({ error: "passwordMismatch" });
  if (password.length < MINIMUM_PASSWORD_LENGTH) {
    return back({ error: "weakPassword" });
  }

  const result = await resetPassword(config, { code, password });
  if (!result.ok) {
    return back({ error: authErrorKeyForCode(result.error.code, "invalidCode") });
  }

  const response = back({ done: "1" });
  clearResetCodeCookie(response, secure);
  return response;
}
