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
    subscriptions: { update: updateSubscription },
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
      planId: "free",
      subscriptionPlanId: "free",
      isPro: false,
      billingManagement: "none",
      billingSource: "none",
      manageUrl: null,
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
