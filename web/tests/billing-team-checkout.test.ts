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
// Queued Stripe answers, used before the defaults; reset before every test.
let queuedSessions: Array<Record<string, unknown>> = [];
let queuedRetrievals: Array<Record<string, unknown>> = [];
const createSession = mock(async (_params: unknown, _options?: unknown): Promise<Record<string, unknown>> =>
  queuedSessions.shift() ?? { id: "cs_team", url: "https://checkout.stripe.com/c/team" });
const retrieveSession = mock(async (id: string): Promise<Record<string, unknown>> =>
  queuedRetrievals.shift() ?? { id, url: "https://checkout.stripe.com/c/team", status: "open" });
const createCustomer = mock(async (_params: unknown, _options?: unknown) => ({ id: "cus_new_team" }));
const deleteCustomer = mock(async (_id: string) => ({ id: _id, deleted: true }));
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
    checkout: { sessions: { create: createSession, retrieve: retrieveSession } },
    customers: { create: createCustomer, del: deleteCustomer },
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
    deleteCustomer.mockClear();
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
    expect(createCustomer).toHaveBeenCalledWith(
      { name: "Team B", metadata: { stackTeamId: "team-b", app: "cmux" } },
      { idempotencyKey: expect.stringContaining("team-b") },
    );
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

describe("team checkout idempotency", () => {
  const teamB = fixtureTeam("team-b", { displayName: "Team B", members: 5 });
  const teamC = fixtureTeam("team-c", { displayName: "Team C", members: 5 });

  function idempotencyKeys(calls: unknown[][]): unknown[] {
    return calls.map((call) => (call[1] as { idempotencyKey?: unknown } | undefined)?.idempotencyKey);
  }

  beforeEach(() => {
    dbRows = emptyBillingDbRows();
    currentUser = fixtureStackUser({ id: USER_ID, teams: [teamB, teamC], adminTeamIds: ["team-b", "team-c"] });
    queuedSessions = [];
    queuedRetrievals = [];
    createSession.mockClear();
    retrieveSession.mockClear();
    createCustomer.mockClear();
    deleteCustomer.mockClear();
  });

  test("a repeated checkout for the same team reuses its Stripe customer and session keys", async () => {
    await checkoutGet("plan=team&teamId=team-b");
    dbRows = emptyBillingDbRows();
    await checkoutGet("plan=team&teamId=team-b");
    await checkoutGet("plan=team&teamId=team-c");

    const customerKeys = idempotencyKeys(createCustomer.mock.calls);
    const sessionKeys = idempotencyKeys(createSession.mock.calls);
    expect(customerKeys).toHaveLength(3);
    expect(sessionKeys).toHaveLength(3);
    for (const key of [...customerKeys, ...sessionKeys]) {
      expect(typeof key).toBe("string");
      expect((key as string).length).toBeLessThanOrEqual(255);
    }
    expect(customerKeys[0]).toBe(customerKeys[1]);
    expect(sessionKeys[0]).toBe(sessionKeys[1]);
    expect(customerKeys[2]).not.toBe(customerKeys[0]);
    expect(sessionKeys[2]).not.toBe(sessionKeys[0]);
    expect(customerKeys[0]).not.toBe(sessionKeys[0]);
  });

  function replayedSession(id: string, url: string) {
    return { id, url, lastResponse: { headers: { "idempotent-replayed": "true" } } };
  }

  test("a replayed Checkout Session that is still open is reused", async () => {
    queuedSessions = [replayedSession("cs_team", "https://checkout.stripe.com/c/team")];

    const response = await checkoutGet("plan=team&teamId=team-b");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    expect(retrieveSession).toHaveBeenCalledWith("cs_team");
    expect(createSession).toHaveBeenCalledTimes(1);
  });

  for (const status of ["complete", "expired"]) {
    test(`a replayed Checkout Session that is ${status} is replaced by a new one`, async () => {
      queuedSessions = [
        replayedSession("cs_stale", "https://checkout.stripe.com/c/stale"),
        { id: "cs_fresh", url: "https://checkout.stripe.com/c/fresh" },
      ];
      queuedRetrievals = [{ id: "cs_stale", url: null, status }];

      const response = await checkoutGet("plan=team&teamId=team-b");

      expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/fresh");
      const [first, second] = idempotencyKeys(createSession.mock.calls);
      expect(createSession.mock.calls[1]?.[0]).toEqual(createSession.mock.calls[0]?.[0]);
      expect(typeof second).toBe("string");
      expect(second).not.toBe(first);
      expect((second as string).length).toBeLessThanOrEqual(255);
    });
  }

  test("a replacement session that is itself replayed and finished is replaced again", async () => {
    queuedSessions = [
      replayedSession("cs_first", "https://checkout.stripe.com/c/first"),
      replayedSession("cs_second", "https://checkout.stripe.com/c/second"),
      { id: "cs_third", url: "https://checkout.stripe.com/c/third" },
    ];
    queuedRetrievals = [
      { id: "cs_first", url: null, status: "complete" },
      { id: "cs_second", url: null, status: "complete" },
    ];

    const response = await checkoutGet("plan=team&teamId=team-b");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/third");
    expect(retrieveSession.mock.calls.map((call) => call[0])).toEqual(["cs_first", "cs_second"]);
    expect(new Set(idempotencyKeys(createSession.mock.calls)).size).toBe(3);
  });

  test("a racer that got the same Stripe customer back reuses it when the insert hits the primary key", async () => {
    dbRows.beforeInsert = () => {
      dbRows.customers = [{ id: "cus_new_team" }];
      throw Object.assign(new Error("duplicate key"), { code: "23505", constraint: "stripe_customers_pkey" });
    };

    const response = await checkoutGet("plan=team&teamId=team-b");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    expect(sessionParams().customer).toBe("cus_new_team");
    expect(deleteCustomer).not.toHaveBeenCalled();
  });

  test("a checkout that loses the customer insert race deletes its Stripe customer and uses the winner's", async () => {
    dbRows.beforeInsert = () => {
      dbRows.customers = [{ id: "cus_race_winner" }];
      throw Object.assign(new Error("duplicate key"), {
        code: "23505",
        constraint: "stripe_customers_stack_team_id_unique",
      });
    };

    const response = await checkoutGet("plan=team&teamId=team-b");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    expect(sessionParams().customer).toBe("cus_race_winner");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_new_team");
  });

  test("a race whose winner holds the same Stripe customer deletes nothing", async () => {
    dbRows.beforeInsert = () => {
      dbRows.customers = [{ id: "cus_new_team" }];
      throw Object.assign(new Error("duplicate key"), {
        code: "23505",
        constraint: "stripe_customers_stack_team_id_unique",
      });
    };

    const response = await checkoutGet("plan=team&teamId=team-b");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    expect(sessionParams().customer).toBe("cus_new_team");
    expect(deleteCustomer).not.toHaveBeenCalled();
  });
});

describe("legacy implicit team checkout", () => {
  beforeEach(() => {
    dbRows = emptyBillingDbRows();
    createSession.mockClear();
  });

  test("without teamId an admin keeps checkout for the selected team", async () => {
    const selected = fixtureTeam("team-selected", { members: 2 });
    currentUser = fixtureStackUser({ id: USER_ID, teams: [selected], adminTeamIds: ["team-selected"], selectedTeam: selected });

    const response = await checkoutGet("plan=team");

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/team");
    expect(sessionParams().client_reference_id).toBe("team-selected");
  });

  test("without teamId a plain member of the selected team is refused", async () => {
    const selected = fixtureTeam("team-selected", { members: 2 });
    currentUser = fixtureStackUser({ id: USER_ID, teams: [selected], selectedTeam: selected });

    const response = await checkoutGet("plan=team");

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?billing=team_admin_required");
    expect(createSession).not.toHaveBeenCalled();
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
