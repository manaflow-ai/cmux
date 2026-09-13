import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeSubscriptions } from "../db/schema";
import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { fallbackContentLocales } from "../i18n/locale-availability";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";

const nextServer = { ...await import("next/server") };
mock.module("next/server", () => ({ ...nextServer, connection: async () => undefined }));

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

const nextNavigationMock = createNextNavigationMock(redirect);

mock.module("next/navigation", () => nextNavigationMock);
mock.module("next/headers", () => ({ headers: async () => new Headers() }));

// The pricing page uses the locale-aware Link returned by createNavigation.
// Bun module mocks are process-global, so mock the package's complete export
// surface and return every navigation function our shared wrapper exposes.
mock.module("next-intl/navigation", () => ({
  createNavigation: () => ({
    Link: (props: React.ComponentProps<"a">) => <a {...props} />,
    redirect: nextNavigationMock.redirect,
    usePathname: nextNavigationMock.usePathname,
    useRouter: nextNavigationMock.useRouter,
    getPathname: ({ href }: { href: string }) => href,
  }),
}));

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

// PricingPage uses the locale-aware Link for the billing-recovery route. Keep
// this server-render test independent of next-intl's client navigation
// context, just like the other page tests that render locale-aware links.
mock.module("../i18n/navigation", () => ({
  Link: ({ href, children, ...props }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
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
        where: () => Object.assign(Promise.resolve(table === stripeSubscriptions ? stripeSubscriptionRows : []), {
          limit: async () => (table === stripeSubscriptions ? stripeSubscriptionRows : []),
        }),
      }),
    }),
  }),
}));

const { default: PricingPage } = await import("../app/[locale]/pricing/page");

describe("localized pricing page", () => {
  test("hides Go and all annual offers when the Go rollout is disabled", async () => {
    const previous = process.env.CMUX_TEST_GO_PLAN_DISABLED;
    process.env.CMUX_TEST_GO_PLAN_DISABLED = "1";
    try {
      const html = renderToStaticMarkup(await PricingPage({ params: Promise.resolve({ locale: "en" }) }));
      expect(html).toContain("Get Pro");
      expect(html).toContain("Get Max");
      expect(html).not.toContain("Get Go");
      expect(html).not.toContain("$10");
      expect(html).not.toContain("Save 20%");
      expect(html).not.toContain("interval=year");
      expect(html).toContain("25% repeat(5,15%)");
    } finally {
      if (previous === undefined) delete process.env.CMUX_TEST_GO_PLAN_DISABLED;
      else process.env.CMUX_TEST_GO_PLAN_DISABLED = previous;
    }
  });

  test("shows monthly prices only even for old annual pricing links", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }), searchParams: Promise.resolve({ interval: "year" }) });
    const html = renderToStaticMarkup(element);
    expect(html).toContain("$50");
    expect(html).toContain("$200");
    expect(html).not.toContain('role="radiogroup"');
    expect(html).not.toContain("Save 20%");
    expect(html).not.toContain("interval=year");
    expect(html).not.toContain("billed annually");
  });

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
      go: "true",
      free: "false",
      pro: "true",
      max: "true",
      team: "true",
      enterprise: "true",
    });
    expect(
      enMessages.pricing.compare.rows.find(
        (row) => row.label === "Concurrent Cloud VMs",
      ),
    ).toEqual({
      label: "Concurrent Cloud VMs",
      go: "1",
      free: "false",
      pro: "50",
      max: "50",
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

  test("shows the Founder's Edition recovery link once, after every card and before comparison", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);
    const recoveryIndex = html.indexOf('href="/billing/recover"');
    expect(html.match(/href="\/billing\/recover"/g)).toHaveLength(1);
    for (const plan of ["free", "pro", "max", "team", "enterprise"] as const) {
      const lastFeature = enMessages.pricing[plan].features.at(-1)!;
      const featureIndex = html.indexOf(lastFeature);
      expect(featureIndex).toBeGreaterThan(-1);
      expect(recoveryIndex).toBeGreaterThan(featureIndex);
    }
    const comparisonIndex = html.indexOf("<table");
    expect(comparisonIndex).toBeGreaterThan(-1);
    expect(recoveryIndex).toBeLessThan(comparisonIndex);
    expect(html).toContain("Already paid? Connect Founder&#x27;s Edition");
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

  test("defaults public pricing to monthly billing with full-size paid-plan CTAs", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).not.toContain("/api/billing/portal");
    expect(html).not.toContain("Manage billing");
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).toContain("$60/user/mo");
    expect(html).toContain(
      "/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;interval=month&amp;cmux_placement=pricing_page",
    );
    expect(html).toContain(
      "/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;interval=month&amp;cmux_placement=pricing_page",
    );
    expect(html).toMatch(
      /href="\/api\/billing\/checkout\?plan=pro[^"]*interval=month[^"]*"[^>]*class="[^"]*min-h-12 px-5 py-3 text-\[15px\][^"]*"[^>]*><span>Get Pro/,
    );
    expect(html).toMatch(
      /href="\/api\/billing\/checkout\?plan=team[^"]*interval=month[^"]*"[^>]*class="[^"]*min-h-12 px-5 py-3 text-\[15px\][^"]*"[^>]*><span>Get Teams/,
    );
    expect(html).toMatch(
      /href="\/api\/billing\/checkout\?plan=max[^"]*"[^>]*class="[^"]*min-h-12 px-5 py-3 text-\[15px\][^"]*"[^>]*><span>Get Max/,
    );
    expect(html).toContain('<p class="mt-5 text-sm font-medium">Includes:</p>');
    expect(html).not.toContain('style="min-height:4rem"');
    expect(html).toContain("text-3xl font-medium tabular-nums tracking-tight");
    expect(html).not.toContain("CodeRouter");
    expect(html).not.toContain("Subrouter");
    expect(html).not.toContain("cmux Vault");
  });

  test("sells Max at $200/mo on a monthly-only checkout link, between Pro and Team", async () => {
    const element = await PricingPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({ interval: "year" }),
    });
    const html = renderToStaticMarkup(element);

    // The annual selector must not touch Max: no interval on its checkout
    // link and no "billed yearly" label on its card or table column.
    expect(html).toContain(
      "/api/billing/checkout?plan=max&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;cmux_placement=pricing_page",
    );
    expect(html).toContain(
      "/api/billing/checkout?plan=max&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;cmux_placement=pricing_compare_header",
    );
    expect(html).not.toMatch(/plan=max[^"]*interval=/);
    expect(html.split("api/billing/checkout?plan=max")).toHaveLength(3);
    expect(html).toContain("$200");
    expect(html).toContain("$200 /mo");
    expect(html).not.toContain("$200/mo, billed yearly");
    expect(html).toContain("Up to 64 GB RAM per machine");
    expect(html).toContain("Get Go");
    expect(html).toContain("2 vCPU, 4 GiB RAM, and 16 GiB disk");
    expect(html).toContain("For individuals");
    expect(html).toContain("For teams and businesses");
    expect(html).toContain("Largest Cloud VM");
    expect(html).toContain("What does Max add?");
    expect(html).toContain("md:grid-cols-2 lg:grid-cols-4");
    const proIndex = html.indexOf("<span>Get Pro");
    const maxIndex = html.indexOf("<span>Get Max");
    const teamIndex = html.indexOf("<span>Get Teams");
    expect(proIndex).toBeGreaterThan(-1);
    expect(maxIndex).toBeGreaterThan(proIndex);
    expect(teamIndex).toBeGreaterThan(maxIndex);
    // Six plan columns include Go.
    expect(html).toContain("25% repeat(6,12.5%)");
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
    stripeSubscriptionRows = [{ id: "sub_123", plan: "pro" }];

    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).toContain('href="/api/billing/portal"');
    expect(html).toContain("Manage billing");
    expect(html).toContain("Current plan");
    // A Pro subscriber can still upgrade: the Max card keeps its checkout
    // link (the server routes an active Pro subscription to the portal).
    expect(html).toContain("/api/billing/checkout?plan=max");
    expect(html).toMatch(/plan=max[^"]*"[^>]*><span>Get Max/);
  });

  test("renders monthly offers for an old annual link", async () => {
    const element = await PricingPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({ interval: "year" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("$50");
    expect(html).toContain("/mo");
    expect(html).toContain("$50/mo");
    expect(html).toContain("$60");
    expect(html).toContain("/user/mo");
    expect(html).not.toContain("/mo, billed yearly");
    expect(html).not.toContain("/user/mo, billed yearly");
    expect(html).toContain("$60/user/mo");
    expect(html).not.toContain("$480/year");
    expect(html).not.toContain("$576/user/year");
    expect(html).not.toContain("$24");
    expect(html).not.toContain("$28");
    expect(html).toContain(
      "/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;interval=month&amp;cmux_placement=pricing_page",
    );
    expect(html).toContain(
      "/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;interval=month&amp;cmux_placement=pricing_page",
    );
    expect(html).toContain('role="tablist"');
    expect(html).toMatch(/<button[^>]*role="tab"[^>]*aria-selected="true"/);
    expect(html).not.toContain('href="?interval=');
    expect(html).toContain('data-testid="pricing-controls"');
  });

  test("forwards an inbound source and campaign tags to checkout", async () => {
    const element = await PricingPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({
        interval: "month",
        cmux_source: "cli_free_access_expiry",
        cmux_client: "cli",
        utm_source: "newsletter",
        utm_campaign: "sept",
      }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain(
      "/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_source=cli_free_access_expiry&amp;cmux_client=cli&amp;utm_source=newsletter&amp;utm_campaign=sept&amp;interval=month&amp;cmux_placement=pricing_page",
    );
    expect(html).not.toContain("cmux_source=pricing_page");
  });

  test("honors an explicit monthly billing interval", async () => {
    const element = await PricingPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({ interval: "month" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("$50");
    expect(html).toContain("$60");
    expect(html).toContain(
      "Up to 50 Cloud VMs, with 24 GB RAM and 6 vCPUs shared across all VMs",
    );
    expect(html).toContain("Unlimited workspaces");
    expect(html).not.toContain("Unlimited active Cloud VMs");
    expect(html).toContain(
      "/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;interval=month&amp;cmux_placement=pricing_page",
    );
    expect(html).toContain(
      "/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;cmux_source=pricing_page&amp;interval=month&amp;cmux_placement=pricing_page",
    );
    expect(html).toMatch(/<button[^>]*role="tab"[^>]*aria-selected="true"/);
  });

  test("shows individual plans first and includes the team audience view", async () => {
    const element = await PricingPage({ params: Promise.resolve({ locale: "en" }) });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("Individual");
    expect(html).toContain("Team &amp; Enterprise");
    expect(html).toContain('aria-selected="true"');
    expect(html).toContain('hidden=""');
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
