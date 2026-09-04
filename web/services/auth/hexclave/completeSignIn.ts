import { NextResponse, type NextRequest } from "next/server";

import type { HexclaveSignInSuccess } from "./auth";
import type { HexclaveClientConfig } from "./config";
import { authPageHref, DEFAULT_AFTER_AUTH_PATH, safeReturnToPath } from "./returnTo";
import { secureCookiesForRequest, setHexclaveSessionCookies } from "./session";

/**
 * Turns a fresh token pair into a signed-in browser.
 *
 * Every successful auth path ends here so the cookie shape, the redirect
 * policy, and the same-origin check on the caller's destination exist once
 * rather than once per screen.
 */
export function completeSignIn(
  request: NextRequest,
  config: HexclaveClientConfig,
  tokens: HexclaveSignInSuccess,
  options: { readonly origin: string; readonly returnTo?: string | null },
): NextResponse {
  const destination = safeReturnToPath(
    options.returnTo,
    DEFAULT_AFTER_AUTH_PATH,
  );
  const response = NextResponse.redirect(new URL(destination, options.origin));
  setHexclaveSessionCookies(response, {
    projectId: config.projectId,
    secure: secureCookiesForRequest(request),
    tokens,
    now: Date.now(),
  });
  return response;
}

/** Sends the visitor back to an auth screen with a localizable error key. */
export function failSignIn(
  origin: string,
  path: string,
  params: {
    readonly error: string;
    readonly returnTo?: string | null;
    readonly email?: string | null;
    readonly method?: string | null;
    readonly nonce?: string | null;
  },
): NextResponse {
  return NextResponse.redirect(
    new URL(
      authPageHref(path, {
        returnTo: params.returnTo ?? null,
        email: params.email ?? null,
        method: params.method ?? null,
        nonce: params.nonce ?? null,
        error: params.error,
      }),
      origin,
    ),
  );
}
