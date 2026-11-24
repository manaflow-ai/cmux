import { afterEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { emptyBillingDbRows, fixtureStackUser, stubBillingDb } from "./helpers/billing-team-fixtures";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;
const stripeModule = await import("../services/billing/stripe");
const stackModule = await import("../app/lib/stack");

const currentUser = fixtureStackUser({ id: "user_1" });
const getUser = mock(async () => currentUser);
const createSession = mock(async (_params: unknown) => ({ id: "cs_x", url: "https://checkout.stripe.com/c/x" }));

mock.module("../app/lib/stack", () => ({
  ...stackModule,
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));
mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => stubBillingDb(() => emptyBillingDbRows()),
}));
mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  isStripeBillingConfigured: () => true,
  stripe: () => ({ checkout: { sessions: { create: createSession } } }),
}));

const { GET } = await import("../app/api/billing/checkout/route");
const { resolveProPlanStatus } = await import("../services/billing/pro");

const originalFlag = process.env.CMUX_CLOUD_INTRO;
afterEach(() => {
  if (originalFlag === undefined) delete process.env.CMUX_CLOUD_INTRO;
  else process.env.CMUX_CLOUD_INTRO = originalFlag;
});

describe("cmux Cloud $1 pass checkout route", () => {
  test("with the flag off, plan=intro answers exactly like any unknown plan", async () => {
    delete process.env.CMUX_CLOUD_INTRO;
    const intro = await GET(new NextRequest("https://cmux.test/api/billing/checkout?plan=intro&renew=1"));
    const unknown = await GET(new NextRequest("https://cmux.test/api/billing/checkout?plan=nonsense"));
    expect(intro.status).toBe(unknown.status);
    expect(intro.headers.get("location")).toBe("https://cmux.test/pricing?billing=invalid_plan");
    expect(intro.headers.get("location")).toBe(unknown.headers.get("location"));
    expect(createSession).not.toHaveBeenCalled();
    expect(getUser).not.toHaveBeenCalled();
  });
});

describe("cmux Cloud $1 pass expiry", () => {
  function statusFor(metadata: Record<string, unknown>) {
    const update = mock(async (_options: { clientReadOnlyMetadata: unknown }) => {});
    const user = { id: "user_1", clientReadOnlyMetadata: metadata, update };
    const lease = { refresh: mock(async () => {}) };
    return {
      update,
      run: () => resolveProPlanStatus(user, {
        activePersonalPlan: async () => null,
        stripeBillingStatus: {
          customerId: null, subscriptionStatus: null, subscriptionId: null, activePlanId: null,
          cancelAtPeriodEnd: false, hasCustomer: false, hasActiveSubscription: false,
        },
        activeApplePlan: async () => null,
        withFreshMetadataUser: async (_id, operation) => await operation(user, lease as never),
        environment: { NODE_ENV: "production", VERCEL_ENV: "production" },
      }),
    };
  }

  test("removes the pass keys at read time once the 30 days are over, keeping cmuxPlan and cmuxVmPlan", async () => {
    const ended = statusFor({
      cmuxPlan: "free",
      cmuxVmPlan: "free",
      cmuxNextPlan: "next_intro",
      cmuxNextPlanStartedAt: "2020-01-01T00:00:00.000Z",
      cmuxNextPlanEndsAt: "2020-01-31T00:00:00.000Z",
    });
    const status = await ended.run();
    expect(status.metadataChanged).toBe(true);
    expect(ended.update).toHaveBeenCalledTimes(1);
    expect(ended.update.mock.calls[0]![0]).toEqual({ clientReadOnlyMetadata: { cmuxPlan: "free", cmuxVmPlan: "free" } });
  });

  test("leaves a running pass alone", async () => {
    const running = statusFor({
      cmuxNextPlan: "next_intro",
      cmuxNextPlanStartedAt: new Date().toISOString(),
      cmuxNextPlanEndsAt: new Date(Date.now() + 86_400_000).toISOString(),
    });
    const status = await running.run();
    expect(status.metadataChanged).toBe(false);
    expect(running.update).not.toHaveBeenCalled();
  });
});
