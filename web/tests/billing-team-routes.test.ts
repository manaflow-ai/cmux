import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import {
  activeTeamSubscriptionRow,
  emptyBillingDbRows,
  fixtureStackUser,
  fixtureTeam,
  stubBillingDb,
  type BillingDbRows,
} from "./helpers/billing-team-fixtures";

const USER_ID = "user-1";
const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;
const stripeModule = await import("../services/billing/stripe");

let currentUser: ReturnType<typeof fixtureStackUser> | null = null;
let dbRows: BillingDbRows = emptyBillingDbRows();
const getUser = mock(async () => currentUser);
// The payment method return token is signed with the Stripe secret.
process.env.STRIPE_SECRET_KEY ||= "sk_test_unit";
// A past-due team subscription on Stripe for the payment method return.
let providerSubscriptions: Array<{ id: string; status: string; metadata: Record<string, string>; default_payment_method: string | null }> = [];
let teamInvoices: Array<{ id: string; subscription: string; status: string; created: number }> = [];
let teamInvoiceError: Error | null = null;
const payTeamInvoice = mock(async (id: string, _params?: unknown) => {
  if (teamInvoiceError) throw teamInvoiceError;
  const invoice = teamInvoices.find((candidate) => candidate.id === id)!;
  invoice.status = "paid";
  providerSubscriptions.find((candidate) => candidate.id === invoice.subscription)!.status = "active";
  return { id, status: "paid" };
});
const createPortal = mock(async (_params: unknown) => ({ url: "https://billing.stripe.com/p/team" }));
const updateSubscription = mock(async (id: unknown, params: Record<string, unknown>) => ({
  id,
  status: "active",
  customer: "cus_team",
  cancel_at_period_end: params.cancel_at_period_end,
  items: { data: [] },
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser },
}));
mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => stubBillingDb(() => dbRows),
}));
mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  isStripeBillingConfigured: () => true,
  stripe: () => ({
    billingPortal: { sessions: { create: createPortal } },
    customers: { retrieve: async () => ({ id: "cus_team_b", invoice_settings: { default_payment_method: "pm_new" } }) },
    subscriptions: {
      update: updateSubscription,
      list: async (params: { status: string }) => ({
        data: providerSubscriptions.filter((subscription) => subscription.status === params.status),
      }),
      retrieve: async (id: string) => ({ ...providerSubscriptions.find((subscription) => subscription.id === id) }),
    },
    invoices: {
      list: async (params: { subscription: string; status: string }) => ({
        data: teamInvoices.filter((invoice) => invoice.subscription === params.subscription && invoice.status === params.status),
      }),
      retrieve: async (id: string) => ({ ...teamInvoices.find((invoice) => invoice.id === id) }),
      pay: payTeamInvoice,
    },
  }),
}));

const { GET: portalGET } = await import("../app/api/billing/portal/route");
const { POST: subscriptionPOST } = await import("../app/api/billing/subscription/route");
const { GET: planGET } = await import("../app/api/billing/plan/route");

const teamA = fixtureTeam("team-a", { displayName: "Team A", metadata: { cmuxPlan: "team", cmuxSeats: 4 } });
const teamB = fixtureTeam("team-b", { displayName: "Team B" });

beforeEach(() => {
  dbRows = emptyBillingDbRows();
  // Admin of team-b only; team-a is selected, so the legacy implicit
  // resolution would pick team-a.
  currentUser = fixtureStackUser({ id: USER_ID, teams: [teamA, teamB], adminTeamIds: ["team-b"], selectedTeam: teamA });
  createPortal.mockClear();
  updateSubscription.mockClear();
  providerSubscriptions = [];
  teamInvoices = [];
  teamInvoiceError = null;
  payTeamInvoice.mockClear();
});

describe("team portal", () => {
  test("?scope=team&teamId= opens that team's portal for its admin", async () => {
    dbRows.customers = [{ id: "cus_team_b" }];

    const response = await portalGET(new NextRequest("https://cmux.test/api/billing/portal?scope=team&teamId=team-b"));

    expect(response.headers.get("location")).toBe("https://billing.stripe.com/p/team");
    expect(createPortal).toHaveBeenCalledWith({
      customer: "cus_team_b",
      return_url: "https://cmux.test/dashboard/billing?team=team-b",
    });
  });

  test("opens the team's card form for its admin; saving returns to the team through recovery", async () => {
    dbRows.customers = [{ id: "cus_team_b" }];

    const response = await portalGET(
      new NextRequest("https://cmux.test/api/billing/portal?scope=team&teamId=team-b&flow=payment_method_update"),
    );

    expect(response.headers.get("location")).toBe("https://billing.stripe.com/p/team");
    const params = createPortal.mock.calls[0]?.[0] as {
      customer: string;
      return_url: string;
      flow_data: { type: string; after_completion: { redirect: { return_url: string } } };
    };
    expect(params.customer).toBe("cus_team_b");
    expect(params.return_url).toBe("https://cmux.test/dashboard/billing?team=team-b");
    expect(params.flow_data.type).toBe("payment_method_update");
    const completed = new URL(params.flow_data.after_completion.redirect.return_url);
    expect(completed.searchParams.get("flow")).toBe("payment_method_return");
    expect(completed.searchParams.get("scope")).toBe("team");
    expect(completed.searchParams.get("teamId")).toBe("team-b");

    // The team has nothing past due, so the return lands on its billing view.
    const returned = await portalGET(new NextRequest(completed));
    expect(returned.headers.get("location")).toBe("https://cmux.test/dashboard/billing?team=team-b");
  });

  async function teamCompletionURL(): Promise<URL> {
    await portalGET(new NextRequest("https://cmux.test/api/billing/portal?scope=team&teamId=team-b&flow=payment_method_update"));
    const params = createPortal.mock.calls.at(-1)?.[0] as { flow_data: { after_completion: { redirect: { return_url: string } } } };
    return new URL(params.flow_data.after_completion.redirect.return_url);
  }

  function pastDueTeam() {
    dbRows.customers = [{ id: "cus_team_b" }];
    providerSubscriptions = [{
      id: "sub_team", status: "past_due", metadata: { app: "cmux", plan: "team", scope: "team" }, default_payment_method: "pm_declined",
    }];
    teamInvoices = [{ id: "in_team", subscription: "sub_team", status: "open", created: 1 }];
  }

  test("pays the team's past-due renewal on its admin's return and reports it on the team view", async () => {
    pastDueTeam();

    const response = await portalGET(new NextRequest(await teamCompletionURL()));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?team=team-b&billing=payment_updated");
    expect(payTeamInvoice).toHaveBeenCalledWith("in_team", { payment_method: "pm_new" });
  });

  test("keeps a Stripe outage during the team's recovery on the team view", async () => {
    pastDueTeam();
    teamInvoiceError = Object.assign(new Error("Stripe is unavailable"), { type: "StripeAPIError" });

    const response = await portalGET(new NextRequest(await teamCompletionURL()));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?team=team-b&billing=error");
  });

  test("refuses a token minted for another customer on the team return", async () => {
    pastDueTeam();
    const completed = await teamCompletionURL();
    // A token signed for a different Stripe customer, such as the admin's personal one.
    const { paymentReturnToken } = await import("../services/billing/paymentRecovery");
    completed.searchParams.set("token", paymentReturnToken("cus_personal")!);

    const response = await portalGET(new NextRequest(completed));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?team=team-b");
    expect(payTeamInvoice).not.toHaveBeenCalled();
  });

  test("refuses a non-admin's payment method update for the team", async () => {
    dbRows.customers = [{ id: "cus_team_a" }];

    const response = await portalGET(
      new NextRequest("https://cmux.test/api/billing/portal?scope=team&teamId=team-a&flow=payment_method_return"),
    );

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?team=team-a&billing=team_admin_required",
    );
    expect(createPortal).not.toHaveBeenCalled();
  });

  test("returns non-admins to the team billing view with a banner and no session", async () => {
    dbRows.customers = [{ id: "cus_team_a" }];

    const response = await portalGET(new NextRequest("https://cmux.test/api/billing/portal?scope=team&teamId=team-a"));

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?team=team-a&billing=team_admin_required",
    );
    expect(createPortal).not.toHaveBeenCalled();
  });

  test("refuses teams the user does not belong to", async () => {
    dbRows.customers = [{ id: "cus_other" }];

    const response = await portalGET(new NextRequest("https://cmux.test/api/billing/portal?scope=team&teamId=team-x"));

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?team=team-x&billing=team_not_found",
    );
    expect(createPortal).not.toHaveBeenCalled();
  });

  test("reports nosub for an admin whose team never had a Stripe customer", async () => {
    const response = await portalGET(new NextRequest("https://cmux.test/api/billing/portal?scope=team&teamId=team-b"));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?team=team-b&billing=nosub");
  });
});

describe("team subscription cancel and resume", () => {
  function post(fields: Record<string, string>) {
    return subscriptionPOST(new NextRequest("https://cmux.test/api/billing/subscription", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "https://cmux.test",
        referer: "https://cmux.test/dashboard/billing",
      },
      body: new URLSearchParams(fields),
    }));
  }

  test("an admin cancels the named team's subscription, not the selected team's", async () => {
    dbRows.subscriptions = [{ id: "sub_team_b" }];

    const response = await post({ action: "cancel", scope: "team", teamId: "team-b" });

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?team=team-b&billing=cancelled");
    expect(updateSubscription).toHaveBeenCalledWith("sub_team_b", { cancel_at_period_end: true });
  });

  test("a member who is not an admin cannot cancel", async () => {
    dbRows.subscriptions = [{ id: "sub_team_a" }];

    const response = await post({ action: "cancel", scope: "team", teamId: "team-a" });

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?team=team-a&billing=team_admin_required",
    );
    expect(updateSubscription).not.toHaveBeenCalled();
  });

  test("the personal entry is not a team subscription subject", async () => {
    dbRows.subscriptions = [{ id: "sub_personal" }];

    const response = await post({ action: "resume", scope: "team", teamId: USER_ID });

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=personal_team_not_upgradable_to_team",
    );
    expect(updateSubscription).not.toHaveBeenCalled();
  });
});

// Regression: older forms and links name no team, so the routes resolve the
// selected team. That path skipped the admin check, and a plain member who
// selected a paid team could cancel its subscription or open its portal.
describe("legacy team billing without teamId", () => {
  function post(fields: Record<string, string>) {
    return subscriptionPOST(new NextRequest("https://cmux.test/api/billing/subscription", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "https://cmux.test",
        referer: "https://cmux.test/dashboard/billing",
      },
      body: new URLSearchParams(fields),
    }));
  }

  test("a member of the selected team cannot cancel it", async () => {
    dbRows.subscriptions = [{ id: "sub_team_a" }];

    const response = await post({ action: "cancel", scope: "team" });

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?team=team-a&billing=team_admin_required",
    );
    expect(updateSubscription).not.toHaveBeenCalled();
  });

  test("a member of the selected team cannot open its portal", async () => {
    dbRows.customers = [{ id: "cus_team_a" }];

    const response = await portalGET(new NextRequest("https://cmux.test/api/billing/portal?scope=team"));

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?team=team-a&billing=team_admin_required",
    );
    expect(createPortal).not.toHaveBeenCalled();
  });

  test("an admin of the selected team keeps the legacy cancel and portal", async () => {
    currentUser = fixtureStackUser({ id: USER_ID, teams: [teamA, teamB], adminTeamIds: ["team-b"], selectedTeam: teamB });
    dbRows.subscriptions = [{ id: "sub_team_b" }];
    dbRows.customers = [{ id: "cus_team_b" }];

    const cancel = await post({ action: "cancel", scope: "team" });
    expect(cancel.headers.get("location")).toBe("https://cmux.test/dashboard/billing?team=team-b&billing=cancelled");
    expect(updateSubscription).toHaveBeenCalledWith("sub_team_b", { cancel_at_period_end: true });

    const portal = await portalGET(new NextRequest("https://cmux.test/api/billing/portal?scope=team"));
    expect(portal.headers.get("location")).toBe("https://billing.stripe.com/p/team");
  });
});

describe("plan status for an explicit team", () => {
  async function plan(teamId: string) {
    return planGET(new NextRequest(`https://cmux.test/api/billing/plan?teamId=${encodeURIComponent(teamId)}`));
  }

  test("any member reads the team's plan, seats and their billing role", async () => {
    dbRows.subscriptions = [activeTeamSubscriptionRow(4)];

    const response = await plan("team-a");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      authenticated: true,
      billingAvailable: true,
      teamId: "team-a",
      teamPlanId: "team",
      teamBillingManagement: "stripe",
      seats: 4,
      role: "member",
      canManageBilling: false,
    });
  });

  test("an admin of a free team sees admin role and the free plan", async () => {
    const response = await plan("team-b");

    expect(await response.json()).toMatchObject({
      teamId: "team-b",
      teamPlanId: "free",
      teamBillingManagement: "none",
      seats: null,
      role: "admin",
      canManageBilling: true,
    });
  });

  test("non-members get 404 and the personal entry gets 400", async () => {
    const foreign = await plan("team-x");
    expect(foreign.status).toBe(404);
    expect(await foreign.json()).toEqual({ error: "team_not_found" });

    const personal = await plan(USER_ID);
    expect(personal.status).toBe(400);
    expect(await personal.json()).toEqual({ error: "personal_team_not_upgradable_to_team" });
  });

  test("without teamId keeps the legacy implicit response shape", async () => {
    const response = await planGET(new NextRequest("https://cmux.test/api/billing/plan"));

    const body = await response.json();
    expect(body).toHaveProperty("planId");
    expect(body).toHaveProperty("teamPlanId");
    expect(body).not.toHaveProperty("role");
  });
});
