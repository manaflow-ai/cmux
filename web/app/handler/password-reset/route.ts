import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../lib/request-origin";
import { verifyPasswordResetCode } from "../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import { authErrorKeyForCode } from "../../../services/auth/hexclave/errorCodes";
import { refuseFormPost } from "../../../services/auth/hexclave/formFailure";
import {
  isResetCodeShaped,
  setResetCodeCookie,
} from "../../../services/auth/hexclave/resetCode";
import { safeReturnToPath } from "../../../services/auth/hexclave/returnTo";
import { secureCookiesForRequest } from "../../../services/auth/hexclave/session";

const FORM_PATH = "/handler/new-password";

/**
 * The address the reset email links to. It exists to take the credential back
 * out of the URL.
 *
 * The code is checked here, moved into an httpOnly cookie, and the visitor is
 * sent to a form whose address holds nothing secret. Every later step, retry,
 * and error message then runs on that clean URL, so the code never reaches
 * history, a `Referer`, or a pasted link.
 */
export async function GET(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return refuseFormPost(origin, "not_configured");

  const params = request.nextUrl.searchParams;
  const rawReturnTo = params.get("after_auth_return_to");
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const code = params.get("code") ?? "";

  const form = new URL(FORM_PATH, origin);
  if (returnTo) form.searchParams.set("after_auth_return_to", returnTo);

  if (!isResetCodeShaped(code)) {
    form.searchParams.set("error", "invalidCode");
    return NextResponse.redirect(form);
  }

  const checked = await verifyPasswordResetCode(config, code);
  if (!checked.ok) {
    form.searchParams.set(
      "error",
      authErrorKeyForCode(checked.error.code, "invalidCode"),
    );
    return NextResponse.redirect(form);
  }

  const response = NextResponse.redirect(form);
  setResetCodeCookie(response, code, secureCookiesForRequest(request));
  return response;
}
