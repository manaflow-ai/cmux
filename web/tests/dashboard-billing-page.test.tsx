import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeCustomers, stripeSubscriptions } from "../db/schema";
import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = true;
let currentUser: typeof proUser | null = null;
let subscriptionRows: Array<Record<string, unknown>> = [];
let subscriptionResults: Array<Array<Record<string, unknown>>> = [];
let customerRows: Array<Record<string, unknown>> = [];

const proUser = {
  id: "user-pro",
  isAnonymous: false,
  primaryEmail: "pro@example.com",
  clientReadOnlyMetadata: {},
  selectedTeam: null as null | { id: string; displayName?: string; clientReadOnlyMetadata?: unknown },
  listTeams: mock(async () => [] as Array<{ id: string; displayName?: string; clientReadOnlyMetadata?: unknown }>),
  update: mock(async () => undefined),
};

mock.module("next-intl/server", () => ({
  getTranslations: async (input?: string | { namespace?: string }) =>
    translator(typeof input === "string" ? input : input?.namespace),
  setRequestLocale: () => undefined,
}));

// AccountPlanBadge is a client component using the client `useTranslations`.
// Mock it here (like next-intl/server above) so the render is self-contained;
// depending on another file's leaked next-intl mock made CI's sorted test
// order fail while local readdir order passed. Export the full client surface
// the app imports (NextIntlClientProvider, useLocale, useTranslations) so this
// mock never shadows an export a later file's module evaluation needs — bun's
// mock.module is global and persists across files.
mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => "en",
  useTranslations: (namespace?: string) => translator(namespace),
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({ href, children, ...props }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
  redirect: () => undefined,
  usePathname: () => "/dashboard/billing",
  useRouter: () => ({}),
  getPathname: () => "/dashboard/billing",
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser: async () => currentUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser: async () => currentUser } : null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => withAccountMutationLeaseSupport({
    select: () => ({
      from: (table: unknown) => ({
        where: () => selectableResult(table),
      }),
    }),
  }),
}));

const { default: DashboardBillingPage } = await import("../app/[locale]/dashboard/billing/page");
const { DashboardQueryProvider } = await import("../app/[locale]/dashboard/components/query-provider");

describe("dashboard billing page", () => {
  beforeEach(() => {
    stackConfigured = true;
    currentUser = proUser;
    subscriptionRows = [];
    subscriptionResults = [];
    customerRows = [];
    proUser.clientReadOnlyMetadata = {};
    proUser.selectedTeam = null;
    proUser.listTeams.mockClear();
    mockImplementation(proUser.listTeams, async () => []);
    proUser.update.mockClear();
  });

  test("renders the Free plan state with pricing cards and TestFlight link", async () => {
    const html = await renderBillingPage();

    expect(html).toContain("Free");
    expect(html).toContain("You are currently on the Free plan.");
    expect(html).toContain(
      "Upgrade when you need cloud agents or shared CodeRouter.",
    );
    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;interval=month"',
    );
    expect(html).toContain(
      'href="/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;interval=month"',
    );
    expect(html).toContain("Get Pro");
    expect(html).toContain("Get Teams");
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).not.toContain("/mo.");
    expect(html).not.toContain('style="min-height:4rem"');
    expect(html).toContain("text-3xl font-medium tabular-nums tracking-tight");
    expect(html).toContain('href="/dashboard/testflight"');
    expect(html).toContain("Join the iOS beta");
    expect(html).toContain("active personal Pro subscribers");
    expect(html).not.toContain("/api/billing/subscription");
  });

  test("renders annual Pro and Team pricing from the billing upsell", async () => {
    const html = await renderBillingPage({ interval: "year" });

    expect(html).toContain("$24");
    expect(html).toContain("$28");
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).toContain("/mo, billed yearly");
    expect(html).toContain("/user/mo, billed yearly");
    expect(html).not.toContain("/mo.");
    expect(html).not.toContain("Billed $288 annually · save 20%");
    expect(html).not.toContain("Billed $336 annually · save 20%");
    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;interval=year"',
    );
    expect(html).toContain(
      'href="/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;interval=year"',
    );
  });

  test("renders active Stripe Pro with cancel and portal actions", async () => {
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: false })];
    customerRows = [{ id: "cus_123" }];

    const html = await renderBillingPage();

    expect(html).toContain("cmux Pro");
    expect(html).toContain("Your plan renews on");
    expect(html).toContain("$30/mo");
    expect(html).toContain("Cancel plan");
    expect(html).toContain('action="/api/billing/subscription"');
    expect(html).toContain('href="/api/billing/portal"');
  });

  test("labels new and grandfathered annual Stripe prices", async () => {
    subscriptionRows = [
      stripeSubscriptionRow({
        cancelAtPeriodEnd: false,
        lookupKey: "cmux-pro-yearly-288",
      }),
    ];
    customerRows = [{ id: "cus_123" }];
    expect(await renderBillingPage()).toContain("$24/mo, billed annually");

    subscriptionRows = [
      stripeSubscriptionRow({
        cancelAtPeriodEnd: false,
        lookupKey: "cmux-pro-yearly",
      }),
    ];
    expect(await renderBillingPage()).toContain("$20/mo, billed annually");
  });

  test("renders pending cancellation with resume and end-date copy", async () => {
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: true })];
    customerRows = [{ id: "cus_123" }];

    const html = await renderBillingPage();

    expect(html).toContain("Your plan is scheduled to end on");
    expect(html).toContain("Ends on");
    expect(html).toContain("Resume plan");
    expect(html).not.toContain("Confirm cancellation");
  });

  test("renders active Stripe Team with seats, cancel, and team portal actions", async () => {
    proUser.selectedTeam = { id: "team-pro", displayName: "Team Pro" };
    subscriptionResults = [
      [],
      [],
      [
        stripeSubscriptionRow({
          cancelAtPeriodEnd: false,
          plan: "team",
          scope: "team",
          seats: 4,
        }),
      ],
    ];
    customerRows = [{ id: "cus_team" }];

    const html = await renderBillingPage();

    expect(html).toContain("cmux Team");
    expect(html).toContain("Team Pro renews on");
    expect(html).toContain("Seats");
    expect(html).toContain(">4<");
    expect(html).toContain("$35/seat/mo");
    expect(html).toContain('name="scope" value="team"');
    expect(html).toContain('href="/api/billing/portal?scope=team"');
  });

  test("labels annual Stripe Team subscriptions", async () => {
    proUser.selectedTeam = { id: "team-pro", displayName: "Team Pro" };
    subscriptionResults = [
      [],
      [],
      [
        stripeSubscriptionRow({
          cancelAtPeriodEnd: false,
          plan: "team",
          scope: "team",
          seats: 4,
          lookupKey: "cmux-team-yearly-336",
        }),
      ],
    ];
    customerRows = [{ id: "cus_team" }];

    expect(await renderBillingPage()).toContain("$28/seat/mo, billed annually");
  });

  test("uses the current Stripe price interval over stale checkout metadata", async () => {
    proUser.selectedTeam = { id: "team-pro", displayName: "Team Pro" };
    subscriptionResults = [
      [],
      [],
      [
        stripeSubscriptionRow({
          cancelAtPeriodEnd: false,
          plan: "team",
          scope: "team",
          seats: 4,
          lookupKey: "cmux-team-monthly",
          billingInterval: "year",
        }),
      ],
    ];
    customerRows = [{ id: "cus_team" }];

    expect(await renderBillingPage()).toContain("$35/seat/mo");

    subscriptionResults = [
      [],
      [],
      [
        stripeSubscriptionRow({
          cancelAtPeriodEnd: false,
          plan: "team",
          scope: "team",
          seats: 4,
          lookupKey: "operator-managed-annual-price",
          recurringInterval: "year",
        }),
      ],
    ];
    expect(await renderBillingPage()).toContain("$28/seat/mo, billed annually");
  });

  test("localizes active annual Pro prices", () => {
    expect(enMessages.dashboard.billing.pro.annualPrice).toBe(
      "$24/mo, billed annually",
    );
    expect(jaMessages.dashboard.billing.pro.annualPrice).toBe("$24/月（年払い）");
  });

  test("renders active Stripe Team for a paid team when no team is selected", async () => {
    mockImplementation(proUser.listTeams, async () => [
      { id: "team-free", displayName: "Team Free", clientReadOnlyMetadata: { cmuxPlan: "free" } },
      { id: "team-pro", displayName: "Team Pro", clientReadOnlyMetadata: { cmuxPlan: "team" } },
    ]);
    subscriptionResults = [
      [],
      [],
      [
        stripeSubscriptionRow({
          cancelAtPeriodEnd: false,
          plan: "team",
          scope: "team",
          seats: 4,
        }),
      ],
    ];
    customerRows = [{ id: "cus_team" }];

    const html = await renderBillingPage();

    expect(html).toContain("cmux Team");
    expect(html).toContain("Team Pro renews on");
    expect(html).toContain('name="scope" value="team"');
    expect(html).not.toContain(
      "Upgrade when you need cloud agents or shared CodeRouter.",
    );
  });

  test("renders Stack metadata-only Pro as Free", async () => {
    proUser.clientReadOnlyMetadata = { cmuxPlan: "pro" };

    const html = await renderBillingPage();

    expect(html).toContain("Free");
    expect(html).toContain("You are currently on the Free plan.");
    expect(html).not.toContain("/api/billing/subscription");
    expect(html).not.toContain("/api/billing/portal");
  });

  for (const [billing, message] of [
    ["cancelled", "Your plan will cancel at the end of the current billing period."],
    ["resumed", "Your plan has been resumed and will renew normally."],
    ["nosub", "No active Stripe subscription was found for this account."],
    ["error", "Billing could not be updated. Try again shortly."],
  ] as const) {
    test(`renders ${billing} banner`, async () => {
      const html = await renderBillingPage({ billing });

      expect(html).toContain(message);
    });
  }
});

function selectableResult(table: unknown) {
  return {
    orderBy: () => selectableResult(table),
    limit: async () => {
      if (table === stripeSubscriptions) {
        return subscriptionResults.length > 0
          ? subscriptionResults.shift()!
          : subscriptionRows;
      }
      if (table === stripeCustomers) return customerRows;
      return [];
    },
  };
}

async function renderBillingPage(searchParams: Record<string, string> = {}) {
  const element = await DashboardBillingPage({
    params: Promise.resolve({ locale: "en" }),
    searchParams: Promise.resolve(searchParams),
  });
  // DashboardQueryProvider supplies the QueryClient that AccountPlanBadge's
  // useQuery needs; next-intl is mocked above so useTranslations resolves.
  return renderToStaticMarkup(
    <DashboardQueryProvider>{element}</DashboardQueryProvider>,
  );
}

function stripeSubscriptionRow({
  cancelAtPeriodEnd,
  plan = "pro",
  scope = "user",
  seats = null,
  lookupKey = "cmux-pro-monthly",
  billingInterval,
  recurringInterval,
}: {
  cancelAtPeriodEnd: boolean;
  plan?: string;
  scope?: string;
  seats?: number | null;
  lookupKey?: string;
  billingInterval?: "month" | "year";
  recurringInterval?: "month" | "year";
}) {
  return {
    id: "sub_123",
    status: "active",
    priceId: "price_123",
    plan,
    scope,
    seats,
    currentPeriodEnd: new Date("2026-12-01T00:00:00Z"),
    cancelAtPeriodEnd,
    raw: {
      metadata: billingInterval ? { billingInterval } : {},
      items: {
        data: [
          {
            price: {
              lookup_key: lookupKey,
              recurring: recurringInterval ? { interval: recurringInterval } : undefined,
            },
          },
        ],
      },
    },
  };
}

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string, values?: Record<string, unknown>) => {
    const message = String(valueAtPath(root, key));
    return interpolate(message, values);
  };
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

function mockImplementation(
  fn: unknown,
  implementation: (...args: never[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}
