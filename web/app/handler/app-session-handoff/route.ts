import { NextRequest, NextResponse } from "next/server";
import { env } from "../../env";
import { stackServerApp } from "../../lib/stack";

export const dynamic = "force-dynamic";

const SESSION_EXPIRES_IN_MS = 30 * 24 * 60 * 60 * 1000;
const STACK_ACCESS_COOKIE = "stack-access";
const STACK_REFRESH_COOKIE_PREFIX = "stack-refresh";

type StackAuthSessionLike = {
  getTokens: () => Promise<{
    refreshToken?: string | null;
    accessToken?: string | null;
  }>;
};

type StackAuthUserLike = {
  createSession: (options: { expiresInMillis: number }) => Promise<StackAuthSessionLike>;
};

type StackServerAppLike = {
  getUser: (options: {
    tokenStore: {
      accessToken?: string;
      refreshToken: string;
    };
  }) => Promise<StackAuthUserLike | null>;
} | null;

type AppSessionHandoffDependencies = {
  projectId: string | undefined;
  stackServerApp: StackServerAppLike | null;
};

type HandoffRateLimitEntry = {
  count: number;
  resetAt: number;
};

const handoffRateLimits = new Map<string, HandoffRateLimitEntry>();

function sanitizedAfterPath(value: string | null): string | null {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return null;
  try {
    const parsed = new URL(value, "https://cmux.invalid");
    if (parsed.origin !== "https://cmux.invalid") return null;
    if (parsed.pathname === "/handler/app-session-handoff") return null;
    const result = `${parsed.pathname}${parsed.search}${parsed.hash}`;
    // Dot-segment normalization can turn "/..//evil.com" into pathname
    // "//evil.com", which is protocol-relative when later resolved and would
    // 302 off-origin. Reject anything that is not a plain same-origin path.
    if (result.startsWith("//") || result.startsWith("/\\")) return null;
    if (new URL(result, "https://cmux.invalid").origin !== "https://cmux.invalid") return null;
    return result;
  } catch {
    return null;
  }
}

function signInRedirect(request: NextRequest, afterPath: string): NextResponse {
  const target = new URL("/handler/sign-in", request.nextUrl.origin);
  target.searchParams.set("after_auth_return_to", afterPath);
  return NextResponse.redirect(target, 302);
}

function requestRateLimitKey(request: NextRequest): string {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const address = forwarded || request.headers.get("x-real-ip") || "unknown";
  return `${address}:${request.headers.get("user-agent") ?? ""}`;
}

function isRateLimited(request: NextRequest, now = Date.now()): boolean {
  const key = requestRateLimitKey(request);
  const resetAt = now + 60_000;
  const entry = handoffRateLimits.get(key);
  if (!entry || entry.resetAt <= now) {
    handoffRateLimits.set(key, { count: 1, resetAt });
    return false;
  }
  entry.count += 1;
  return entry.count > 60;
}

function secureCookiesFor(request: NextRequest): boolean {
  return request.nextUrl.protocol === "https:";
}

function stackRefreshCookieName(projectId: string): string {
  return `${STACK_REFRESH_COOKIE_PREFIX}-${projectId}`;
}

function setCookie(
  response: NextResponse,
  name: string,
  value: string,
  request: NextRequest
) {
  response.cookies.set(name, value, {
    httpOnly: true,
    maxAge: SESSION_EXPIRES_IN_MS / 1000,
    path: "/",
    sameSite: "lax",
    secure: name.startsWith("__") || secureCookiesFor(request),
  });
}

function setStackSessionCookies(
  response: NextResponse,
  request: NextRequest,
  projectId: string,
  tokens: { refreshToken: string; accessToken: string }
) {
  const accessCookieValue = JSON.stringify([tokens.refreshToken, tokens.accessToken]);
  const refreshName = stackRefreshCookieName(projectId);
  const refreshNames = [refreshName, `${refreshName}--default`];

  setCookie(response, STACK_ACCESS_COOKIE, accessCookieValue, request);
  for (const name of refreshNames) {
    setCookie(response, name, tokens.refreshToken, request);
  }

  if (!secureCookiesFor(request)) return;
  setCookie(response, `__Host-${STACK_ACCESS_COOKIE}`, accessCookieValue, request);
  for (const name of refreshNames) {
    setCookie(response, `__Host-${name}`, tokens.refreshToken, request);
    setCookie(response, `__Secure-${name}`, tokens.refreshToken, request);
  }
}

export function makeAppSessionHandoffHandler(dependencies: AppSessionHandoffDependencies) {
  return async function POST(request: NextRequest) {
    const projectId = dependencies.projectId;
    const app = dependencies.stackServerApp;
    // A malformed POST (wrong/absent Content-Type) makes formData() throw; the
    // app always sends application/x-www-form-urlencoded, so treat anything
    // else as an unauthenticated request rather than a 500.
    let formData: FormData;
    try {
      formData = await request.formData();
    } catch {
      return NextResponse.redirect(new URL("/", request.url), 302);
    }
    const afterPath = sanitizedAfterPath(formData.get("after")?.toString() ?? null);
    if (!afterPath) return NextResponse.redirect(new URL("/", request.url), 302);
    if (!projectId || !app) return signInRedirect(request, afterPath);
    if (isRateLimited(request)) return signInRedirect(request, afterPath);

    const refreshToken = formData.get("refresh_token")?.toString().trim();
    const accessToken = formData.get("access_token")?.toString().trim();
    if (!refreshToken) return signInRedirect(request, afterPath);

    try {
      const user = await app.getUser({
        tokenStore: {
          ...(accessToken ? { accessToken } : {}),
          refreshToken,
        },
      });
      if (!user) return signInRedirect(request, afterPath);

      const session = await user.createSession({ expiresInMillis: SESSION_EXPIRES_IN_MS });
      const tokens = await session.getTokens();
      if (!tokens.refreshToken || !tokens.accessToken) return signInRedirect(request, afterPath);

      const response = NextResponse.redirect(new URL(afterPath, request.nextUrl.origin), 302);
      setStackSessionCookies(response, request, projectId, {
        refreshToken: tokens.refreshToken,
        accessToken: tokens.accessToken,
      });
      response.headers.set("Referrer-Policy", "no-referrer");
      response.headers.set("Cache-Control", "no-store");
      return response;
    } catch {
      return signInRedirect(request, afterPath);
    }
  };
}

export const POST = makeAppSessionHandoffHandler({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  // The handler only calls the narrow getUser({ tokenStore }) subset; the real
  // StackServerApp getUser has broader overloads that don't structurally match
  // StackServerAppLike, so cast at this boundary.
  stackServerApp: stackServerApp as unknown as StackServerAppLike,
});
