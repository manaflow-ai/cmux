import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../lib/request-origin";
import { exchangeOAuthCode } from "../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import {
  completeSignIn,
  failSignIn,
} from "../../../services/auth/hexclave/completeSignIn";
import { authErrorKeyForCode } from "../../../services/auth/hexclave/errorCodes";
import {
  clearOAuthHandoffCookie,
  readOAuthHandoff,
} from "../../../services/auth/hexclave/oauthState";
import { secureCookiesForRequest } from "../../../services/auth/hexclave/session";

const SIGN_IN_PATH = "/handler/sign-in";

/**
 * Finishes the outer OAuth flow without rendering anything.
 *
 * Stack's version of this URL is a client page that has to boot React, read
 * localStorage, and only then exchange the code. Here the exchange happens
 * inside the redirect that brought the visitor back, so the browser goes
 * straight from the provider to the destination.
 */
export async function GET(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });

  const secure = secureCookiesForRequest(request);
  const params = request.nextUrl.searchParams;
  const clear = (response: NextResponse) => {
    clearOAuthHandoffCookie(response, secure);
    return response;
  };

  // The handoff is read before anything else, and every failure below keeps
  // the cookie unless the state matched. Otherwise a forged callback could
  // cancel a sign-in attempt the visitor has running in another tab.
  const state = params.get("state");
  const handoff = state ? readOAuthHandoff(request, state, secure) : null;
  if (!handoff) {
    // No matching handoff means this callback did not start in this browser.
    // Treat it as an expired attempt rather than exchanging a code someone
    // else obtained.
    return failSignIn(origin, SIGN_IN_PATH, { error: "expiredCode" });
  }

  const upstreamErrorCode = params.get("errorCode");
  if (upstreamErrorCode) {
    return clear(
      failSignIn(origin, SIGN_IN_PATH, {
        error: authErrorKeyForCode(upstreamErrorCode),
        returnTo: handoff.returnTo,
      }),
    );
  }

  const code = params.get("code");
  if (!code) {
    return clear(failSignIn(origin, SIGN_IN_PATH, { error: "unexpected" }));
  }

  const result = await exchangeOAuthCode(config, {
    code,
    redirectURI: new URL("/handler/oauth-callback", origin).toString(),
    codeVerifier: handoff.codeVerifier,
  });
  if (!result.ok) {
    return clear(
      failSignIn(origin, SIGN_IN_PATH, {
        error: authErrorKeyForCode(result.error.code),
        returnTo: handoff.returnTo,
      }),
    );
  }

  // The destination comes from the cookie this server wrote, never from the
  // callback URL, so the provider round trip cannot redirect the visitor
  // anywhere the sign-in page did not already agree to.
  return clear(
    completeSignIn(request, config, result.value, {
      origin,
      returnTo: handoff.returnTo,
    }),
  );
}
