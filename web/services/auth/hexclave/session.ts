import type { NextResponse } from "next/server";

const SESSION_EXPIRES_IN_SECONDS = 30 * 24 * 60 * 60;
const ACCESS_COOKIE_MAX_AGE_SECONDS = 24 * 60 * 60;

export type HexclaveSessionTokens = {
  readonly accessToken: string;
  readonly refreshToken: string;
};

/**
 * Writes the browser session in the exact shape `@stackframe/stack` reads.
 *
 * This is the one seam that lets cmux own its auth screens without owning the
 * session layer: our SSR flows mint tokens over REST and store them here, and
 * `StackServerApp.getUser()` plus `useUser()` keep working untouched. Changing
 * a name or an encoding here silently signs everyone out, so the integration
 * test pins both cookies.
 */
export function setHexclaveSessionCookies(
  response: NextResponse,
  options: {
    readonly projectId: string;
    readonly secure: boolean;
    readonly tokens: HexclaveSessionTokens;
    readonly now: number;
  },
): void {
  const securePrefix = options.secure ? "__Host-" : "";
  response.cookies.set(
    "hexclave-access",
    JSON.stringify([options.tokens.refreshToken, options.tokens.accessToken]),
    cookieOptions(options.secure, ACCESS_COOKIE_MAX_AGE_SECONDS),
  );
  response.cookies.set(
    `${securePrefix}hexclave-refresh-${options.projectId}--default`,
    JSON.stringify({
      refresh_token: options.tokens.refreshToken,
      updated_at_millis: options.now,
    }),
    cookieOptions(options.secure, SESSION_EXPIRES_IN_SECONDS),
  );
}

export function secureCookiesForRequest(request: {
  readonly nextUrl: { readonly protocol: string };
  readonly headers: Headers;
}): boolean {
  return request.nextUrl.protocol === "https:" ||
    request.headers.get("x-forwarded-proto") === "https";
}

function cookieOptions(secure: boolean, maxAge: number) {
  return {
    maxAge,
    path: "/",
    sameSite: "lax" as const,
    secure,
  };
}
