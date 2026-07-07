import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { stripeCustomers, stripeSubscriptions } from "../db/schema";
import enMessages from "../messages/en.json";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = true;
let currentUser: typeof proUser | null = null;
let stackProductsActive = false;
let subscriptionRows: Array<Record<string, unknown>> = [];
let customerRows: Array<Record<string, unknown>> = [];

const proUser = {
  id: "user-pro",
  isAnonymous: false,
  primaryEmail: "pro@example.com",
  clientReadOnlyMetadata: {},
  listProducts: mock(async () =>
    Object.assign(
      stackProductsActive
        ? [
            {
              id: "pro",
              quantity: 1,
              subscription: {
                cancelAtPeriodEnd: false,
                currentPeriodEnd: new Date("2026-12-01T00:00:00Z"),
              },
            },
          ]
        : [],
      { nextCursor: null },
    ),
  ),
  update: mock(async () => undefined),
};

mock.module("next-intl/server", () => ({
  getTranslations: async (input?: string | { namespace?: string }) =>
    translator(typeof input === "string" ? input : input?.namespace),
  setRequestLocale: () => undefined,
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
  cloudDb: () => ({
    select: () => ({
      from: (table: unknown) => ({
        where: () => selectableResult(table),
      }),
    }),
  }),
}));

const { default: DashboardBillingPage } = await import("../app/[locale]/dashboard/billing/page");

describe("dashboard billing page", () => {
  beforeEach(() => {
    stackConfigured = true;
    currentUser = proUser;
    stackProductsActive = false;
    subscriptionRows = [];
    customerRows = [];
    proUser.listProducts.mockClear();
    proUser.update.mockClear();
  });

  test("renders the Free plan state with a pricing link", async () => {
    const html = await renderBillingPage();

    expect(html).toContain("Free");
    expect(html).toContain("You are currently on the Free plan.");
    expect(html).toContain('href="/pricing"');
    expect(html).not.toContain("/api/billing/subscription");
  });

  test("renders active Stripe Pro with cancel and portal actions", async () => {
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: false })];
    customerRows = [{ id: "cus_123" }];

    const html = await renderBillingPage();

    expect(html).toContain("cmux Pro");
    expect(html).toContain("Your plan renews on");
    expect(html).toContain("$30/month");
    expect(html).toContain("Cancel plan");
    expect(html).toContain('action="/api/billing/subscription"');
    expect(html).toContain('href="/api/billing/portal"');
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

  test("renders legacy Stack Pro without Stripe self-serve actions", async () => {
    stackProductsActive = true;

    const html = await renderBillingPage();

    expect(html).toContain("cmux Pro");
    expect(html).toContain(
      "Your subscription is managed by our previous billing system. Contact support to make changes.",
    );
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
      if (table === stripeSubscriptions) return subscriptionRows;
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
  return renderToStaticMarkup(element);
}

function stripeSubscriptionRow({
  cancelAtPeriodEnd,
}: {
  cancelAtPeriodEnd: boolean;
}) {
  return {
    id: "sub_123",
    status: "active",
    priceId: "price_123",
    currentPeriodEnd: new Date("2026-12-01T00:00:00Z"),
    cancelAtPeriodEnd,
    raw: {
      items: {
        data: [
          {
            price: {
              lookup_key: "cmux-pro-monthly",
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
