import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { resetPassword } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
import {
  formString,
  isSameOriginFormPost,
} from "../../../../services/auth/hexclave/formRequest";
import { safeReturnToPath } from "../../../../services/auth/hexclave/returnTo";

const RESET_PATH = "/handler/password-reset";
const MINIMUM_PASSWORD_LENGTH = 8;

export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });
  if (!isSameOriginFormPost(request, origin)) {
    return NextResponse.json({ error: "cross_origin" }, { status: 403 });
  }

  const form = await request.formData();
  const code = formString(form, "code");
  const password = formString(form, "password");
  const confirmation = formString(form, "password_confirmation");
  const rawReturnTo = formString(form, "after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;

  const back = (params: Record<string, string>) => {
    const url = new URL(RESET_PATH, origin);
    for (const [key, value] of Object.entries(params)) {
      url.searchParams.set(key, value);
    }
    if (returnTo) url.searchParams.set("after_auth_return_to", returnTo);
    return NextResponse.redirect(url);
  };

  if (!code) return back({ error: "invalidCode" });
  if (password !== confirmation) return back({ code, error: "passwordMismatch" });
  if (password.length < MINIMUM_PASSWORD_LENGTH) {
    return back({ code, error: "weakPassword" });
  }

  const result = await resetPassword(config, { code, password });
  if (!result.ok) {
    return back({ code, error: authErrorKeyForCode(result.error.code, "invalidCode") });
  }
  return back({ done: "1" });
}
