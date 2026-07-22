import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeSubscriptions } from "../db/schema";
import enMessages from "../messages/en.json";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = false;
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];
const proUser = {
  id: "user-pro",
  isAnonymous: false,
  primaryEmail: "pro@example.com",
  clientReadOnlyMetadata: { cmuxPlan: "pro" },
  update: mock(async () => undefined),
};
const getUser = mock(async () => proUser);
const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});

mock.module("next/navigation", () => createNextNavigationMock(redirect));

mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => "en",
  useTranslations: (namespace?: string) => translator(namespace),
}));

mock.module("next-intl/server", () => ({
  getTranslations: async (namespace?: string | { namespace?: string }) =>
    translator(typeof namespace === "string" ? namespace : namespace?.namespace),
  setRequestLocale: () => undefined,
}));

mock.module("../app/[locale]/components/site-header", () => ({
  SiteHeader: () => <header />,
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
    stripeSubscriptionRows = [];
    getUser.mockClear();
    proUser.update.mockClear();
  });

  test("does not render Manage billing for non-Pro snapshots", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain("/api/billing/portal");
    expect(html).not.toContain("Manage billing");
  });

  test("renders Stack metadata-only Pro snapshots as Free", async () => {
    stackConfigured = true;

    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain('href="/api/billing/portal"');
    // PRO_CHECKOUT_URL appends the external-browser intent param, so match the
    // path prefix rather than an exact href.
    expect(html).toContain("/api/billing/checkout?plan=pro");
  });

  test("renders Manage billing for Stripe-managed Pro snapshots", async () => {
    stackConfigured = true;
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
