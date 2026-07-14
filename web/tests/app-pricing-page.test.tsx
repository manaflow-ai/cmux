import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeSubscriptions } from "../db/schema";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});

// bun's mock.module replaces these modules process-wide. Keep the shared
// export set complete so this file cannot break an unrelated suite.
mock.module("next/navigation", () => createNextNavigationMock(redirect));

mock.module("next/headers", () => ({
  headers: async () =>
    new Headers({
      host: "localhost:9210",
    }),
  cookies: async () => ({
    get: () => undefined,
    getAll: () => [],
    has: () => false,
  }),
  draftMode: async () => ({ isEnabled: false }),
}));

let stackConfigured = false;
let currentUser: unknown = null;
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];

const proUser = {
  id: "user-pro",
  isAnonymous: false,
  primaryEmail: "pro@example.com",
  clientReadOnlyMetadata: { cmuxPlan: "pro" },
  update: mock(async () => undefined),
};

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser: async () => currentUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser: async () => currentUser } : null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => ({
    select: () => ({
      from: (table: unknown) => ({
        where: () => ({
          limit: async () => (table === stripeSubscriptions ? stripeSubscriptionRows : []),
        }),
      }),
    }),
  }),
}));

const { default: AppPricingPage } = await import("../app/app-pricing/page");

describe("app pricing page", () => {
  beforeEach(() => {
    redirect.mockClear();
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = "cmux-dev-test";
    stackConfigured = false;
    currentUser = null;
    stripeSubscriptionRows = [];
    proUser.update.mockClear();
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
    expect(html).not.toContain("/api/billing/portal");
  });

  test("removes external purchase links in App Store distribution mode", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_distribution: "appstore",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain("/api/billing/checkout");
    expect(html).not.toContain("checkout.stripe.com");
    expect(html).not.toContain("/api/billing/portal");
    expect(html).toContain("Billing is not available right now. Please try again later.");
  });

  test("renders Stack metadata-only Pro users as Free", async () => {
    stackConfigured = true;
    currentUser = proUser;

    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain('href="/api/billing/portal"');
    expect(html).toContain(
      "http://localhost:9210/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_scheme=cmux-dev-test",
    );
  });

  test("hides the billing portal link for Pro users in App Store distribution mode", async () => {
    stackConfigured = true;
    currentUser = proUser;
    stripeSubscriptionRows = [{ id: "sub_123" }];

    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_distribution: "appstore",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = renderToStaticMarkup(element);

    // Apple 3.1.1: no external billing/purchase links inside App Store builds.
    expect(html).not.toContain("/api/billing/portal");
    expect(html).toContain("Current plan");
  });

  test("renders Manage billing for Stripe-managed Pro users", async () => {
    stackConfigured = true;
    currentUser = proUser;
    stripeSubscriptionRows = [{ id: "sub_123" }];

    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain('href="/api/billing/portal"');
    expect(html).toContain("Manage billing");
    expect(html).toContain("Current plan");
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
