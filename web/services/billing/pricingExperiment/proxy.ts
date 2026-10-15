import type { NextRequest, NextResponse } from "next/server";

import {
  POSTHOG_PERSISTENCE_COOKIE,
  assignWebPricingVariant,
  cachedWebPricingFlag,
  postHogDistinctIdFromCookie,
} from "./assignment";
import {
  WEB_PRICING_ASSIGNMENT_COOKIE,
  WEB_PRICING_CONTROL_VARIANT,
  WEB_PRICING_LIVE_COOKIE,
} from "./webPricingV1";

const ENGLISH_PRICING_PATH = /^\/en\/pricing\/?$/;
const PIN_MAX_AGE_SECONDS = 365 * 24 * 60 * 60;
const LIVE_MAX_AGE_SECONDS = 24 * 60 * 60;

/**
 * Applies `web-pricing-v1` to the locale router's response for `/pricing`.
 * Only an English rewrite (`/pricing` -> `/en/pricing`) takes part; other
 * locales, redirects and every other path pass through unchanged. A
 * non-control variant is served by rewriting to its static route
 * (`/en/pricing/<variant>`), so the browser keeps the `/pricing` URL and
 * receives the variant's HTML directly.
 */
export function withWebPricingExperiment(
  request: NextRequest,
  response: NextResponse,
  event?: { waitUntil(promise: Promise<unknown>): void },
): NextResponse {
  if (request.method !== "GET" && request.method !== "HEAD") return response;
  const rewrite = response.headers.get("x-middleware-rewrite");
  if (!rewrite) return response;
  const target = new URL(rewrite);
  if (!ENGLISH_PRICING_PATH.test(target.pathname)) return response;

  const assignment = assignWebPricingVariant({
    config: cachedWebPricingFlag({ waitUntil: event ? (promise) => event.waitUntil(promise) : undefined }),
    userAgent: request.headers.get("user-agent"),
    pinned: request.cookies.get(WEB_PRICING_ASSIGNMENT_COOKIE)?.value ?? null,
    distinctId: postHogDistinctIdFromCookie(request.cookies.get(POSTHOG_PERSISTENCE_COOKIE)?.value)
      ?? crypto.randomUUID(),
  });

  if (assignment.variant !== WEB_PRICING_CONTROL_VARIANT) {
    target.pathname = `/en/pricing/${assignment.variant}`;
    response.headers.set("x-middleware-rewrite", target.toString());
  }
  // Variant HTML differs per visitor behind one URL; no shared cache may keep it.
  response.headers.set("cache-control", "private, no-store");

  const secure = request.nextUrl.protocol === "https:";
  if (assignment.inExperiment) {
    response.cookies.set(WEB_PRICING_ASSIGNMENT_COOKIE, assignment.variant, {
      path: "/", maxAge: PIN_MAX_AGE_SECONDS, sameSite: "lax", secure,
    });
    response.cookies.set(WEB_PRICING_LIVE_COOKIE, "1", {
      path: "/", maxAge: LIVE_MAX_AGE_SECONDS, sameSite: "lax", secure,
    });
  } else if (request.cookies.has(WEB_PRICING_LIVE_COOKIE)) {
    response.cookies.set(WEB_PRICING_LIVE_COOKIE, "", { path: "/", maxAge: 0, sameSite: "lax", secure });
  }
  return response;
}
