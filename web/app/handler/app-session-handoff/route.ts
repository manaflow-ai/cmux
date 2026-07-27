import { NextRequest, NextResponse } from "next/server";
import { env } from "../../env";
import { stackServerApp } from "../../lib/stack";

export const dynamic = "force-dynamic";

const SESSION_EXPIRES_IN_MS = 30 * 24 * 60 * 60 * 1000;
const ACCESS_COOKIE_MAX_AGE_SECONDS = 24 * 60 * 60;
const MAX_BODY_BYTES = 32 * 1024;
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX_REQUESTS = 60;
const RATE_LIMIT_MAX_ENTRIES = 2_048;

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
  stackServerApp: StackServerAppLike;
  now?: () => number;
};

type RateLimitEntry = {
  count: number;
  resetAt: number;
};

const rateLimits = new Map<string, RateLimitEntry>();

function sanitizedAfterPath(value: string | null): string | null {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return null;
  try {
    const parsed = new URL(value, "https://cmux.invalid");
    if (parsed.origin !== "https://cmux.invalid") return null;
    if (parsed.pathname === "/handler/app-session-handoff") return null;
    const result = `${parsed.pathname}${parsed.search}${parsed.hash}`;
    if (result.startsWith("//") || result.startsWith("/\\")) return null;
    if (new URL(result, "https://cmux.invalid").origin !== "https://cmux.invalid") {
      return null;
    }
    return result;
  } catch {
    return null;
  }
}

function signInRedirect(request: NextRequest, afterPath: string): NextResponse {
  const target = new URL("/handler/sign-in", request.nextUrl.origin);
  target.searchParams.set("after_auth_return_to", afterPath);
  return NextResponse.redirect(target, 303);
}

function requestRateLimitKey(request: NextRequest): string {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const address = forwarded || request.headers.get("x-real-ip") || "unknown";
  return `${address}:${request.headers.get("user-agent") ?? ""}`;
}

function pruneRateLimits(now: number): void {
  if (rateLimits.size < RATE_LIMIT_MAX_ENTRIES) return;
  for (const [key, entry] of rateLimits) {
    if (entry.resetAt <= now) rateLimits.delete(key);
  }
  while (rateLimits.size >= RATE_LIMIT_MAX_ENTRIES) {
    const oldestKey = rateLimits.keys().next().value;
    if (typeof oldestKey !== "string") break;
    rateLimits.delete(oldestKey);
  }
}

function isRateLimited(request: NextRequest, now = Date.now()): boolean {
  const key = requestRateLimitKey(request);
  const entry = rateLimits.get(key);
  if (!entry || entry.resetAt <= now) {
    pruneRateLimits(now);
    rateLimits.set(key, {
      count: 1,
      resetAt: now + RATE_LIMIT_WINDOW_MS,
    });
    return false;
  }
  entry.count += 1;
  return entry.count > RATE_LIMIT_MAX_REQUESTS;
}

function secureCookiesFor(request: NextRequest): boolean {
  return request.nextUrl.protocol === "https:"
    || request.headers.get("x-forwarded-proto") === "https";
}

function setCookie(
  response: NextResponse,
  name: string,
  value: string,
  request: NextRequest,
  maxAge: number,
): void {
  response.cookies.set(name, value, {
    maxAge,
    path: "/",
    sameSite: "lax",
    secure: secureCookiesFor(request),
  });
}

function setStackSessionCookies(
  response: NextResponse,
  request: NextRequest,
  projectId: string,
  tokens: { refreshToken: string; accessToken: string },
  now: number,
): void {
  const accessCookieValue = JSON.stringify([tokens.refreshToken, tokens.accessToken]);
  const refreshCookieValue = JSON.stringify({
    refresh_token: tokens.refreshToken,
    updated_at_millis: now,
  });
  const securePrefix = secureCookiesFor(request) ? "__Host-" : "";
  const refreshName =
    `${securePrefix}hexclave-refresh-${projectId}--default`;

  // Stack's browser token store intentionally reads these cookies from
  // document.cookie. Match its current names, values, and browser visibility.
  setCookie(
    response,
    "hexclave-access",
    accessCookieValue,
    request,
    ACCESS_COOKIE_MAX_AGE_SECONDS,
  );
  setCookie(
    response,
    refreshName,
    refreshCookieValue,
    request,
    SESSION_EXPIRES_IN_MS / 1000,
  );
}

async function parseHandoffBody(request: NextRequest): Promise<URLSearchParams | null> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/x-www-form-urlencoded")) return null;
  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES) return null;
  return new URLSearchParams(body);
}

export function makeAppSessionHandoffHandler(
  dependencies: AppSessionHandoffDependencies,
) {
  return async function POST(request: NextRequest) {
    let form: URLSearchParams | null;
    try {
      form = await parseHandoffBody(request);
    } catch {
      form = null;
    }
    const afterPath = sanitizedAfterPath(form?.get("after") ?? null);
    if (!form || !afterPath) {
      return NextResponse.redirect(new URL("/", request.url), 303);
    }

    const app = dependencies.stackServerApp;
    const projectId = dependencies.projectId;
    if (!app || !projectId || isRateLimited(request)) {
      return signInRedirect(request, afterPath);
    }

    const refreshToken = form.get("refresh_token")?.trim();
    const accessToken = form.get("access_token")?.trim();
    if (!refreshToken) return signInRedirect(request, afterPath);

    try {
      const user = await app.getUser({
        tokenStore: {
          ...(accessToken ? { accessToken } : {}),
          refreshToken,
        },
      });
      if (!user) return signInRedirect(request, afterPath);

      const session = await user.createSession({
        expiresInMillis: SESSION_EXPIRES_IN_MS,
      });
      const tokens = await session.getTokens();
      if (!tokens.refreshToken || !tokens.accessToken) {
        return signInRedirect(request, afterPath);
      }

      const response = NextResponse.redirect(
        new URL(afterPath, request.nextUrl.origin),
        303,
      );
      setStackSessionCookies(response, request, projectId, {
        refreshToken: tokens.refreshToken,
        accessToken: tokens.accessToken,
      }, dependencies.now?.() ?? Date.now());
      response.headers.set("Cache-Control", "no-store");
      response.headers.set("Referrer-Policy", "no-referrer");
      return response;
    } catch {
      return signInRedirect(request, afterPath);
    }
  };
}

export const POST = makeAppSessionHandoffHandler({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  stackServerApp: stackServerApp as unknown as StackServerAppLike,
});
