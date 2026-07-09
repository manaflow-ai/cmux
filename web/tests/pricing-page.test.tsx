import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeSubscriptions } from "../db/schema";
import enMessages from "../messages/en.json";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = false;
let proActive = false;
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];
const proUser = {
  id: "user-pro",
  isAnonymous: false,
  primaryEmail: "pro@example.com",
  clientReadOnlyMetadata: { cmuxPlan: "pro" },
  listProducts: mock(async () =>
    Object.assign(
      proActive
        ? [
            {
              id: "pro",
              quantity: 1,
              subscription: {
                cancelAtPeriodEnd: false,
                currentPeriodEnd: null,
              },
            },
          ]
        : [],
      { nextCursor: null },
    ),
  ),
  update: mock(async () => undefined),
};
const getUser = mock(async () => proUser);

mock.module("next-intl/server", () => ({
  getTranslations: async (namespace?: string | { namespace?: string }) =>
    translator(typeof namespace === "string" ? namespace : namespace?.namespace),
  setRequestLocale: () => undefined,
}));

mock.module("../app/[locale]/components/site-header", () => ({
  SiteHeader: () => <header />,
}));

mock.module("../app/[locale]/components/pro-welcome-banner", () => ({
  ProWelcomeBanner: () => null,
}));

mock.module("../app/[locale]/components/pro-cta-link", () => ({
  ProCtaLink: ({ checkoutHref, children }: { checkoutHref: string; children: React.ReactNode }) => (
    <a href={checkoutHref}>{children}</a>
  ),
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
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

const { default: PricingPage } = await import("../app/[locale]/pricing/page");

describe("localized pricing page", () => {
  beforeEach(() => {
    stackConfigured = false;
    proActive = false;
    stripeSubscriptionRows = [];
    getUser.mockClear();
    proUser.listProducts.mockClear();
    proUser.update.mockClear();
  });

  test("does not render Manage billing for non-Pro snapshots", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain("/api/billing/portal");
    expect(html).not.toContain("Manage billing");
  });

  test("renders the external billing note without a portal link for Stack Pro snapshots", async () => {
    stackConfigured = true;
    proActive = true;

    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain('href="/api/billing/portal"');
    expect(html).toContain(
      "Your subscription is managed by our previous billing system. Contact support to make changes.",
    );
    expect(html).toContain("Current plan");
  });

  test("renders Manage billing for Stripe-managed Pro snapshots", async () => {
    stackConfigured = true;
    proActive = true;
    stripeSubscriptionRows = [{ id: "sub_123" }];

    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).toContain('href="/api/billing/portal"');
    expect(html).toContain("Manage billing");
    expect(html).toContain("Current plan");
  });
});

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string) => String(valueAtPath(root, key));
  t.raw = (key: string) => valueAtPath(root, key);
  t.rich = (key: string) => String(valueAtPath(root, key));
  return t;
}

function valueAtPath(root: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, part) => {
    if (value && typeof value === "object" && part in value) {
      return (value as Record<string, unknown>)[part];
    }
    return path;
  }, root);
}
