import { describe, expect, test } from "bun:test";
import { withCheckoutExternalBrowserIntent } from "../app/lib/billing";

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
});
