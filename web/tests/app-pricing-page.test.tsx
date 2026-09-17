import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToReadableStream } from "react-dom/server";
import { renderSettled } from "./helpers/render-settled";
import { readInitialMain } from "./helpers/render-stream";

import { stripeSubscriptions } from "../db/schema";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";

const nextServer = { ...await import("next/server") };
mock.module("next/server", () => ({ ...nextServer, connection: async () => undefined }));

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

const getUser = mock(async () => currentUser);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser: async () => currentUser } : null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => withAccountMutationLeaseSupport({
    select: () => ({
      from: (table: unknown) => ({
        where: () => Object.assign(Promise.resolve(table === stripeSubscriptions ? stripeSubscriptionRows : []), {
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
      renderSettled(AppPricingPage({ searchParams: Promise.resolve({}) })),
    ).rejects.toMatchObject({ href: "/pricing" });
  });

  test("renders embedded pricing with checkout links carrying the validated scheme", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = (await renderSettled(element));

    expect(html).toContain("/handler/native-sign-in?after_auth_return_to=");
    expect(html).toContain("plan%253Dpro");
    expect(html).toContain("plan%253Dteam");
    expect(html).toContain("plan%253Dmax");
    expect(html).not.toMatch(/plan=max[^"]*interval=/);
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).toContain("$50");
    expect(html).toContain("$200");
    expect(html).toContain("$10");
    expect(html).toContain("Get Go");
    expect(html).toContain("For individuals");
    expect(html).toContain("For teams and businesses");
    expect(html).toContain("Get Max");
    expect(html).toContain("Up to 64 GB RAM per machine");
    expect(html).toContain("Largest Cloud VM");
    expect(html).toContain("$60/user/mo");
    expect(html).toContain(
      "Up to 50 Cloud VMs, with 24 GB RAM and 6 vCPUs shared across all VMs",
    );
    expect(html).toContain('<p class="mt-5 text-sm font-medium">Includes:</p>');
    expect(html).not.toContain('style="min-height:4rem"');
    expect(html).toContain("text-3xl font-medium tabular-nums tracking-tight");
    expect(html).toContain("md:grid-cols-2 lg:grid-cols-4");
    expect(html).toContain("$10");
    expect(html).toContain("Get Go");
    expect(html).toContain("For individuals");
    expect(html).toContain("For teams and businesses");
    expect(html).toContain("plan%253Dpro");
    expect(html).toContain("plan%253Dmax");
    expect(html).toContain("plan%253Dteam");
    expect(html).toContain("Compare plans");
    expect(html).not.toContain("/api/billing/portal");
  });

  test("streams prices before account state and keeps App Store fallback purchase-free", async () => {
    stackConfigured = true;
    let release!: () => void;
    const pending = new Promise<unknown>((resolve) => { release = () => resolve(null); });
    getUser.mockImplementation(() => pending);
    const stream = await renderToReadableStream(AppPricingPage({
      searchParams: Promise.resolve({ cmux_app: "1", cmux_distribution: "appstore" }),
    }));
    const reader = stream.getReader();
    try {
      const first = await readInitialMain(reader);
      expect(first.includes("$50") && first.includes("$200")).toBe(true);
      expect(first.includes("animate-pulse")).toBe(false);
      expect(first.includes("/api/billing/checkout")).toBe(false);
      expect(first.includes("/api/billing/portal")).toBe(false);
    } finally {
      release();
      while (!(await reader.read()).done) { /* Drain the completed response. */ }
      getUser.mockImplementation(async () => currentUser);
    }
  });

  test("forwards the Mac app's checkout attribution to every checkout link", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
        cmux_source: "mac_help_menu",
        cmux_client: "mac",
        cmux_channel: "nightly",
        cmux_app_version: "0.65.1",
        cmux_app_build: "2026090101",
      }),
    });
    const html = (await renderSettled(element));

    expect(html).toContain("plan%253Dpro");
    expect(html).toContain("plan%253Dteam");
    expect(html).toContain("cmux_source%253Dmac_help_menu");
    expect(html).toContain("cmux_app_build%253D2026090101");
  });

  test("renders signed-out recovery without claiming Free is the current plan", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
        appearance: "dark",
        background: "#112233",
        interval: "year",
      }),
    });
    const html = (await renderSettled(element)).replaceAll("&amp;", "&");

    expect(html).toContain("not signed in.");
    expect(html).not.toContain("Current plan");
    const signInHref = html.match(
      /href="(\/handler\/native-sign-in\?after_auth_return_to=[^"]+)"/,
    )?.[1];
    expect(signInHref).toBeTruthy();
    const nativeSignIn = new URL(signInHref!, "https://cmux.test");
    const afterSignIn = new URL(
      nativeSignIn.searchParams.get("after_auth_return_to")!,
      "https://cmux.test",
    );
    expect(afterSignIn.searchParams.get("native_app_return_to")).toBe(
      "cmux-dev-test://auth-callback",
    );
    expect(afterSignIn.searchParams.get("web_return_to")).toBe(
      "/app-pricing?cmux_app=1&cmux_scheme=cmux-dev-test&appearance=dark&background=%23112233&interval=year",
    );
  });

  test("renders monthly pricing and preserves native checkout context", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
        appearance: "dark",
        background: "#112233",
        foreground: "#ddeeff",
        accent: "#0091ff",
        interval: "year",
      }),
    });
    const html = (await renderSettled(element));

    expect(html).toContain("$50");
    expect(html).toContain("$60");
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).not.toContain("/mo, billed yearly");
    expect(html).not.toContain("/user/mo, billed yearly");
    expect(html).not.toContain("$24");
    expect(html).not.toContain("$28");
    expect(html).toContain("$60/user/mo");
    expect(html).not.toContain("$480/year");
    expect(html).not.toContain("$576/user/year");
    // Max ignores the annual selector: still $200 /mo, never billed yearly.
    expect(html).toContain("$200");
    expect(html).toContain("$200 /mo");
    expect(html).not.toContain("$200/mo, billed yearly");
    expect(html).not.toMatch(/plan=max[^"]*interval=/);
    expect(html).toContain("plan%253Dpro");
    expect(html).toContain("plan%253Dteam");
    expect(html).not.toContain('role="radiogroup"');
    expect(html).not.toContain('<button type="button" role="radio" aria-checked="true"');
    expect(html).not.toContain("appearance=dark&amp;interval=month");
    expect(html).toContain('data-cmux-app-theme="true"');
    expect(html).toContain("--ghostty-background:#112233");
    expect(html).toContain("--ghostty-foreground:#ddeeff");
    expect(html).toContain("--cmux-product-blue:#0091ff");
    expect(html).toContain("--cmux-product-blue-on-background:#0091ff");
    expect(html).toContain("--cmux-product-blue-on-foreground:#006CBF");
    expect(html).toContain('data-testid="pricing-controls"');
    expect(html).not.toContain("Save 20%");
    expect(html).toContain('href="/enterprise?cmux_external_browser=1"');
  });

  test("does not advertise annual savings", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
        interval: "month",
      }),
    });
    const html = (await renderSettled(element));

    expect(html).not.toContain("Save 20%");
  });

  test("removes external purchase links in App Store distribution mode", async () => {
    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_distribution: "appstore",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = (await renderSettled(element));

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
    const html = (await renderSettled(element));

    expect(html).not.toContain('href="/api/billing/portal"');
    expect(html).toContain(
      "http://localhost:9210/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_scheme=cmux-dev-test",
    );
    expect(html).toContain("Current plan");
    expect(html).not.toContain("not signed in.");
  });

  test("hides the billing portal link for Pro users in App Store distribution mode", async () => {
    stackConfigured = true;
    currentUser = proUser;
    stripeSubscriptionRows = [{ id: "sub_123", plan: "pro" }];

    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_distribution: "appstore",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = (await renderSettled(element));

    // Apple 3.1.1: no external billing/purchase links inside App Store builds.
    expect(html).not.toContain("/api/billing/portal");
    expect(html).toContain("Current plan");
  });

  test("renders Manage billing for Stripe-managed Pro users", async () => {
    stackConfigured = true;
    currentUser = proUser;
    stripeSubscriptionRows = [{ id: "sub_123", plan: "pro" }];

    const element = await AppPricingPage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        cmux_scheme: "cmux-dev-test",
      }),
    });
    const html = (await renderSettled(element));

    expect(html).toContain('href="/api/billing/portal"');
    expect(html).toContain("Manage billing");
    expect(html).toContain("Current plan");
    const card = Array.from(html.matchAll(/aria-labelledby="individual-pricing-category"[\s\S]*?<\/section>/g), (match) => match[0]).find((section) => section.includes("Manage billing")) ?? "";
    expect(card.match(/Current plan/g)).toHaveLength(1);
    expect(card.includes("Manage billing")).toBe(true);
    // A Pro subscriber can still upgrade to Max from the app.
    expect(html).toContain("api/billing/portal?flow=switch_plan&amp;plan=max");
    expect(html).toContain("Get Max");
  });

  for (const [name, params, message] of [
    ["welcomeTeam", { welcome: "team" }, "Your cmux Team purchase is complete."],
    ["billingCancelled", { billing: "cancelled" }, "Checkout cancelled. You have not been charged."],
    ["billingInvalidPlan", { billing: "invalid_plan" }, "That plan is not available. Pick a plan below."],
    ["billingInvalidRelay", { billing: "invalid_relay" }, "The app checkout link expired or could not be verified. Return to cmux and try again."],
  ] as const) {
    test(`renders ${name} banner state`, async () => {
      const element = await AppPricingPage({
        searchParams: Promise.resolve({
          cmux_app: "1",
          ...params,
        }),
      });
      const html = (await renderSettled(element));

      expect(html).toContain(message);
    });
  }
});
