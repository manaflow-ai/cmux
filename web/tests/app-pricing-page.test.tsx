import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeSubscriptions } from "../db/schema";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});

// bun's mock.module replaces these modules process-wide, so each mock must
// carry every export another test in the suite might import.
mock.module("next/navigation", () => ({
  redirect,
  notFound: () => {
    throw new Error("notFound");
  },
  permanentRedirect: redirect,
}));

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
  listProducts: mock(async () =>
    Object.assign(
      [
        {
          id: "pro",
          quantity: 1,
          subscription: {
            cancelAtPeriodEnd: false,
            currentPeriodEnd: null,
          },
        },
      ],
      { nextCursor: null },
    ),
  ),
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
    proUser.listProducts.mockClear();
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

  test("renders the external billing note without a portal link for Stack Pro users", async () => {
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
      "Your subscription is managed by our previous billing system. Contact support to make changes.",
    );
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
