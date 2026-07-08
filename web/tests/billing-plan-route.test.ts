import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { stripeSubscriptions } from "../db/schema";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = true;
let currentUser: ReturnType<typeof planUser> | null = null;
let stackProductsActive = false;
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];
let stripeSubscriptionResults: Array<Array<Record<string, unknown>>> = [];
let dbMissing = false;

const getUser = mock(async () => currentUser);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
  stackHandlerApp: null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => {
    if (dbMissing) throw new Error("DATABASE_URL is required");
    return {
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
    };
  },
}));

const { GET } = await import("../app/api/billing/plan/route");

describe("billing plan route", () => {
  beforeEach(() => {
    stackConfigured = true;
    currentUser = planUser();
    stackProductsActive = false;
    stripeSubscriptionRows = [];
    stripeSubscriptionResults = [];
    dbMissing = false;
    getUser.mockClear();
  });

  test("reports stripe management when an active Stripe subscription row exists", async () => {
    stripeSubscriptionRows = [{ id: "sub_123" }];

    const response = await planResponse();

    expect(response.planId).toBe("pro");
    expect(response.isPro).toBe(true);
    expect(response.billingManagement).toBe("stripe");
  });

  test("reports external management for Stack Pro without Stripe subscription rows", async () => {
    stackProductsActive = true;

    const response = await planResponse();

    expect(response.planId).toBe("pro");
    expect(response.isPro).toBe(true);
    expect(response.billingManagement).toBe("external");
  });

  test("reports no billing management for Free users", async () => {
    const response = await planResponse();

    expect(response.planId).toBe("free");
    expect(response.isPro).toBe(false);
    expect(response.billingManagement).toBe("none");
  });

  test("falls back to external management for Stack Pro when DB config is missing", async () => {
    stackProductsActive = true;
    dbMissing = true;

    const response = await planResponse();

    expect(response.planId).toBe("pro");
    expect(response.isPro).toBe(true);
    expect(response.billingManagement).toBe("external");
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

  test("reports external Team management when team metadata has no Stripe row", async () => {
    currentUser = planUser({
      selectedTeam: {
        id: "team-plan",
        clientReadOnlyMetadata: { cmuxPlan: "team" },
      },
    });
    stripeSubscriptionResults = [[], []];

    const response = await planResponse();

    expect(response.teamPlanId).toBe("team");
    expect(response.teamBillingManagement).toBe("external");
  });

  test("reports no Team billing management without a billing team", async () => {
    currentUser = planUser();

    const response = await planResponse();

    expect(response.teamPlanId).toBe("free");
    expect(response.teamBillingManagement).toBe("none");
  });
});

async function planResponse() {
  const response = await GET(new NextRequest("https://cmux.test/api/billing/plan"));
  return response.json() as Promise<Record<string, unknown>>;
}

function planUser(options: { selectedTeam?: unknown; listTeams?: () => Promise<readonly unknown[]> } = {}) {
  return {
    id: "user-plan",
    isAnonymous: false,
    displayName: "Plan User",
    primaryEmail: "plan@example.com",
    clientReadOnlyMetadata: {},
    selectedTeam: options.selectedTeam ?? null,
    listTeams: options.listTeams ?? mock(async () => []),
    listProducts: mock(async () =>
      Object.assign(
        stackProductsActive
          ? [
              {
                id: "pro",
                quantity: 1,
                subscription: {
                  cancelAtPeriodEnd: false,
                  currentPeriodEnd: null,
                },
              },
            ]
          : [],
        { nextCursor: null },
      ),
    ),
    update: mock(async () => undefined),
  };
}
