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
  test("renders a Manage billing link after an active purchase", async () => {
    const element = await BillingSuccessPage({
      searchParams: Promise.resolve({ session_id: "cs_123" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain('href="/api/billing/portal"');
    expect(html).toContain("Manage billing");
    expect(html).toContain("Open cmux");
    expect(redirect).not.toHaveBeenCalled();
    expect(retrieveSession).toHaveBeenCalledWith("cs_123", {
      expand: ["subscription", "customer"],
    });
  });
});
