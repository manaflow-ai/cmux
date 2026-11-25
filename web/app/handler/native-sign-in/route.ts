import { NextRequest, NextResponse } from "next/server";
import { requestOrigin } from "../../lib/request-origin";
import { SELECT_ACCOUNT_PROMPT } from "../sign-in-entry";
import { isValidCodeChallenge, PKCE_METHOD_S256 } from "../../lib/native-sign-in-codes";

function sameOriginURL(value: string, request: NextRequest): URL | null {
  try {
    const origin = requestOrigin(request);
    const url = new URL(value, origin);
    return url.origin === origin ? url : null;
  } catch {
    return null;
  }
}

/**
 * Entry for an app's browser sign-in. It wraps the hosted sign-in and
 * returns to `/handler/after-sign-in`, which always asks the person to
 * confirm the hand-off to the named app: anyone can open this URL, so nothing
 * set here may skip that click.
 */
export function GET(request: NextRequest) {
  const afterAuthReturnTo = request.nextUrl.searchParams.get("after_auth_return_to");
  if (!afterAuthReturnTo) return NextResponse.redirect(new URL("/handler/sign-in", requestOrigin(request)));

  const afterSignInURL = sameOriginURL(afterAuthReturnTo, request);
  if (!afterSignInURL || afterSignInURL.pathname !== "/handler/after-sign-in") {
    return NextResponse.redirect(new URL("/", requestOrigin(request)));
  }

  // The app's PKCE challenge rides on the entry URL; after-sign-in binds the
  // one-time code to it. A malformed challenge or another method is refused
  // rather than silently downgraded to the legacy token hand-off.
  const codeChallenge = request.nextUrl.searchParams.get("code_challenge");
  if (codeChallenge !== null) {
    const method = request.nextUrl.searchParams.get("code_challenge_method");
    if (!isValidCodeChallenge(codeChallenge) || method !== PKCE_METHOD_S256) {
      return NextResponse.redirect(new URL("/", requestOrigin(request)));
    }
    afterSignInURL.searchParams.set("code_challenge", codeChallenge);
    afterSignInURL.searchParams.set("code_challenge_method", PKCE_METHOD_S256);
  }

  const stackSignInURL = new URL("/handler/sign-in", requestOrigin(request));
  stackSignInURL.searchParams.set("after_auth_return_to", afterSignInURL.toString());
  // The app's Switch Account asks the page to confirm the account even when
  // this browser is already signed in. Only that one value is passed on.
  if (request.nextUrl.searchParams.get("prompt") === SELECT_ACCOUNT_PROMPT) {
    stackSignInURL.searchParams.set("prompt", SELECT_ACCOUNT_PROMPT);
  }
  return NextResponse.redirect(stackSignInURL);
}
