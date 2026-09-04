import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import {
  isHexclaveOAuthProvider,
  oauthAuthorizeURL,
} from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import { failSignIn } from "../../../../services/auth/hexclave/completeSignIn";
import {
  formString,
  isSameOriginFormPost,
} from "../../../../services/auth/hexclave/formRequest";
import {
  createOAuthHandoff,
  setOAuthHandoffCookie,
} from "../../../../services/auth/hexclave/oauthState";
import {
  DEFAULT_AFTER_AUTH_PATH,
  safeReturnToPath,
} from "../../../../services/auth/hexclave/returnTo";
import { secureCookiesForRequest } from "../../../../services/auth/hexclave/session";

const OAUTH_CALLBACK_PATH = "/handler/oauth-callback";

/**
 * Starts the outer OAuth flow on the server.
 *
 * The browser SDK generates the PKCE verifier in the page and parks it in
 * localStorage. Doing it here instead keeps the verifier httpOnly, keeps the
 * sign-in page free of JavaScript, and means the callback can finish the whole
 * exchange before the first byte of HTML is sent.
 */
export async function POST(
  request: NextRequest,
  context: { params: Promise<{ provider: string }> },
): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });
  if (!isSameOriginFormPost(request, origin)) {
    return NextResponse.json({ error: "cross_origin" }, { status: 403 });
  }

  const { provider } = await context.params;
  if (!isHexclaveOAuthProvider(provider)) {
    return failSignIn(origin, "/handler/sign-in", {
      error: "oauthProviderUnavailable",
    });
  }

  const form = await request.formData();
  const returnTo = safeReturnToPath(
    formString(form, "after_auth_return_to") || null,
    DEFAULT_AFTER_AUTH_PATH,
  );
  const handoff = await createOAuthHandoff(returnTo);

  const response = NextResponse.redirect(
    oauthAuthorizeURL(config, {
      provider,
      redirectURI: new URL(OAUTH_CALLBACK_PATH, origin).toString(),
      errorRedirectURL: new URL("/handler/auth-error", origin).toString(),
      state: handoff.state,
      codeChallenge: handoff.codeChallenge,
    }),
  );
  setOAuthHandoffCookie(
    response,
    {
      state: handoff.state,
      codeVerifier: handoff.codeVerifier,
      returnTo,
    },
    secureCookiesForRequest(request),
  );
  return response;
}
