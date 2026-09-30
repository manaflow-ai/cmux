import { checkRateLimit } from "@vercel/firewall";
import { NextRequest, NextResponse } from "next/server";
import { env } from "../../env";
import { stackServerApp } from "../../lib/stack";
import { requestOrigin } from "../../lib/request-origin";
import {
  createStackBrowserSessionHandoffAdapter,
  type StackBrowserSessionHandoffAdapter,
} from "../../../services/auth/stackBrowserSessionHandoff";


const MAX_BODY_BYTES = 32 * 1024;
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX_REQUESTS = 60;
const APP_HANDOFF_HEADER = "x-cmux-app-session-handoff";
const APP_HANDOFF_RESPONSE_HEADER = "x-cmux-app-session-response";

type AppSessionHandoffDependencies = {
  sessionAdapter: StackBrowserSessionHandoffAdapter | null;
  now?: () => number;
  checkRateLimit?: typeof checkRateLimit;
  isVercel?: () => boolean;
  rateLimitId?: string;
};

type RateLimitEntry = {
  count: number;
  resetAt: number;
};

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
  const target = new URL("/handler/sign-in", requestOrigin(request));
  target.searchParams.set("after_auth_return_to", afterPath);
  return NextResponse.redirect(target, 303);
}

function requestsCookieExchange(request: NextRequest): boolean {
  return request.headers.get(APP_HANDOFF_RESPONSE_HEADER) === "cookies";
}

function handoffFailure(
  request: NextRequest,
  afterPath: string,
  status = 401,
): NextResponse {
  if (requestsCookieExchange(request)) {
    return new NextResponse(null, {
      status,
      headers: { "Cache-Control": "no-store" },
    });
  }
  return signInRedirect(request, afterPath);
}

function makeLocalRateLimiter(): (now: number) => boolean {
  let entry: RateLimitEntry | null = null;
  return (now: number) => {
    if (!entry || entry.resetAt <= now) {
      entry = {
        count: 1,
        resetAt: now + RATE_LIMIT_WINDOW_MS,
      };
      return false;
    }
    entry.count += 1;
    return entry.count > RATE_LIMIT_MAX_REQUESTS;
  };
}

function isNativeAppHandoff(request: NextRequest): boolean {
  // A cross-origin browser form cannot set this non-safelisted header, and this
  // route never grants CORS access for a scripted cross-origin request.
  if (request.headers.get(APP_HANDOFF_HEADER) !== "1") return false;
  if (request.headers.get("sec-fetch-site")?.toLowerCase() === "cross-site") {
    return false;
  }
  const origin = request.headers.get("origin");
  if (origin && origin !== "null") {
    try {
      if (new URL(origin).origin !== requestOrigin(request)) return false;
    } catch {
      return false;
    }
  }
  return true;
}

async function isDurablyRateLimited(
  request: NextRequest,
  dependencies: AppSessionHandoffDependencies,
): Promise<boolean> {
  if (!isVercelRuntime(dependencies)) return false;

  const rateLimitId = dependencies.rateLimitId
    ?? env.CMUX_APP_SESSION_HANDOFF_RATE_LIMIT_ID
    ?? env.CMUX_FEEDBACK_RATE_LIMIT_ID;
  // Token exchange is security-sensitive, so a deployed route fails closed if
  // its durable limiter is missing, deleted, blocked, or unavailable.
  if (!rateLimitId) return true;

  try {
    const result = await (dependencies.checkRateLimit ?? checkRateLimit)(
      rateLimitId,
      { request },
    );
    return result.rateLimited || Boolean(result.error);
  } catch {
    return true;
  }
}

function isVercelRuntime(
  dependencies: AppSessionHandoffDependencies,
): boolean {
  return dependencies.isVercel?.() ?? process.env.VERCEL === "1";
}

async function parseHandoffBody(request: NextRequest): Promise<URLSearchParams | null> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/x-www-form-urlencoded")) return null;
  if (contentLengthExceedsLimit(request)) return null;
  const body = await readBodyWithLimit(request, MAX_BODY_BYTES);
  if (body === null) return null;
  return new URLSearchParams(body);
}

function contentLengthExceedsLimit(request: NextRequest): boolean {
  const value = request.headers.get("content-length")?.trim();
  if (!value || !/^\d+$/.test(value)) return false;
  const length = Number(value);
  return !Number.isSafeInteger(length) || length > MAX_BODY_BYTES;
}

async function readBodyWithLimit(
  request: NextRequest,
  limit: number,
): Promise<string | null> {
  const reader = request.body?.getReader();
  if (!reader) return "";

  const decoder = new TextDecoder();
  let byteLength = 0;
  let body = "";
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    byteLength += chunk.value.byteLength;
    if (byteLength > limit) {
      await reader.cancel();
      return null;
    }
    body += decoder.decode(chunk.value, { stream: true });
  }
  return body + decoder.decode();
}

export function makeAppSessionHandoffHandler(
  dependencies: AppSessionHandoffDependencies,
) {
  // Production uses Vercel's durable limiter below. This process-local budget
  // covers non-Vercel development runtimes and deliberately does not trust
  // forwarding headers supplied by the caller.
  const isLocallyRateLimited = makeLocalRateLimiter();
  return async function POST(request: NextRequest) {
    if (!isNativeAppHandoff(request)) {
      return NextResponse.redirect(new URL("/", requestOrigin(request)), 303);
    }

    if (contentLengthExceedsLimit(request)) {
      return NextResponse.redirect(new URL("/", requestOrigin(request)), 303);
    }

    const sessionAdapter = dependencies.sessionAdapter;
    if (!sessionAdapter) return handoffFailure(request, "/", 503);
    if (!isVercelRuntime(dependencies)) {
      // Production token exchange requires the durable Vercel firewall. The
      // process-local budget exists only for `next dev` and tests, where one
      // developer owns the process and a shared bucket cannot affect customers.
      if (process.env.NODE_ENV === "production") {
        return handoffFailure(request, "/", 503);
      }
      if (isLocallyRateLimited(dependencies.now?.() ?? Date.now())) {
        return handoffFailure(request, "/", 429);
      }
    }
    if (await isDurablyRateLimited(request, dependencies)) {
      return handoffFailure(request, "/", 429);
    }

    let form: URLSearchParams | null;
    try {
      form = await parseHandoffBody(request);
    } catch {
      form = null;
    }
    const afterPath = sanitizedAfterPath(form?.get("after") ?? null);
    if (!form || !afterPath) {
      return NextResponse.redirect(new URL("/", requestOrigin(request)), 303);
    }

    const refreshToken = form.get("refresh_token")?.trim();
    const accessToken = form.get("access_token")?.trim();
    if (!refreshToken || !accessToken) {
      return handoffFailure(request, afterPath);
    }

    try {
      const cookieExchange = requestsCookieExchange(request);
      const response = cookieExchange
        ? new NextResponse(null, { status: 204 })
        : NextResponse.redirect(
          new URL(afterPath, requestOrigin(request)),
          303,
        );
      const established = await sessionAdapter.establish({
        request,
        response,
        tokens: { refreshToken, accessToken },
        now: dependencies.now?.() ?? Date.now(),
      });
      if (!established) return handoffFailure(request, afterPath);
      response.headers.set("Cache-Control", "no-store");
      response.headers.set("Referrer-Policy", "no-referrer");
      if (cookieExchange) {
        response.headers.set("X-Cmux-App-Session-Handoff", "ready");
      }
      return response;
    } catch {
      return handoffFailure(request, afterPath, 503);
    }
  };
}

export const POST = makeAppSessionHandoffHandler({
  sessionAdapter: stackServerApp && env.NEXT_PUBLIC_STACK_PROJECT_ID
    ? createStackBrowserSessionHandoffAdapter(
        stackServerApp,
        env.NEXT_PUBLIC_STACK_PROJECT_ID,
      )
    : null,
});
