import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeSubscriptions } from "../db/schema";
import enMessages from "../messages/en.json";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";

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

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => withAccountMutationLeaseSupport({
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

  test("defaults public pricing to annual billing with compact paid-plan CTAs", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain("/api/billing/portal");
    expect(html).not.toContain("Manage billing");
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).not.toContain("/mo.");
    expect(html).toContain("$28/user/mo");
    expect(html).toContain(
      "/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;interval=year",
    );
    expect(html).toContain(
      "/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;interval=year",
    );
    expect(html).toMatch(
      /href="\/api\/billing\/checkout\?plan=pro[^"]*interval=year"[^>]*class="[^"]*px-3 py-1\.5 text-xs[^"]*"[^>]*><span>Get Pro/,
    );
    expect(html).toMatch(
      /href="\/api\/billing\/checkout\?plan=team[^"]*interval=year"[^>]*class="[^"]*px-3 py-1\.5 text-xs[^"]*"[^>]*><span>Get Teams/,
    );
    expect(html).toContain('<p class="mt-5 text-sm font-medium">Includes:</p>');
    expect(html).not.toContain('style="min-height:4rem"');
    expect(html).toContain("text-3xl font-medium tabular-nums tracking-tight");
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

  test("renders the annual price and sends annual checkout intent", async () => {
    const element = await PricingPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({ interval: "year" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("$24");
    expect(html).toContain("/mo");
    expect(html).toContain("$24/mo");
    expect(html).toContain("$28");
    expect(html).toContain("/user/mo");
    expect(html).toContain("/mo, billed yearly");
    expect(html).toContain("/user/mo, billed yearly");
    expect(html).toContain("$28/user/mo");
    expect(html).not.toContain("$288/year");
    expect(html).not.toContain("$336/user/year");
    expect(html).not.toContain("Billed $288 annually · save 20%");
    expect(html).not.toContain("Billed $336 annually · save 20%");
    expect(html).toContain(
      "/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;interval=year",
    );
    expect(html).toContain(
      "/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;interval=year",
    );
    expect(html).toContain('role="radiogroup"');
    expect(html).toContain('<button type="button" role="radio" aria-checked="true"');
    expect(html).not.toContain('href="?interval=');
    expect(html).toContain("mx-auto mt-6 flex w-fit");
  });

  test("honors an explicit monthly billing interval", async () => {
    const element = await PricingPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({ interval: "month" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("$30");
    expect(html).toContain("$35");
    expect(html).toContain(
      "/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;interval=month",
    );
    expect(html).toContain(
      "/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;interval=month",
    );
    expect(html).toContain(
      '<button type="button" role="radio" aria-checked="true" tabindex="0" class="bg-foreground px-3 py-1.5 font-medium text-background">Monthly</button>',
    );
  });
});

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
  t.raw = (key: string) => valueAtPath(root, key);
  t.rich = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
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

function interpolate(message: string, values?: Record<string, unknown>) {
  if (!values) return message;
  return Object.entries(values).reduce(
    (result, [key, value]) => result.replaceAll(`{${key}}`, String(value)),
    message,
  );
}
