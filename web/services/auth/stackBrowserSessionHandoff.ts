import type { StackServerApp } from "@stackframe/stack";
import type { NextRequest, NextResponse } from "next/server";

const SESSION_EXPIRES_IN_SECONDS = 30 * 24 * 60 * 60;
const ACCESS_COOKIE_MAX_AGE_SECONDS = 24 * 60 * 60;

export type StackBrowserSessionTokens = {
  readonly accessToken: string;
  readonly refreshToken: string;
};

export type StackBrowserSessionHandoffAdapter = {
  establish(input: {
    readonly request: NextRequest;
    readonly response: NextResponse;
    readonly tokens: StackBrowserSessionTokens;
    readonly now: number;
  }): Promise<boolean>;
};

/**
 * Contains the one version-sensitive boundary between native handoff and
 * Stack's browser cookie store. The app argument is the real SDK type, so an
 * SDK token-store contract change fails typecheck here instead of being hidden
 * by a route-level cast. The integration test pins the cookie names and values
 * currently read by @stackframe/stack 2.8.x.
 */
export function createStackBrowserSessionHandoffAdapter(
  app: StackServerApp<true>,
  projectId: string,
): StackBrowserSessionHandoffAdapter {
  return {
    establish: async ({ request, response, tokens, now }) => {
      const user = await app.getUser({ tokenStore: tokens });
      if (!user) return false;

      const validated = await user.currentSession.getTokens();
      if (!validated.refreshToken || !validated.accessToken) return false;

      setStackSessionCookies(response, request, projectId, {
        refreshToken: validated.refreshToken,
        accessToken: validated.accessToken,
      }, now);
      return true;
    },
  };
}

function setStackSessionCookies(
  response: NextResponse,
  request: NextRequest,
  projectId: string,
  tokens: StackBrowserSessionTokens,
  now: number,
): void {
  const secure = secureCookiesFor(request);
  const securePrefix = secure ? "__Host-" : "";
  response.cookies.set(
    "hexclave-access",
    JSON.stringify([tokens.refreshToken, tokens.accessToken]),
    cookieOptions(secure, ACCESS_COOKIE_MAX_AGE_SECONDS),
  );
  response.cookies.set(
    `${securePrefix}hexclave-refresh-${projectId}--default`,
    JSON.stringify({
      refresh_token: tokens.refreshToken,
      updated_at_millis: now,
    }),
    cookieOptions(secure, SESSION_EXPIRES_IN_SECONDS),
  );
}

function secureCookiesFor(request: NextRequest): boolean {
  return request.nextUrl.protocol === "https:"
    || request.headers.get("x-forwarded-proto") === "https";
}

function cookieOptions(secure: boolean, maxAge: number) {
  return {
    maxAge,
    path: "/",
    sameSite: "lax" as const,
    secure,
  };
}
