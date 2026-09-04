import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../lib/request-origin";
import { signInWithPasskey } from "../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import {
  completeSignIn,
  failSignIn,
} from "../../../services/auth/hexclave/completeSignIn";
import { authErrorKeyForCode } from "../../../services/auth/hexclave/errorCodes";
import {
  formString,
  isSameOriginFormPost,
} from "../../../services/auth/hexclave/formRequest";
import { safeReturnToPath } from "../../../services/auth/hexclave/returnTo";

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
  const fail = (error: string) =>
    failSignIn(origin, "/handler/sign-in", { error, returnTo });

  let authenticationResponse: unknown;
  try {
    authenticationResponse = JSON.parse(formString(form, "authentication_response"));
  } catch {
    return fail("passkeyFailed");
  }
  if (!code) return fail("passkeyFailed");

  const result = await signInWithPasskey(config, {
    authenticationResponse,
    code,
  });
  if (!result.ok) return fail(authErrorKeyForCode(result.error.code));
  return completeSignIn(request, config, result.value, { origin, returnTo });
}
