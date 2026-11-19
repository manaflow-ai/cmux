import { randomUUID } from "crypto";
import { NextRequest, NextResponse } from "next/server";
import {
  issueNativeHandoffCookie,
  NATIVE_HANDOFF_QUERY_PARAM,
} from "../native-handoff-cookie";
import { requestOrigin } from "../../lib/request-origin";
import { SELECT_ACCOUNT_PROMPT } from "../sign-in-entry";
import { isValidCodeChallenge, PKCE_METHOD_S256 } from "../../lib/native-sign-in-codes";


function canSetAutoHandoff(request: NextRequest): boolean {
  const fetchSite = request.headers.get("sec-fetch-site");
  return fetchSite === null || fetchSite === "none" || fetchSite === "same-origin" || fetchSite === "same-site";
}

function sameOriginURL(value: string, request: NextRequest): URL | null {
  try {
    const origin = requestOrigin(request);
    const url = new URL(value, origin);
    return url.origin === origin ? url : null;
  } catch {
    return null;
  }
}

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

  const nativeReturnTo = afterSignInURL.searchParams.get("native_app_return_to");
  const shouldSetHandoff = canSetAutoHandoff(request) && nativeReturnTo?.includes("cmux_auth_state") === true;
  let nonce: string | null = null;
  if (shouldSetHandoff) {
    nonce = randomUUID();
    afterSignInURL.searchParams.set(NATIVE_HANDOFF_QUERY_PARAM, nonce);
  }

  const stackSignInURL = new URL("/handler/sign-in", requestOrigin(request));
  stackSignInURL.searchParams.set("after_auth_return_to", afterSignInURL.toString());
  // The app's Switch Account asks the page to confirm the account even when
  // this browser is already signed in. Only that one value is passed on.
  if (request.nextUrl.searchParams.get("prompt") === SELECT_ACCOUNT_PROMPT) {
    stackSignInURL.searchParams.set("prompt", SELECT_ACCOUNT_PROMPT);
  }
  const response = NextResponse.redirect(stackSignInURL);
  if (nonce) {
    issueNativeHandoffCookie(response, request, nonce);
  }
  return response;
}
