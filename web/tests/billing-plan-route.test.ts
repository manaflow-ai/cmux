import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import {
  billingEmailClaims,
  cloudVmStateTransitions,
  stripeSubscriptions,
} from "../db/schema";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = true;
let currentUser: ReturnType<typeof planUser> | null = null;
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];
let stripeSubscriptionResults: Array<Array<Record<string, unknown>>> = [];
let stateTransitionRows: Array<Record<string, unknown>> = [];
let claimLookupCount = 0;
let dbMissing = false;
let stackAuthUnavailable = false;

const getUser = mock(async () => {
  if (stackAuthUnavailable) throw new Error("Stack Auth unavailable");
  return currentUser;
});

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
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
          where: () => {
            const rows = table === cloudVmStateTransitions
              ? stateTransitionRows
              : table === billingEmailClaims
              ? []
              : table !== stripeSubscriptions
              ? []
              : stripeSubscriptionResults.length > 0
              ? stripeSubscriptionResults.shift()!
              : stripeSubscriptionRows;
            return Object.assign(Promise.resolve(rows), {
              limit: async () => {
                if (table === billingEmailClaims) claimLookupCount += 1;
                return rows;
              },
            });
          },
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
    stateTransitionRows = [];
    claimLookupCount = 0;
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

  test("includes current VM usage and the Pro allowance", async () => {
    stripeSubscriptionRows = [{
      id: "sub_123",
      currentPeriodEnd: new Date("2026-09-01T00:00:00Z"),
      raw: {
        current_period_start: Math.floor(new Date("2026-08-01T00:00:00Z").getTime() / 1_000),
        current_period_end: Math.floor(new Date("2026-09-01T00:00:00Z").getTime() / 1_000),
      },
    }];
    stateTransitionRows = [
      {
        id: "event-1",
        vmId: "vm-1",
        billingTeamId: "user-plan",
        fromState: "provisioning",
        toState: "running",
        createdAt: new Date("2026-08-10T00:00:00Z"),
      },
      {
        id: "event-2",
        vmId: "vm-1",
        billingTeamId: "user-plan",
        fromState: "running",
        toState: "paused",
        createdAt: new Date("2026-08-10T02:00:00Z"),
      },
    ];

    const response = await planResponse();
    const usage = response.vmUsage as Record<string, unknown>;
    expect(usage.activeComputeHours).toBe(2);
    expect(usage.includedComputeHours).toBe(20);
    expect(usage.overageComputeHours).toBe(0);
    expect(usage.billingTeamId).toBe("user-plan");
  });

  test("uses the personal Pro period for VMs stored under a personal team", async () => {
    const proSubscription = {
      id: "sub_personal_team",
      currentPeriodEnd: new Date("2026-09-15T00:00:00Z"),
      raw: {
        current_period_start: Math.floor(new Date("2026-08-15T00:00:00Z").getTime() / 1_000),
        current_period_end: Math.floor(new Date("2026-09-15T00:00:00Z").getTime() / 1_000),
      },
    };
    currentUser = planUser({
      selectedTeam: { id: "personal-team", clientReadOnlyMetadata: {} },
    });
    // Pro status, Team status, Team-period lookup, then the user-scoped Pro
    // fallback used for a personal team.
    stripeSubscriptionResults = [[proSubscription], [], [], [proSubscription]];
    stateTransitionRows = [
      {
        id: "personal-event-1",
        vmId: "vm-personal",
        billingTeamId: "personal-team",
        fromState: "provisioning",
        toState: "running",
        createdAt: new Date("2026-08-20T00:00:00Z"),
      },
      {
        id: "personal-event-2",
        vmId: "vm-personal",
        billingTeamId: "personal-team",
        fromState: "running",
        toState: "paused",
        createdAt: new Date("2026-08-20T02:00:00Z"),
      },
    ];

    const response = await planResponse();
    const usage = response.vmUsage as Record<string, unknown>;
    expect(usage.periodStart).toBe("2026-08-15T00:00:00.000Z");
    expect(usage.periodEnd).toBe("2026-09-15T00:00:00.000Z");
    expect(usage.activeComputeHours).toBe(2);
    expect(usage.billingTeamId).toBe("personal-team");
  });

  test("does not transfer pending ownership during a plan read", async () => {
    currentUser = planUser({ primaryEmailVerified: true });
    const response = await planResponse();

    expect(response.planId).toBe("free");
    expect(claimLookupCount).toBe(0);
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
  primaryEmailVerified?: boolean;
} = {}) {
  return {
    id: "user-plan",
    isAnonymous: false,
    displayName: "Plan User",
    primaryEmail: "plan@example.com",
    primaryEmailVerified: options.primaryEmailVerified ?? false,
    clientReadOnlyMetadata: {},
    selectedTeam: options.selectedTeam ?? null,
    listTeams: options.listTeams ?? mock(async () => []),
    stackProductGrant: options.stackProductGrant ?? false,
    update: mock(async () => undefined),
  };
}
