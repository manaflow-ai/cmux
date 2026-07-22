import { describe, expect, test } from "bun:test";
import {
  appPricingCheckoutURL,
  withCheckoutExternalBrowserIntent,
} from "../app/lib/billing";

describe("billing links", () => {
  test("marks relative checkout URLs for system-browser handoff", () => {
    expect(withCheckoutExternalBrowserIntent("/api/billing/checkout")).toBe(
      "/api/billing/checkout?cmux_external_browser=1",
    );
  });

  test("preserves existing query strings and hash fragments", () => {
    expect(
      withCheckoutExternalBrowserIntent(
        "https://cmux.com/api/billing/checkout?plan=pro#pay",
      ),
    ).toBe(
      "https://cmux.com/api/billing/checkout?plan=pro&cmux_external_browser=1#pay",
    );
  });

  test("app pricing checkout uses the request origin", () => {
    expect(appPricingCheckoutURL("pro", "http://localhost:9210")).toBe(
      "http://localhost:9210/api/billing/checkout?plan=pro&cmux_external_browser=1",
    );
    expect(appPricingCheckoutURL("team", "https://cmux.com")).toBe(
      "https://cmux.com/api/billing/checkout?plan=team&cmux_external_browser=1",
    );
  });

  test("app pricing checkout can carry the native callback scheme", () => {
    expect(appPricingCheckoutURL("pro", "http://localhost:9210", "cmux-dev-test")).toBe(
      "http://localhost:9210/api/billing/checkout?plan=pro&cmux_external_browser=1&cmux_scheme=cmux-dev-test",
    );
  });

  test("app pricing checkout keeps an explicit origin override", () => {
    const previous = process.env.CMUX_APP_PRICING_CHECKOUT_URL;
    process.env.CMUX_APP_PRICING_CHECKOUT_URL = "https://billing.example/checkout";
    try {
      expect(appPricingCheckoutURL("pro", "http://localhost:9210")).toBe(
        "https://billing.example/checkout?plan=pro&cmux_external_browser=1",
      );
    } finally {
      if (previous === undefined) {
        delete process.env.CMUX_APP_PRICING_CHECKOUT_URL;
      } else {
        process.env.CMUX_APP_PRICING_CHECKOUT_URL = previous;
      }
    }
  });
});
