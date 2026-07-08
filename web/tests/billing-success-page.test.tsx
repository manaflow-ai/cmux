import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

const purchaseModule = await import("../services/billing/purchase");
const stripeModule = await import("../services/billing/stripe");

const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});

const retrieveSession = mock(async () => ({
  customer_details: { email: "buyer@example.com" },
  subscription: { status: "active" },
}));

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
      "accept-language": "en",
      host: "cmux.test",
      "x-forwarded-proto": "https",
    }),
  cookies: async () => ({
    get: () => undefined,
    getAll: () => [],
    has: () => false,
  }),
  draftMode: async () => ({ isEnabled: false }),
}));

mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  isStripeBillingConfigured: () => true,
  stripe: () => ({
    checkout: {
      sessions: {
        retrieve: retrieveSession,
      },
    },
  }),
}));

mock.module("../services/billing/purchase", () => ({
  ...purchaseModule,
  latestStripeSubscriptionForSession: mock(async () => null),
}));

const { default: BillingSuccessPage } = await import("../app/billing/success/page");

describe("billing success page", () => {
  test("renders welcome sections and links after an active purchase", async () => {
    const element = await BillingSuccessPage({
      searchParams: Promise.resolve({ session_id: "cs_123" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("cmux Pro is active");
    expect(html).toContain("buyer@example.com");
    expect(html).toContain("What you unlocked");
    expect(html).toContain("Cloud agents on Cloud VMs");
    expect(html).toContain("Run agents in isolated remote sandboxes.");
    expect(html).toContain("Model gateway");
    expect(html).toContain("Route across providers with usage and cost analytics, plus 20 compute-hours a month.");
    expect(html).toContain("Connect your AI accounts");
    expect(html).toContain("Add provider accounts so cmux can route work through them.");
    expect(html).toContain("cmux iOS app");
    expect(html).toContain("Use cmux on your phone.");
    expect(html).toContain('href="https://cmux.test/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback"');
    expect(html).toContain('href="/dashboard/subrouter"');
    expect(html).toContain('href="/dashboard/ai-accounts"');
    expect(html).toContain('href="/dashboard/testflight"');
    expect(html).toContain('href="/api/billing/portal"');
    expect(html).toContain('href="/handler/account-settings"');
    expect(html).toContain("Manage billing");
    expect(html).toContain("Open cmux");
    expect(html).toContain("Manage sign-in methods");
    expect(redirect).not.toHaveBeenCalled();
    expect(retrieveSession).toHaveBeenCalledWith("cs_123", {
      expand: ["subscription", "customer"],
    });
  });
});
