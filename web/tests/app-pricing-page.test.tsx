import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});

mock.module("next/navigation", () => ({
  redirect,
}));

mock.module("next/headers", () => ({
  headers: async () =>
    new Headers({
      host: "localhost:9210",
    }),
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser: async () => null }),
  isStackConfigured: () => false,
}));

const { default: AppPricingPage } = await import("../app/app-pricing/page");

describe("app pricing page", () => {
  beforeEach(() => {
    redirect.mockClear();
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = "cmux-dev-test";
  });

  test("redirects to public pricing outside the cmux app", async () => {
    await expect(
      AppPricingPage({ searchParams: Promise.resolve({}) }),
    ).rejects.toMatchObject({ href: "/pricing" });
  });

  test("renders embedded pricing with checkout links carrying the validated scheme", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain(
      "http://localhost:9210/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_scheme=cmux-dev-test",
    );
    expect(html).toContain(
      "http://localhost:9210/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;cmux_scheme=cmux-dev-test",
    );
  });

  for (const [name, params, message] of [
    ["welcomeTeam", { welcome: "team" }, "Your cmux Team purchase is complete."],
    ["billingCancelled", { billing: "cancelled" }, "Checkout cancelled. You have not been charged."],
    ["billingInvalidPlan", { billing: "invalid_plan" }, "That plan is not available. Pick a plan below."],
  ] as const) {
    test(`renders ${name} banner state`, async () => {
      const element = await AppPricingPage({
        searchParams: Promise.resolve({
          cmux_app: "1",
          ...params,
        }),
      });
      const html = renderToStaticMarkup(element);

      expect(html).toContain(message);
    });
  }
});
