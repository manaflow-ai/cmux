import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { stripeSubscriptions } from "../db/schema";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = true;
let currentUser: ReturnType<typeof planUser> | null = null;
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];
let stripeSubscriptionResults: Array<Array<Record<string, unknown>>> = [];
let dbMissing = false;
let stackAuthUnavailable = false;

const getUser = mock(async () => {
  if (stackAuthUnavailable) throw new Error("Stack Auth unavailable");
  return currentUser;
});

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => {
    if (dbMissing) throw new Error("DATABASE_URL is required");
    return withAccountMutationLeaseSupport({
      select: () => ({
        from: (table: unknown) => ({
          where: () => ({
            limit: async () => {
              if (table !== stripeSubscriptions) return [];
              return stripeSubscriptionResults.length > 0
                ? stripeSubscriptionResults.shift()!
                : stripeSubscriptionRows;
            },
          }),
        }),
      }),
    });
  },
}));

const { GET } = await import("../app/api/billing/plan/route");

describe("billing plan route", () => {
  beforeEach(() => {
    stackConfigured = true;
    currentUser = planUser();
    stripeSubscriptionRows = [];
    stripeSubscriptionResults = [];
    dbMissing = false;
    stackAuthUnavailable = false;
    getUser.mockClear();
  });

  test("reports stripe management when an active Stripe subscription row exists", async () => {
    stripeSubscriptionRows = [{ id: "sub_123" }];

    const response = await planResponse();

    expect(response.planId).toBe("pro");
    expect(response.isPro).toBe(true);
    expect(response.billingManagement).toBe("stripe");
  });

  test("reports a Founder entitlement as Pro without Stripe management", async () => {
    currentUser = planUser({
      clientReadOnlyMetadata: { cmuxVmPlan: "founders" },
    });

    const response = await planResponse();

    expect(response.planId).toBe("pro");
    expect(response.isPro).toBe(true);
    expect(response.billingManagement).toBe("none");
  });

  test("keeps a Founder personal plan alongside a Team Stripe plan", async () => {
    currentUser = planUser({
      clientReadOnlyMetadata: { cmuxVmPlan: "founders" },
      selectedTeam: { id: "team-founder", clientReadOnlyMetadata: {} },
    });
    stripeSubscriptionResults = [[], [{ id: "sub_team" }]];

    const response = await planResponse();

    expect(response.planId).toBe("pro");
    expect(response.isPro).toBe(true);
    expect(response.billingManagement).toBe("none");
    expect(response.teamPlanId).toBe("team");
    expect(response.teamBillingManagement).toBe("stripe");
  });

  test("reports Free for Stack Pro products without Stripe subscription rows", async () => {
    currentUser = planUser({
      stackProductGrant: true,
    });

    const response = await planResponse();

    expect(response.planId).toBe("free");
    expect(response.isPro).toBe(false);
    expect(response.billingManagement).toBe("none");
  });

  test("reports no billing management for Free users", async () => {
    const response = await planResponse();

    expect(response.planId).toBe("free");
    expect(response.isPro).toBe(false);
    expect(response.billingManagement).toBe("none");
  });

  test("does not grant Pro from Stack products when DB config is missing", async () => {
    currentUser = planUser({ stackProductGrant: true });
    dbMissing = true;

    const response = await planResponse();

    expect(response.planId).toBe("free");
    expect(response.isPro).toBe(false);
    expect(response.billingManagement).toBe("none");
  });

  test("reports Stripe management for an active Team subscription row", async () => {
    currentUser = planUser({
      selectedTeam: { id: "team-plan", clientReadOnlyMetadata: {} },
    });
    stripeSubscriptionResults = [[], [{ id: "sub_team" }]];

    const response = await planResponse();

    expect(response.teamPlanId).toBe("team");
    expect(response.teamBillingManagement).toBe("stripe");
  });

  test("reports no Team management when team metadata has no Stripe row", async () => {
    currentUser = planUser({
      selectedTeam: {
        id: "team-plan",
        clientReadOnlyMetadata: { cmuxPlan: "team" },
      },
    });
    stripeSubscriptionResults = [[], []];

    const response = await planResponse();

    expect(response.teamPlanId).toBe("free");
    expect(response.teamBillingManagement).toBe("none");
  });

  test("reports no Team billing management without a billing team", async () => {
    currentUser = planUser();

    const response = await planResponse();

    expect(response.teamPlanId).toBe("free");
    expect(response.teamBillingManagement).toBe("none");
  });

  test("returns a bounded unavailable response when Stack Auth is down", async () => {
    stackAuthUnavailable = true;

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/plan"),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "authentication_unavailable",
    });
  });
});

async function planResponse() {
  const response = await GET(new NextRequest("https://cmux.test/api/billing/plan"));
  return response.json() as Promise<Record<string, unknown>>;
}

function planUser(options: {
  selectedTeam?: unknown;
  listTeams?: () => Promise<readonly unknown[]>;
  stackProductGrant?: boolean;
  clientReadOnlyMetadata?: unknown;
} = {}) {
  return {
    id: "user-plan",
    isAnonymous: false,
    displayName: "Plan User",
    primaryEmail: "plan@example.com",
    clientReadOnlyMetadata: options.clientReadOnlyMetadata ?? {},
    selectedTeam: options.selectedTeam ?? null,
    listTeams: options.listTeams ?? mock(async () => []),
    stackProductGrant: options.stackProductGrant ?? false,
    update: mock(async () => undefined),
  };
}
