import { describe, expect, test } from "bun:test";

import {
  checkoutAttributionFromMetadata,
  checkoutAttributionFromRequest,
  checkoutAttributionMetadata,
  checkoutAttributionProperties,
  forwardCheckoutAttribution,
  withCheckoutAttribution,
} from "../services/analytics/checkoutAttribution";

describe("checkout attribution", () => {
  test("normalizes request parameters and falls back to unknown/web", () => {
    const attribution = checkoutAttributionFromRequest({
      searchParams: new URLSearchParams(
        "cmux_source=Mac_Sidebar_Badge&cmux_placement=<script>&cmux_client=MAC" +
          "&cmux_channel=beta&cmux_app_version=0.65.1&cmux_app_build=x y&utm_source=" +
          "%20Newsletter%20",
      ),
      referer: "https://cmux.com/app-pricing?cmux_app=1&secret=1",
    });

    expect(attribution).toEqual({
      source: "mac_sidebar_badge",
      placement: null,
      client: "mac",
      channel: null,
      appVersion: "0.65.1",
      appBuild: null,
      referrerHost: "cmux.com",
      referrerPath: "/app-pricing",
      utmSource: "Newsletter",
      utmMedium: null,
      utmCampaign: null,
      utmContent: null,
      utmTerm: null,
    });
  });

  test("defaults an untagged request to an unknown web checkout with no referrer", () => {
    const attribution = checkoutAttributionFromRequest({
      searchParams: new URLSearchParams("plan=pro"),
      referer: "javascript:alert(1)",
    });
    expect(attribution.source).toBe("unknown");
    expect(attribution.client).toBe("web");
    expect(attribution.referrerHost).toBeNull();
    expect(attribution.referrerPath).toBeNull();
  });

  test("round-trips through Stripe metadata", () => {
    const attribution = checkoutAttributionFromRequest({
      searchParams: new URLSearchParams(
        "cmux_source=pricing_page&cmux_placement=hero&cmux_client=web&utm_campaign=launch",
      ),
      referer: "https://cmux.com/pricing",
    });
    const metadata = checkoutAttributionMetadata(attribution);
    expect(metadata).toEqual({
      cmuxSource: "pricing_page",
      cmuxPlacement: "hero",
      cmuxClient: "web",
      cmuxReferrerHost: "cmux.com",
      cmuxReferrerPath: "/pricing",
      utmCampaign: "launch",
    });
    expect(checkoutAttributionFromMetadata(metadata)).toEqual(attribution);
    expect(Object.keys(checkoutAttributionProperties(attribution))).toEqual([
      "checkout_source",
      "checkout_placement",
      "checkout_client",
      "checkout_channel",
      "checkout_app_version",
      "checkout_app_build",
      "checkout_referrer_host",
      "checkout_referrer_path",
      "utm_source",
      "utm_medium",
      "utm_campaign",
      "utm_content",
      "utm_term",
    ]);
  });

  test("reads sessions created before attribution existed as unknown", () => {
    const attribution = checkoutAttributionFromMetadata({ plan: "pro", app: "cmux" });
    expect(attribution.source).toBe("unknown");
    expect(attribution.client).toBe("web");
    expect(attribution.channel).toBeNull();
  });

  test("appends attribution to a link and keeps the hash", () => {
    expect(
      withCheckoutAttribution("/api/billing/checkout?plan=pro#top", {
        cmux_source: "dashboard_billing",
        cmux_placement: null,
        utm_source: undefined,
      }),
    ).toBe("/api/billing/checkout?plan=pro&cmux_source=dashboard_billing#top");
  });

  test("forwards only attribution parameters onto a relay target", () => {
    const target = new URL("https://checkout.cmux.test/api/billing/checkout?plan=pro");
    forwardCheckoutAttribution(
      new URLSearchParams("cmux_source=mac_help_menu&cmux_channel=nightly&cmux_scheme=cmux&plan=team"),
      target,
    );
    expect(target.searchParams.get("cmux_source")).toBe("mac_help_menu");
    expect(target.searchParams.get("cmux_channel")).toBe("nightly");
    expect(target.searchParams.get("plan")).toBe("pro");
    expect(target.searchParams.has("cmux_scheme")).toBe(false);
  });
});
