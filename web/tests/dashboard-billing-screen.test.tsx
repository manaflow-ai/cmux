import { beforeEach, describe, expect, mock, test } from "bun:test";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createTranslator, type AbstractIntlMessages } from "use-intl/core";

import { stripeCustomers, stripeSubscriptions } from "../db/schema";
import baseEnMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";
import {
  createScreenQueryClient,
  renderDashboardScreen,
} from "./helpers/dashboard-spa-render";
import { procedureResponse } from "./helpers/dashboard-procedure";

const enMessages = baseEnMessages;

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
  displayName: "Pro User",
  primaryEmail: "pro@example.com",
  primaryEmailVerified: true,
  profileImageUrl: null,
  clientReadOnlyMetadata: {},
  selectedTeam: null as null | { id: string; displayName?: string; clientReadOnlyMetadata?: unknown },
  listTeams: mock(async () => [] as Array<TestTeam>),
  update: mock(async () => undefined),
  hasPermission: mock(async (_team: unknown, _permission: string) => true),
};

type TestTeam = {
  id: string;
  displayName?: string;
  clientReadOnlyMetadata?: unknown;
  listUsers?: () => Promise<unknown[]>;
};

function teamWithMembers(id: string, displayName: string, members: number, metadata: unknown = {}): TestTeam {
  return {
    id,
    displayName,
    clientReadOnlyMetadata: metadata,
    listUsers: async () => Array.from({ length: members }, (_, index) => ({ id: `member-${index}` })),
  };
}

// The screens use the client `useTranslations`. Mock it with the real ICU
// translator over the English catalog so the render is self-contained. Export
// the full client surface the app imports so this mock never shadows an export
// a later file needs (bun's mock.module is process-global without --isolate).
mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => "en",
  useTranslations: (namespace?: string) =>
    createTranslator({
      locale: "en",
      messages: enMessages as unknown as AbstractIntlMessages,
      namespace: namespace as never,
      timeZone: "UTC",
    }),
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

const { accountRouter } = await import("../orpc/server/dashboard/account");
const { billing: teamBillingProcedure } = await import("../orpc/server/dashboard/team-billing");
const dashboardBillingGET = (request: Request) =>
  procedureResponse(accountRouter.billing, { team: new URL(request.url).searchParams.get("team") }, request);
const teamBillingGET = async (request: Request, context: { params: Promise<{ teamId: string }> }) =>
  procedureResponse(teamBillingProcedure, { teamId: (await context.params).teamId }, request);
const { BillingScreen } = await import("../dashboard-app/screens/billing/billing-screen");
const { TeamBillingPanel } = await import("../dashboard-app/screens/billing/team-billing-panel");
const { dashboardBillingQuery, teamBillingQuery } = await import("../dashboard-app/queries/billing");
const { sessionQuery } = await import("../dashboard-app/lib/session");

function resetFixtures() {
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
  proUser.hasPermission.mockClear();
  mockImplementation(proUser.hasPermission, async () => true);
}

describe("dashboard.account.billing", () => {
  beforeEach(resetFixtures);

  test("returns 401 without a signed-in user", async () => {
    currentUser = null;
    const response = await dashboardBillingGET(new Request("https://cmux.test/api/dashboard/billing"));
    expect(response.status).toBe(401);
  });

  test("returns the personal entry with a private no-store response", async () => {
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: false })];
    customerRows = [{ id: "cus_123" }];

    const response = await dashboardBillingGET(new Request("https://cmux.test/api/dashboard/billing"));
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.selectedTeamId).toBe("user-pro");
    expect(body.team).toBeNull();
    expect(body.personal.planStatus).toEqual({ isPro: true, planId: "pro", billingManagement: "stripe" });
    expect(body.personal.subscription).toEqual({
      plan: "pro",
      status: "active",
      currentPeriodEnd: "2026-12-01T00:00:00.000Z",
      cancelAtPeriodEnd: false,
      price: { amountUsd: 50, interval: "month" },
    });
    expect(body.personal.hasPaidManualGrant).toBe(false);
    // Nothing server-only (raw Stripe payloads, price ids) reaches the wire.
    expect(JSON.stringify(body)).not.toContain("price_123");
    expect(JSON.stringify(body)).not.toContain("lookup_key");
  });

  test("returns the selected team's view with ISO dates", async () => {
    const team = teamWithMembers("team-pro", "Team Pro", 3, { cmuxPlan: "team", cmuxSeats: 4 });
    mockImplementation(proUser.listTeams, async () => [team]);
    subscriptionRows = [
      stripeSubscriptionRow({ cancelAtPeriodEnd: false, plan: "team", scope: "team", seats: 4, unitAmount: 6000 }),
    ];

    const response = await dashboardBillingGET(
      new Request("https://cmux.test/api/dashboard/billing?team=team-pro"),
    );
    const body = await response.json();
    expect(body.selectedTeamId).toBe("team-pro");
    expect(body.personal).toBeNull();
    expect(body.team.status).toBe("ready");
    expect(body.team.subscription.currentPeriodEnd).toBe("2026-12-01T00:00:00.000Z");
    expect(body.team.memberCount).toBe(3);
    expect(body.teams).toEqual([
      { id: "team-pro", displayName: "Team Pro", personal: false, planId: "team" },
    ]);
  });

  test("marks an operator paid grant without a subscription", async () => {
    proUser.clientReadOnlyMetadata = { cmuxVmPlan: "pro" };
    const body = await (await dashboardBillingGET(new Request("https://cmux.test/api/dashboard/billing"))).json();
    expect(body.personal.hasPaidManualGrant).toBe(true);
  });
});

describe("dashboard.teams.billing", () => {
  beforeEach(resetFixtures);

  test("returns 401 without a signed-in user", async () => {
    currentUser = null;
    const response = await teamBillingGET(
      new Request("https://cmux.test/api/teams/team-pro/billing"),
      { params: Promise.resolve({ teamId: "team-pro" }) },
    );
    expect(response.status).toBe(401);
  });

  test("returns not_found for a team the user does not belong to", async () => {
    const response = await teamBillingGET(
      new Request("https://cmux.test/api/teams/team-foreign/billing"),
      { params: Promise.resolve({ teamId: "team-foreign" }) },
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "not_found", teamId: "team-foreign" });
  });

  test("renders a member's team panel through the shared query", async () => {
    const team = teamWithMembers("team-pro", "Team Pro", 6);
    mockImplementation(proUser.listTeams, async () => [team]);
    mockImplementation(proUser.hasPermission, async () => false);
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: false, plan: "team", scope: "team", seats: 4 })];

    const response = await teamBillingGET(
      new Request("https://cmux.test/api/teams/team-pro/billing"),
      { params: Promise.resolve({ teamId: "team-pro" }) },
    );
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(teamBillingQuery("team-pro").queryKey, await response.json());
    const html = await renderDashboardScreen({
      url: "/dashboard/teams/team-pro/billing",
      queryClient,
      render: () => <TeamPanelFromQuery teamId="team-pro" />,
    });

    expect(html).toContain("Team Pro renews on");
    expect(html).toContain("6 of 4 used");
    expect(html).toContain("Only team admins can change this plan.");
    expect(html).not.toContain("/api/billing/portal");
  });
});

describe("dashboard billing screen", () => {
  beforeEach(resetFixtures);

  test("renders the Free plan state with pricing cards and TestFlight link", async () => {
    const html = await renderBillingPage();

    expect(html).toContain("Free");
    expect(html).toContain("You are currently on the Free plan.");
    expect(html).toContain(
      "Upgrade when you need cloud agents.",
    );
    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_source=dashboard_billing&amp;interval=month&amp;cmux_placement=dashboard_billing"',
    );
    // Personal accounts cannot buy Team; the card routes to team creation.
    expect(html).toContain('href="/dashboard/teams/new"');
    expect(html).not.toContain("plan=team");
    expect(html).toContain("Get Pro");
    expect(html).toContain("Get Max");
    expect(html).toContain("Create a team");
    expect(html).toContain(
      'href="/api/billing/checkout?plan=max&amp;cmux_external_browser=1&amp;cmux_source=dashboard_billing&amp;cmux_placement=dashboard_billing"',
    );
    expect(html).not.toMatch(/plan=max[^"]*interval=/);
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

  test("keeps billing upsells monthly for old annual links", async () => {
    const html = await renderBillingPage({ interval: "year" });

    expect(html).toContain("$50");
    expect(html).toContain("$60");
    expect(html).toContain("/mo");
    expect(html).toContain("/user/mo");
    expect(html).not.toContain("/mo, billed yearly");
    expect(html).not.toContain("/user/mo, billed yearly");
    expect(html).not.toContain("/mo.");
    expect(html).not.toContain("$24");
    expect(html).not.toContain("$28");
    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro&amp;cmux_external_browser=1&amp;cmux_source=dashboard_billing&amp;interval=month&amp;cmux_placement=dashboard_billing"',
    );
    // Personal accounts cannot buy Team; the card routes to team creation.
    expect(html).toContain('href="/dashboard/teams/new"');
    expect(html).not.toContain("plan=team");
  });

  test("renders active Stripe Pro with cancel and portal actions", async () => {
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: false })];
    customerRows = [{ id: "cus_123" }];

    const html = await renderBillingPage();

    expect(html).toContain("cmux Pro");
    expect(html).toContain("Your plan renews on");
    expect(html).toContain("$50/mo");
    expect(html).toContain("Cancel plan");
    expect(html).toContain('action="/api/billing/subscription"');
    expect(html).toContain('href="/api/billing/portal"');
  });

  test("prices every Stripe Pro subscription from its own price amount", async () => {
    customerRows = [{ id: "cus_123" }];
    const cases: Array<[string | undefined, number, "month" | "year", string]> = [
      ["cmux-pro-yearly-480", 48000, "year", "$40/mo, billed annually"],
      ["cmux-pro-yearly-288", 28800, "year", "$24/mo, billed annually"],
      ["cmux-pro-yearly", 24000, "year", "$20/mo, billed annually"],
      ["cmux-pro-monthly", 3000, "month", "$30/mo"],
      // Stack-era Prices carry no lookup key at all.
      [undefined, 3000, "month", "$30/mo"],
    ];
    for (const [lookupKey, unitAmount, recurringInterval, expected] of cases) {
      subscriptionRows = [
        stripeSubscriptionRow({
          cancelAtPeriodEnd: false,
          lookupKey,
          unitAmount,
          recurringInterval,
        }),
      ];
      expect(await renderBillingPage()).toContain(expected);
    }
  });

  test("omits the price metric when Stripe sent no amount or a non-USD currency", async () => {
    customerRows = [{ id: "cus_123" }];
    subscriptionRows = [
      stripeSubscriptionRow({ cancelAtPeriodEnd: false, unitAmount: null }),
    ];
    let html = await renderBillingPage();
    expect(html).toContain("cmux Pro");
    expect(html).not.toContain(">Price<");

    // 5000 JPY is not $50.
    subscriptionRows = [
      stripeSubscriptionRow({ cancelAtPeriodEnd: false, unitAmount: 5000, currency: "jpy" }),
    ];
    html = await renderBillingPage();
    expect(html).not.toContain(">Price<");
    expect(html).not.toContain("$50/mo");
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

  test("renders a past-due banner that links to the Stripe portal", async () => {
    subscriptionRows = [stripeSubscriptionRow({
      cancelAtPeriodEnd: false,
      status: "past_due",
    })];
    customerRows = [{ id: "cus_123" }];

    const html = await renderBillingPage();

    expect(html).toContain(
      "Your latest payment failed. Update your payment method to keep your plan active.",
    );
    expect(html).toContain('href="/api/billing/portal"');
  });

  test("renders the selected team's active Team plan with seats vs members and admin actions", async () => {
    const team = teamWithMembers("team-pro", "Team Pro", 3, { cmuxPlan: "team", cmuxSeats: 4 });
    proUser.selectedTeam = team;
    mockImplementation(proUser.listTeams, async () => [team]);
    subscriptionRows = [
      stripeSubscriptionRow({
        cancelAtPeriodEnd: false,
        plan: "team",
        scope: "team",
        seats: 4,
        lookupKey: "cmux-team-monthly-60",
        unitAmount: 6000,
      }),
    ];
    customerRows = [{ id: "cus_team" }];

    const html = await renderBillingPage();

    expect(html).toContain("cmux Team");
    expect(html).toContain("Team Pro renews on");
    expect(html).toContain("Seats");
    expect(html).toContain("3 of 4 used");
    expect(html).toContain("$60/seat/mo");
    expect(html).toContain('name="scope" value="team"');
    expect(html).toContain('name="teamId" value="team-pro"');
    expect(html).toContain('href="/api/billing/portal?scope=team&amp;teamId=team-pro"');
    expect(html).not.toContain("You are currently on the Free plan.");
    expect(proUser.hasPermission).toHaveBeenCalledWith(team, "team_admin");
  });

  test("labels annual Stripe Team subscriptions", async () => {
    const team = teamWithMembers("team-pro", "Team Pro", 2);
    proUser.selectedTeam = team;
    subscriptionRows = [
      stripeSubscriptionRow({
        cancelAtPeriodEnd: false,
        plan: "team",
        scope: "team",
        seats: 4,
        lookupKey: "cmux-team-yearly-576",
        unitAmount: 57600,
        recurringInterval: "year",
      }),
    ];
    customerRows = [{ id: "cus_team" }];

    expect(await renderBillingPage()).toContain("$48/seat/mo, billed annually");
  });

  test("uses the current Stripe price interval over stale checkout metadata", async () => {
    const team = teamWithMembers("team-pro", "Team Pro", 2);
    proUser.selectedTeam = team;
    subscriptionRows = [
      stripeSubscriptionRow({
        cancelAtPeriodEnd: false,
        plan: "team",
        scope: "team",
        seats: 4,
        lookupKey: "cmux-team-monthly",
        unitAmount: 3500,
        billingInterval: "year",
      }),
    ];
    customerRows = [{ id: "cus_team" }];

    expect(await renderBillingPage()).toContain("$35/seat/mo");

    subscriptionRows = [
      stripeSubscriptionRow({
        cancelAtPeriodEnd: false,
        plan: "team",
        scope: "team",
        seats: 4,
        lookupKey: "operator-managed-annual-price",
        unitAmount: 33600,
        recurringInterval: "year",
      }),
    ];
    expect(await renderBillingPage()).toContain("$28/seat/mo, billed annually");
  });

  test("nudges admins when members exceed paid seats without blocking", async () => {
    const team = teamWithMembers("team-pro", "Team Pro", 6);
    proUser.selectedTeam = team;
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: false, plan: "team", scope: "team", seats: 4 })];

    const html = await renderBillingPage();

    expect(html).toContain("6 of 4 used");
    expect(html).toContain("Team Pro has 6 members and 4 paid seats.");
    expect(html).toContain("Add seats");
  });

  test("shows team members a read-only Team plan without billing actions", async () => {
    const team = teamWithMembers("team-pro", "Team Pro", 6);
    proUser.selectedTeam = team;
    mockImplementation(proUser.hasPermission, async () => false);
    subscriptionRows = [stripeSubscriptionRow({ cancelAtPeriodEnd: false, plan: "team", scope: "team", seats: 4 })];

    const html = await renderBillingPage();

    expect(html).toContain("Team Pro renews on");
    expect(html).toContain("Only team admins can change this plan.");
    expect(html).not.toContain("/api/billing/subscription");
    expect(html).not.toContain("/api/billing/portal");
    expect(html).not.toContain("paid seats");
  });

  test("offers admins an explicit-team upgrade on a free team", async () => {
    const team = teamWithMembers("team-free", "Team Free", 2);
    mockImplementation(proUser.listTeams, async () => [team]);

    const html = await renderBillingPage({ team: "team-free" });

    expect(html).toContain("Team Free is on the Free plan.");
    expect(html).toContain("Upgrade this team");
    expect(html).toContain("/api/billing/checkout?plan=team&amp;cmux_external_browser=1&amp;teamId=team-free");
    expect(html).not.toContain("Get Pro");
  });

  test("asks members of a free team to contact an admin", async () => {
    const team = teamWithMembers("team-free", "Team Free", 2);
    mockImplementation(proUser.listTeams, async () => [team]);
    mockImplementation(proUser.hasPermission, async () => false);

    const html = await renderBillingPage({ team: "team-free" });

    expect(html).toContain("Ask an admin of Team Free to upgrade.");
    expect(html).not.toContain("plan=team");
  });

  test("ignores a ?team= the user does not belong to and shows the personal view", async () => {
    const html = await renderBillingPage({ team: "team-foreign" });

    expect(html).toContain("You are currently on the Free plan.");
    expect(proUser.hasPermission).not.toHaveBeenCalled();
  });

  test("localizes active Pro and Team price templates", () => {
    expect(enMessages.dashboard.billing.pro.monthlyPrice).toBe("${amount}/mo");
    expect(enMessages.dashboard.billing.pro.annualPrice).toBe(
      "${monthly}/mo, billed annually",
    );
    expect(jaMessages.dashboard.billing.pro.annualPrice).toBe("${monthly}/月（年払い）");
    expect(jaMessages.dashboard.billing.team.price).toBe("${amount}/シート/月");
  });

  test("shows the personal view with a team list and plan badges when no team is selected", async () => {
    mockImplementation(proUser.listTeams, async () => [
      { id: "team-free", displayName: "Team Free", clientReadOnlyMetadata: { cmuxPlan: "free" } },
      { id: "team-pro", displayName: "Team Pro", clientReadOnlyMetadata: { cmuxPlan: "team" } },
    ]);

    const html = await renderBillingPage();

    expect(html).toContain("You are currently on the Free plan.");
    expect(html).toContain("Billing scopes");
    expect(html).toContain('href="/dashboard/billing?team=user-pro"');
    expect(html).toContain('href="/dashboard/billing?team=team-free"');
    expect(html).toContain('href="/dashboard/billing?team=team-pro"');
    expect(html).toMatch(/Team Pro<\/a><span[^>]*>Team<\/span>/);
    expect(html).not.toContain('name="scope" value="team"');
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
  const rows = () => {
    if (table === stripeSubscriptions) return subscriptionResults.length ? subscriptionResults.shift()! : subscriptionRows;
    if (table === stripeCustomers) return customerRows;
    return [];
  };
  return {
    then: (resolve: (value: Array<Record<string, unknown>>) => unknown, reject?: (error: unknown) => unknown) => Promise.resolve(rows()).then(resolve, reject),
    orderBy: () => selectableResult(table),
    limit: async () => rows(),
  };
}


function TeamPanelFromQuery({ teamId }: { teamId: string }) {
  const { data } = useSuspenseQuery(teamBillingQuery(teamId));
  return <TeamBillingPanel view={data} />;
}

/**
 * The full path: the API route builds the response from the mocked Stack
 * user and DB, the screen renders it from a seeded query cache.
 */
async function renderBillingPage(searchParams: Record<string, string> = {}) {
  const search = new URLSearchParams(searchParams).toString();
  const response = await dashboardBillingGET(
    new Request(`https://cmux.test/api/dashboard/billing${search ? `?${search}` : ""}`),
  );
  expect(response.status).toBe(200);
  const queryClient = createScreenQueryClient();
  queryClient.setQueryData(dashboardBillingQuery(searchParams.team).queryKey, await response.json());
  queryClient.setQueryData(sessionQuery.queryKey, {
    user: {
      id: proUser.id,
      displayName: proUser.displayName,
      primaryEmail: proUser.primaryEmail,
      primaryEmailVerified: true,
      profileImageUrl: null,
      selectedTeamId: proUser.selectedTeam?.id ?? null,
    },
    flags: { vaultEnabled: false },
  });
  return renderDashboardScreen({
    url: `/dashboard/billing${search ? `?${search}` : ""}`,
    queryClient,
    render: () => <BillingScreen search={searchParams} />,
  });
}

function stripeSubscriptionRow({
  cancelAtPeriodEnd,
  status = "active",
  plan = "pro",
  scope = "user",
  seats = null,
  lookupKey = "cmux-pro-monthly-50",
  unitAmount = 5000,
  currency = "usd",
  billingInterval,
  recurringInterval = "month",
}: {
  cancelAtPeriodEnd: boolean;
  status?: string;
  plan?: string;
  scope?: string;
  seats?: number | null;
  lookupKey?: string;
  unitAmount?: number | null;
  currency?: string;
  billingInterval?: "month" | "year";
  recurringInterval?: "month" | "year";
}) {
  return {
    id: "sub_123",
    status,
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
              unit_amount: unitAmount,
              currency,
              recurring: { interval: recurringInterval },
            },
          },
        ],
      },
    },
  };
}

function mockImplementation(
  fn: unknown,
  implementation: (...args: never[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}
