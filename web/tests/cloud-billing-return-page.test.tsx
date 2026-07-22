import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { NextRequest } from "next/server";

let acceptLanguage = "en";

mock.module("next/headers", () => ({
  headers: async () => new Headers({ "accept-language": acceptLanguage }),
  cookies: async () => ({
    get: () => undefined,
    getAll: () => [],
    has: () => false,
  }),
  draftMode: async () => ({ isEnabled: false }),
}));

const { default: CloudBillingReturnPage, generateMetadata } = await import(
  "../app/cloud/billing/page"
);
const { default: middleware } = await import("../proxy");

describe("cloud billing return page", () => {
  test("renders a distinct message for each supported billing return", async () => {
    const cases = [
      ["checkout-success", "checkoutSuccess", "Checkout complete"],
      ["checkout-canceled", "checkoutCanceled", "Checkout canceled"],
      ["portal-return", "portalReturn", "Back from the billing portal"],
    ] as const;

    for (const [status, messageKey, title] of cases) {
      const element = await CloudBillingReturnPage({
        searchParams: Promise.resolve({ status }),
      });
      const html = renderToStaticMarkup(element);

      expect(html).toContain(`data-billing-status="${messageKey}"`);
      expect(html).toContain(title);
      expect(html).toContain("Return to the terminal where you ran ssh cmux.cloud");
      expect(html).toContain("ssh cmux.cloud");
    }
  });

  test("uses a generic safe state for missing and unknown statuses", async () => {
    for (const status of [undefined, "unexpected"]) {
      const element = await CloudBillingReturnPage({
        searchParams: Promise.resolve({ status }),
      });
      const html = renderToStaticMarkup(element);

      expect(html).toContain('data-billing-status="default"');
      expect(html).toContain("Billing complete");
    }
  });

  test("renders Japanese copy for Japanese browsers", async () => {
    acceptLanguage = "ja-JP,ja;q=0.9,en;q=0.8";
    try {
      const element = await CloudBillingReturnPage({
        searchParams: Promise.resolve({ status: "portal-return" }),
      });
      const html = renderToStaticMarkup(element);

      expect(html).toContain('lang="ja"');
      expect(html).toContain("請求ポータルから戻りました");
      expect(html).toContain("ターミナルに戻る");
    } finally {
      acceptLanguage = "en";
    }
  });

  test("honors quality weights, exclusions, and every supported locale catalog", async () => {
    const cases = [
      {
        accepted: "en-US,en;q=0.9,ja;q=0.8",
        locale: "en",
        title: "Back from the billing portal",
      },
      {
        accepted: "ja;q=0,en;q=0.5",
        locale: "en",
        title: "Back from the billing portal",
      },
      {
        accepted: "de-DE,de;q=0.9,en;q=0.8",
        locale: "de",
        title: "Zurück vom Abrechnungsportal",
      },
      {
        accepted: "zh-TW,zh;q=0.9,en;q=0.8",
        locale: "zh-TW",
        title: "已從帳單入口網站返回",
      },
    ] as const;

    try {
      for (const testCase of cases) {
        acceptLanguage = testCase.accepted;
        const element = await CloudBillingReturnPage({
          searchParams: Promise.resolve({ status: "portal-return" }),
        });
        const html = renderToStaticMarkup(element);

        expect(html).toContain(`lang="${testCase.locale}"`);
        expect(html).toContain(testCase.title);
      }
    } finally {
      acceptLanguage = "en";
    }
  });

  test("uses status-specific metadata and keeps return pages out of search", async () => {
    expect(
      await generateMetadata({
        searchParams: Promise.resolve({ status: "checkout-success" }),
      }),
    ).toEqual({
      title: "Checkout complete",
      robots: { index: false, follow: false },
    });
  });

  test("bypasses locale rewriting for the fixed Stripe return path", () => {
    for (const path of [
      "/cloud/billing?status=checkout-success",
      "/cloud/billing/?status=portal-return",
    ]) {
      const response = middleware(new NextRequest(`https://cmux.com${path}`));
      expect(response.headers.get("x-middleware-rewrite")).toBeNull();
      expect(response.headers.get("x-middleware-next")).toBe("1");
    }
  });
});
