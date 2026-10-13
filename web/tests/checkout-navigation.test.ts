import { describe, expect, test } from "bun:test";

import { isCheckoutHref } from "../app/components/checkout-navigation";

describe("checkout navigation", () => {
  test("recognizes app pricing checkout URLs before navigation", () => {
    expect(
      isCheckoutHref(
        "http://localhost:9210/api/billing/checkout?plan=pro&cmux_external_browser=1",
      ),
    ).toBe(true);
    expect(isCheckoutHref("/api/billing/checkout?plan=max")).toBe(true);
    expect(isCheckoutHref("https://cmux.com/api/billing/checkout-now")).toBe(false);
  });
});
