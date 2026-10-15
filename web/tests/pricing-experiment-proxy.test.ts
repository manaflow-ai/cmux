import { afterEach, describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

import middleware from "../proxy";
import {
  POSTHOG_PERSISTENCE_COOKIE,
  setWebPricingFlagForTesting,
  type WebPricingFlagConfig,
} from "../services/billing/pricingExperiment/assignment";

const BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

const evenSplit: WebPricingFlagConfig = {
  active: true,
  rolloutPercentage: 100,
  variants: [
    { key: "control", rolloutPercentage: 25 },
    { key: "yearly-emphasis", rolloutPercentage: 25 },
    { key: "highlight-pro", rolloutPercentage: 25 },
    { key: "outcome-headline", rolloutPercentage: 25 },
  ],
};

function pricingRequest(options: { distinctId?: string; cookies?: string; userAgent?: string; language?: string; path?: string } = {}) {
  const cookies = [
    options.distinctId
      ? `${POSTHOG_PERSISTENCE_COOKIE}=${encodeURIComponent(JSON.stringify({ distinct_id: options.distinctId }))}`
      : null,
    options.cookies ?? null,
  ].filter(Boolean).join("; ");
  return new NextRequest(`https://cmux.test${options.path ?? "/pricing"}`, {
    headers: {
      "user-agent": options.userAgent ?? BROWSER,
      "accept-language": options.language ?? "en-US,en;q=0.9",
      ...(cookies ? { cookie: cookies } : {}),
    },
  });
}

function rewrittenPath(response: Response): string | null {
  const rewrite = response.headers.get("x-middleware-rewrite");
  return rewrite ? new URL(rewrite).pathname : null;
}

function setCookie(response: Response, name: string): string | null {
  return response.headers.getSetCookie().find((cookie) => cookie.startsWith(`${name}=`)) ?? null;
}

afterEach(() => setWebPricingFlagForTesting(null));

describe("web-pricing-v1 assignment at the proxy", () => {
  // Expected arms are PostHog's own hash (sha1 of "web-pricing-v1.<id>variant"),
  // computed independently, so the proxy agrees with PostHog's evaluation.
  test.each([
    ["visitor-5", "/en/pricing/highlight-pro", "highlight-pro"],
    ["visitor-4", "/en/pricing/yearly-emphasis", "yearly-emphasis"],
    ["visitor-0", "/en/pricing/outcome-headline", "outcome-headline"],
    ["visitor-2", "/en/pricing", "control"],
  ])("serves %s the arm PostHog assigns, as server HTML behind /pricing", (distinctId, path, variant) => {
    setWebPricingFlagForTesting(evenSplit);
    const response = middleware(pricingRequest({ distinctId }));

    expect(response.headers.get("location")).toBeNull();
    expect(rewrittenPath(response)).toBe(path);
    expect(setCookie(response, "cmux_wp1")).toStartWith(`cmux_wp1=${variant};`);
    expect(setCookie(response, "cmux_wp1_live")).toStartWith("cmux_wp1_live=1;");
    expect(response.headers.get("cache-control")).toBe("private, no-cache");
  });

  test("keeps a pinned visitor in their arm after the split moves away from it", () => {
    setWebPricingFlagForTesting({
      ...evenSplit,
      variants: evenSplit.variants.map((variant) => ({
        ...variant,
        rolloutPercentage: variant.key === "control" ? 100 : 0,
      })),
    });
    const response = middleware(pricingRequest({ distinctId: "visitor-2", cookies: "cmux_wp1=yearly-emphasis" }));

    expect(rewrittenPath(response)).toBe("/en/pricing/yearly-emphasis");
    expect(setCookie(response, "cmux_wp1_live")).toStartWith("cmux_wp1_live=1;");
  });

  test("the kill switch serves control and ends exposure but keeps the pin for resume", () => {
    setWebPricingFlagForTesting({ ...evenSplit, active: false });
    const response = middleware(pricingRequest({ distinctId: "visitor-5", cookies: "cmux_wp1=highlight-pro; cmux_wp1_live=1" }));

    expect(rewrittenPath(response)).toBe("/en/pricing");
    expect(setCookie(response, "cmux_wp1")).toBeNull();
    expect(setCookie(response, "cmux_wp1_live")).toMatch(/^cmux_wp1_live=;.*Max-Age=0/i);
  });

  test("a visitor outside a partial rollout is not in the experiment, not counted as control", () => {
    setWebPricingFlagForTesting({ ...evenSplit, rolloutPercentage: 50 });
    const outside = middleware(pricingRequest({ distinctId: "visitor-3" }));
    expect(rewrittenPath(outside)).toBe("/en/pricing");
    expect(setCookie(outside, "cmux_wp1")).toBeNull();
    expect(setCookie(outside, "cmux_wp1_live")).toBeNull();
    expect(outside.headers.get("cache-control")).toBeNull();

    const inside = middleware(pricingRequest({ distinctId: "visitor-5" }));
    expect(rewrittenPath(inside)).toBe("/en/pricing/highlight-pro");
  });

  test("a cold instance serves control without ending the visitor's exposure state", () => {
    const response = middleware(pricingRequest({ distinctId: "visitor-5", cookies: "cmux_wp1=highlight-pro; cmux_wp1_live=1" }));

    expect(rewrittenPath(response)).toBe("/en/pricing");
    expect(setCookie(response, "cmux_wp1")).toBeNull();
    expect(setCookie(response, "cmux_wp1_live")).toBeNull();
  });

  test("a pin to a variant that left the flag is reassigned", () => {
    setWebPricingFlagForTesting(evenSplit);
    const response = middleware(pricingRequest({ distinctId: "visitor-5", cookies: "cmux_wp1=retired-arm" }));

    expect(rewrittenPath(response)).toBe("/en/pricing/highlight-pro");
    expect(setCookie(response, "cmux_wp1")).toStartWith("cmux_wp1=highlight-pro;");
  });

  test.each([
    ["a crawler", "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"],
    ["a script", "curl/8.7.1"],
    ["a client without a user agent", ""],
  ])("%s gets control with no assignment", (_label, userAgent) => {
    setWebPricingFlagForTesting(evenSplit);
    const response = middleware(pricingRequest({ distinctId: "visitor-5", userAgent }));

    expect(rewrittenPath(response)).toBe("/en/pricing");
    expect(setCookie(response, "cmux_wp1")).toBeNull();
    expect(setCookie(response, "cmux_wp1_live")).toBeNull();
  });

  test("without a fresh flag definition the experiment is off", () => {
    const response = middleware(pricingRequest({ distinctId: "visitor-5" }));

    expect(rewrittenPath(response)).toBe("/en/pricing");
    expect(setCookie(response, "cmux_wp1")).toBeNull();
  });

  test("a flag with targeting rules the proxy cannot evaluate fails closed to control", () => {
    setWebPricingFlagForTesting("unsupported");
    const response = middleware(pricingRequest({ distinctId: "visitor-5" }));

    expect(rewrittenPath(response)).toBe("/en/pricing");
    expect(setCookie(response, "cmux_wp1")).toBeNull();
  });

  test("other locales stay on their own pricing page", () => {
    setWebPricingFlagForTesting(evenSplit);
    const response = middleware(pricingRequest({ distinctId: "visitor-5", path: "/ja/pricing", language: "ja" }));

    expect(rewrittenPath(response) ?? "/ja/pricing").not.toContain("highlight-pro");
    expect(setCookie(response, "cmux_wp1")).toBeNull();
  });

  test("other pages are not assigned", () => {
    setWebPricingFlagForTesting(evenSplit);
    const response = middleware(pricingRequest({ distinctId: "visitor-5", path: "/docs" }));

    expect(setCookie(response, "cmux_wp1")).toBeNull();
  });
});
