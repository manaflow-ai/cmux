import { describe, expect, mock, test } from "bun:test";
import { fakePostHog, installFakeBrowser } from "./analytics-consent-fake-browser";

// Website analytics are off by default: posthog-js is never initialized (no
// cookie, no identify, no capture) until the visitor accepts.
const browser = installFakeBrowser();
const { client, calls } = fakePostHog();
mock.module("posthog-js", () => ({ default: client }));

const consent = await import("../app/lib/posthog-client");

describe("website analytics consent", () => {
  test("does not initialize PostHog for a visitor who has not chosen", () => {
    expect(consent.readAnalyticsConsent()).toBeNull();
    expect(consent.analyticsEnabled()).toBe(false);
    expect(calls).toEqual([]);
    expect(browser.cookies.size).toBe(0);
  });

  test("initializes PostHog only once the visitor allows it", () => {
    consent.setAnalyticsConsent("granted");
    expect(calls).toEqual(["init"]);
    expect(consent.analyticsEnabled()).toBe(true);
    expect(browser.local.get(consent.ANALYTICS_CONSENT_STORAGE_KEY)).toBe("granted");
  });

  test("declining later opts out and clears PostHog's cookie and storage", () => {
    browser.cookies.set(`ph_${consent.POSTHOG_PROJECT_KEY}_posthog`, "{}");
    browser.cookies.set("NEXT_LOCALE", "en");
    browser.local.set(`ph_${consent.POSTHOG_PROJECT_KEY}_posthog`, "{}");
    calls.length = 0;
    consent.setAnalyticsConsent("denied");
    expect(calls).toEqual(["opt_out_capturing", "reset"]);
    expect(consent.analyticsEnabled()).toBe(false);
    expect([...browser.cookies.keys()]).toEqual(["NEXT_LOCALE"]);
    expect([...browser.local.keys()]).toEqual([consent.ANALYTICS_CONSENT_STORAGE_KEY]);
    expect(consent.readAnalyticsConsent()).toBe("denied");
  });

  test("forgetting the choice keeps analytics off until the visitor allows them again", () => {
    consent.setAnalyticsConsent("granted");
    expect(calls.at(-1)).toBe("opt_in_capturing");
    consent.setAnalyticsConsent(null);
    expect(consent.readAnalyticsConsent()).toBeNull();
    expect(consent.analyticsEnabled()).toBe(false);
    expect(calls.slice(-2)).toEqual(["opt_out_capturing", "reset"]);
  });

  test("the waitlist form keeps its own submission endpoint without PostHog's config", () => {
    expect(consent.POSTHOG_API_HOST).toBe("https://r.cmux.com");
    expect(consent.POSTHOG_PROJECT_KEY.startsWith("phc_")).toBe(true);
  });
});
