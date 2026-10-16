import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

import middleware from "../proxy";

describe("billing success routing", () => {
  test("keeps the Stripe URL while rendering through the localized dashboard route", () => {
    const response = middleware(
      new NextRequest(
        "https://cmux.test/billing/success?session_id=cs_123&cmux_scheme=cmux-nightly",
        { headers: { "accept-language": "ja" } },
      ),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
    const rewritten = new URL(response.headers.get("x-middleware-rewrite")!);
    expect(rewritten.pathname).toBe("/ja/dashboard/billing/success");
    expect(rewritten.search).toBe(
      "?session_id=cs_123&cmux_scheme=cmux-nightly",
    );
    expect(
      response.headers.get("x-middleware-request-x-next-intl-locale"),
    ).toBe("ja");
  });

  test("keeps the public Founder recovery URL while localizing its page", () => {
    const response = middleware(
      new NextRequest("https://cmux.test/billing/recover", {
        headers: { "accept-language": "ja" },
      }),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
    const rewritten = new URL(response.headers.get("x-middleware-rewrite")!);
    expect(rewritten.pathname).toBe("/ja/billing/recover");
    expect(response.headers.get("x-middleware-request-x-next-intl-locale")).toBe(
      "ja",
    );
  });
});
