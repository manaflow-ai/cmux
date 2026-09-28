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

const USER_ID = "user-admin";
const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;
const stripeModule = await import("../services/billing/stripe");

let currentUser: ReturnType<typeof fixtureStackUser> | null = null;
let dbRows: BillingDbRows = emptyBillingDbRows();
const getUser = mock(async (options?: unknown) => {
  if (typeof options === "string") return currentUser?.id === options ? currentUser : null;
  return currentUser;
});
const createSession = mock(async (_params: unknown) => ({ id: "cs_team", url: "https://checkout.stripe.com/c/team" }));
const createCustomer = mock(async (_params: unknown) => ({ id: "cus_new_team" }));
const createPortal = mock(async (_params: unknown) => ({ url: "https://billing.stripe.com/p/team" }));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
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
  resolveTeamPrice: async () => "price_team_month",
  stripe: () => ({
    checkout: { sessions: { create: createSession } },
    customers: { create: createCustomer },
    billingPortal: { sessions: { create: createPortal } },
  }),
}));
const realVmAuth = await import("../services/vms/auth");
mock.module("../services/vms/auth", () => ({
  ...realVmAuth,
  verifyRequest: async () => (currentUser ? { id: currentUser.id, isAnonymous: false } : null),
}));

const { GET, POST } = await import("../app/api/billing/checkout/route");

function checkoutGet(query: string) {
  return GET(new NextRequest(`https://cmux.test/api/billing/checkout?${query}`));
}

function checkoutPost(body: Record<string, unknown>) {
  return POST(new NextRequest("https://cmux.test/api/billing/checkout", {
    method: "POST",
    headers: {
      authorization: "Bearer app-access",
      "x-stack-refresh-token": "app-refresh",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  }));
}

function sessionParams(): Record<string, unknown> {
  return createSession.mock.calls[0]?.[0] as Record<string, unknown>;
}

describe("explicit team checkout", () => {
  const teamA = fixtureTeam("team-a", { displayName: "Team A", members: 3 });
  const teamB = fixtureTeam("team-b", { displayName: "Team B", members: 5 });

  beforeEach(() => {
    dbRows = emptyBillingDbRows();
    currentUser = fixtureStackUser({ id: USER_ID, teams: [teamA, teamB], adminTeamIds: ["team-b"], selectedTeam: teamA });
    getUser.mockClear();
    createSession.mockClear();
    createCustomer.mockClear();
    createPortal.mockClear();
  });

  test("GET ?teamId= buys for that team, not the selected one, and records the purchasing admin", async () => {
    const response = await checkoutGet("plan=team&teamId=team-b");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    const params = sessionParams();
    expect(params.client_reference_id).toBe("team-b");
    expect(params.line_items).toEqual([
      { price: "price_team_month", quantity: 5, adjustable_quantity: { enabled: true, minimum: 1 } },
    ]);
    expect(params.metadata).toMatchObject({ stackTeamId: "team-b", stackUserId: USER_ID, plan: "team" });
    expect((params.subscription_data as { metadata: unknown }).metadata).toMatchObject({ stackTeamId: "team-b", stackUserId: USER_ID });
    expect(currentUser?.hasPermission).toHaveBeenCalledWith(teamB, "team_admin");
    expect(createCustomer).toHaveBeenCalledWith({ name: "Team B", metadata: { stackTeamId: "team-b", app: "cmux" } });
  });

  test("refuses a member who is not an admin with 403 JSON and creates no Stripe state", async () => {
    const response = await checkoutGet("plan=team&teamId=team-a&format=json");

    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ error: "team_admin_required" });
    expect(createSession).not.toHaveBeenCalled();
    expect(createCustomer).not.toHaveBeenCalled();
  });

  test("refuses a team the user does not belong to with 404", async () => {
    const response = await checkoutGet("plan=team&teamId=team-foreign&format=json");

    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: "team_not_found" });
    expect(createSession).not.toHaveBeenCalled();
  });

  test("refuses the personal entry with 400 personal_team_not_upgradable_to_team", async () => {
    const response = await checkoutGet(`plan=team&teamId=${USER_ID}&format=json`);

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "personal_team_not_upgradable_to_team" });
    expect(currentUser?.hasPermission).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  test("browser navigations redirect refusals to the dashboard billing banner, not JSON", async () => {
    const cases: Array<[string, string]> = [
      ["team-a", "https://cmux.test/dashboard/billing?team=team-a&billing=team_admin_required"],
      ["team-foreign", "https://cmux.test/dashboard/billing?billing=team_not_found"],
      [USER_ID, "https://cmux.test/dashboard/billing?billing=personal_team_not_upgradable_to_team"],
    ];
    for (const [teamId, location] of cases) {
      const response = await checkoutGet(`plan=team&teamId=${teamId}`);
      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe(location);
    }
    currentUser!.hasPermission.mockImplementation(async () => {
      throw new Error("Stack unavailable");
    });
    expect((await checkoutGet("plan=team&teamId=team-b")).headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?team=team-b&billing=authorization_unavailable",
    );
    expect(createSession).not.toHaveBeenCalled();
  });

  test("sends an already-paying team's admin to that team's portal", async () => {
    dbRows.customers = [{ id: "cus_team_b" }];
    dbRows.subscriptions = [activeTeamSubscriptionRow()];

    const response = await checkoutGet("plan=team&teamId=team-b");

    const location = new URL(response.headers.get("location")!);
    expect(location.pathname).toBe("/api/billing/portal");
    expect(location.searchParams.get("scope")).toBe("team");
    expect(location.searchParams.get("teamId")).toBe("team-b");
    expect(createSession).not.toHaveBeenCalled();
  });

  test("fails closed with 503 when Stack cannot answer the admin check", async () => {
    currentUser!.hasPermission.mockImplementation(async () => {
      throw new Error("Stack unavailable");
    });

    const response = await checkoutGet("plan=team&teamId=team-b&format=json");

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: "authorization_unavailable" });
    expect(createSession).not.toHaveBeenCalled();
  });

  test("POST {plan: team, teamId} returns a checkout URL for an admin", async () => {
    const response = await checkoutPost({ plan: "team", teamId: "team-b" });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      url: "https://checkout.stripe.com/c/team",
      plan: "team",
      teamId: "team-b",
      flow: "checkout",
    });
    expect(getUser).toHaveBeenCalledWith(USER_ID);
    expect(sessionParams().metadata).toMatchObject({ stackTeamId: "team-b", stackUserId: USER_ID, cmuxClient: "cli" });
  });

  test("POST team requires an explicit teamId", async () => {
    const response = await checkoutPost({ plan: "team" });

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "team_id_required" });
    expect(createSession).not.toHaveBeenCalled();
  });

  test("POST team refuses non-admins, non-members and the personal entry", async () => {
    expect((await checkoutPost({ plan: "team", teamId: "team-a" })).status).toBe(403);
    expect((await checkoutPost({ plan: "team", teamId: "team-foreign" })).status).toBe(404);
    expect((await checkoutPost({ plan: "team", teamId: USER_ID })).status).toBe(400);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("POST team for a paying team returns a server-created team portal session", async () => {
    dbRows.customers = [{ id: "cus_team_b" }];
    dbRows.subscriptions = [activeTeamSubscriptionRow()];

    const response = await checkoutPost({ plan: "team", teamId: "team-b" });

    expect(await response.json()).toEqual({
      url: "https://billing.stripe.com/p/team",
      plan: "team",
      teamId: "team-b",
      flow: "portal",
    });
    expect(createPortal).toHaveBeenCalledWith({
      customer: "cus_team_b",
      return_url: "https://cmux.test/dashboard/billing?team=team-b",
    });
  });
});

describe("legacy implicit team checkout", () => {
  beforeEach(() => {
    dbRows = emptyBillingDbRows();
    createSession.mockClear();
  });

  test("without teamId keeps the selected team and skips the admin check", async () => {
    const selected = fixtureTeam("team-selected", { members: 2 });
    currentUser = fixtureStackUser({ id: USER_ID, teams: [selected], selectedTeam: selected });

    const response = await checkoutGet("plan=team");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    expect(sessionParams().client_reference_id).toBe("team-selected");
    expect(currentUser.hasPermission).not.toHaveBeenCalled();
  });

  test("creating a team for a user with none grants the creator team_admin", async () => {
    currentUser = fixtureStackUser({ id: USER_ID });

    const response = await checkoutGet("plan=team");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    expect(currentUser.createTeam).toHaveBeenCalledWith({ displayName: "cmux Team" });
    expect(currentUser.grantPermission).toHaveBeenCalledWith(
      expect.objectContaining({ id: "created-team" }),
      "team_admin",
    );
    expect(sessionParams().client_reference_id).toBe("created-team");
  });

  test("deletes the created team and fails checkout when the admin grant fails", async () => {
    const created = fixtureTeam("created-team");
    currentUser = fixtureStackUser({ id: USER_ID });
    currentUser.createTeam.mockImplementation(async () => created);
    currentUser.grantPermission.mockImplementation(async () => {
      throw new Error("grant failed");
    });

    const response = await checkoutGet("plan=team");

    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?billing=error");
    expect(created.delete).toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });
});
