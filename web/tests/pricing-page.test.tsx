import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeSubscriptions } from "../db/schema";
import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { fallbackContentLocales } from "../i18n/locale-availability";
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
const originalVaultEnabled = process.env.CMUX_VAULT_ENABLED;

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
  test("publishes pricing only in its fully authored English and Japanese catalogs", () => {
    expect(fallbackContentLocales).toEqual(["en", "ja"]);
  });

  test("keeps paid-plan copy flat: no metering, trials, or CodeRouter", () => {
    expect(enMessages.pricing.team.features).toEqual([
      "Centralized billing for your whole team",
      "Priority support",
    ]);
    expect(jaMessages.pricing.team.features).toEqual([
      "チーム全体の一元請求",
      "優先サポート",
    ]);
    expect(
      enMessages.pricing.compare.rows.find(
        (row) => row.label === "Cloud agents on Cloud VMs",
      ),
    ).toEqual({
      label: "Cloud agents on Cloud VMs",
      free: "false",
      pro: "true",
      team: "true",
      enterprise: "true",
    });
    expect(
      enMessages.pricing.compare.rows.find(
        (row) => row.label === "Concurrent Cloud VMs",
      ),
    ).toEqual({
      label: "Concurrent Cloud VMs",
      free: "false",
      pro: "50",
      team: "50 per user",
      enterprise: "Custom",
    });
    expect(enMessages.dashboard.billing.free.upsellTitle).toBe(
      "Upgrade when you need cloud agents.",
    );
    for (const catalog of [enMessages.pricing, jaMessages.pricing]) {
      const flat = JSON.stringify(catalog);
      expect(flat).not.toContain("CodeRouter");
      expect(flat).not.toContain("compute-hour");
      expect(flat).not.toContain("usage-based");
      expect(flat).not.toContain("trial");
      expect(flat).not.toContain("トライアル");
      expect(flat).not.toContain("アクティブ計算時間");
      expect(flat).not.toContain("コンピュート時間");
      expect("sizes" in catalog).toBe(false);
    }
  });

  beforeEach(() => {
    process.env.CMUX_VAULT_ENABLED = "0";
    stackConfigured = false;
    stripeSubscriptionRows = [];
    getUser.mockClear();
    proUser.update.mockClear();
  });

  afterEach(() => {
    if (originalVaultEnabled === undefined) {
      delete process.env.CMUX_VAULT_ENABLED;
    } else {
      process.env.CMUX_VAULT_ENABLED = originalVaultEnabled;
    }
  });

  test("defaults public pricing to annual billing with compact paid-plan CTAs", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain("/api/billing/portal");
    expect(html).not.toContain("Manage billing");
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).not.toContain("/mo.");
    expect(html).toContain("$48/user/mo");
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
    expect(html).not.toContain("CodeRouter");
    expect(html).not.toContain("Subrouter");
    expect(html).not.toContain("cmux Vault");
  });

  test("only advertises Vault when its release flag is enabled", async () => {
    process.env.CMUX_VAULT_ENABLED = "1";

    const element = await PricingPage({
      params: Promise.resolve({ locale: "en" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("cmux Vault");
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

    expect(html).toContain("$40");
    expect(html).toContain("/mo");
    expect(html).toContain("$40/mo");
    expect(html).toContain("$48");
    expect(html).toContain("/user/mo");
    expect(html).toContain("/mo, billed yearly");
    expect(html).toContain("/user/mo, billed yearly");
    expect(html).toContain("$48/user/mo");
    expect(html).not.toContain("$480/year");
    expect(html).not.toContain("$576/user/year");
    expect(html).not.toContain("$24");
    expect(html).not.toContain("$28");
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

    expect(html).toContain("$50");
    expect(html).toContain("$60");
    expect(html).toContain("Up to 50 Cloud VMs, each with 5 vCPU, 20 GB RAM, and 200 GB disk");
    expect(html).toContain("Unlimited workspaces");
    expect(html).not.toContain("Unlimited active Cloud VMs");
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
