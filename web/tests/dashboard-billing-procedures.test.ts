import { beforeEach, describe, expect, mock, test } from "bun:test";
import { call, ORPCError } from "@orpc/server";

let sessionOk = true;
let accessOk = true;
let applied: { scope: string; ownerId: string; action: string }[] = [];
let applyResult = true;
let events: { event: string; distinctId: string; teamId?: string | null; properties?: Record<string, unknown> }[] = [];
let previewImpl: () => Promise<unknown> = async () => ({});
let changeImpl: () => Promise<unknown> = async () => ({ plan: "max" });

mock.module("@/services/billing/dashboardSessionRoute", () => ({
  resolveDashboardSessionUser: async () =>
    sessionOk ? { ok: true, user: { id: "user-1", primaryEmailVerified: false } } : { ok: false, status: 401, reason: "unauthorized" },
}));

const realPlanChange = await import("../services/billing/planChange");
mock.module("@/services/billing/planChange", () => ({
  ...realPlanChange,
  previewPersonalPlanChange: () => previewImpl(),
  applyPersonalPlanChange: () => changeImpl(),
}));

const realManagement = await import("../services/billing/subscriptionManagement");
mock.module("@/services/billing/subscriptionManagement", () => ({
  ...realManagement,
  applySubscriptionAction: async (input: { scope: string; ownerId: string; action: string }) => {
    applied.push({ scope: input.scope, ownerId: input.ownerId, action: input.action });
    return applyResult;
  },
}));

const realAccess = await import("../services/billing/teamBillingAccess");
mock.module("@/services/billing/teamBillingAccess", () => ({
  ...realAccess,
  resolveTeamBillingAccess: async (_user: unknown, teamId: string, options: { requireAdmin: boolean }) => {
    expect(options.requireAdmin).toBe(true);
    return accessOk ? { ok: true, team: { id: teamId } } : { ok: false, error: "team_admin_required" };
  },
}));

const realEvents = await import("../services/analytics/serverEvents");
mock.module("@/services/analytics/serverEvents", () => ({
  ...realEvents,
  captureServerEvent: async (input: (typeof events)[number]) => {
    events.push(input);
  },
}));

const realStripe = await import("../services/billing/stripe");
mock.module("@/services/billing/stripe", () => ({ ...realStripe, isStripeBillingConfigured: () => true }));

const { billingRouter } = await import("../orpc/server/dashboard/billing");
const { PlanChangeError } = realPlanChange;

const context = { request: new Request("https://cmux.test/api/dashboard/rpc"), serverPrefetch: true };

async function refusalOf(operation: Promise<unknown>) {
  const error = await operation.catch((caught: unknown) => caught);
  expect(error).toBeInstanceOf(ORPCError);
  const refusal = error as ORPCError<string, { reason: string }>;
  return [refusal.code, refusal.status, refusal.data?.reason];
}

beforeEach(() => {
  sessionOk = true;
  accessOk = true;
  applied = [];
  applyResult = true;
  events = [];
  previewImpl = async () => ({});
  changeImpl = async () => ({ plan: "max" });
});

describe("dashboard billing procedures", () => {
  test("every billing procedure requires a signed-in user", async () => {
    sessionOk = false;
    expect(await refusalOf(call(billingRouter.previewChange, { plan: "max" }, { context }))).toEqual(["UNAUTHORIZED", 401, "unauthorized"]);
    expect(await refusalOf(call(billingRouter.cancel, {}, { context }))).toEqual(["UNAUTHORIZED", 401, "unauthorized"]);
    expect(applied).toEqual([]);
  });

  test("a preview passes the service result through its output schema", async () => {
    const preview = {
      plan: "max",
      direction: "upgrade",
      currency: "usd",
      amountDueToday: 9_987,
      credit: 0,
      nextRenewalAt: "2026-10-20T00:00:00.000Z",
      nextInvoiceAmount: 20_000,
      prorationDate: 1_790_000_000,
    };
    previewImpl = async () => preview;
    expect(await call(billingRouter.previewChange, { plan: "max" }, { context })).toEqual(preview);
  });

  test("plan change refusals are declared: conflicts and a declined payment", async () => {
    previewImpl = async () => { throw new PlanChangeError("cancel_scheduled"); };
    expect(await refusalOf(call(billingRouter.previewChange, { plan: "max" }, { context }))).toEqual(["CONFLICT", 409, "cancel_scheduled"]);
    changeImpl = async () => { throw new PlanChangeError("payment_failed"); };
    expect(await refusalOf(call(billingRouter.change, { plan: "max", prorationDate: 1 }, { context }))).toEqual(["PAYMENT_REQUIRED", 402, "payment_failed"]);
  });

  test("cancel without a reason records no analytics; with one it records the reason", async () => {
    await call(billingRouter.cancel, {}, { context });
    expect(applied).toEqual([{ scope: "user", ownerId: "user-1", action: "cancel" }]);
    expect(events).toEqual([]);
    await call(billingRouter.cancel, { reason: { code: "other", detail: "  moving to another tool  " } }, { context });
    expect(events).toEqual([
      expect.objectContaining({
        event: "billing_cancel_reason",
        distinctId: "user-1",
        properties: expect.objectContaining({ scope: "user", reason: "other", detail: "moving to another tool" }),
      }),
    ]);
  });

  test("team cancel and resume require team admin", async () => {
    accessOk = false;
    expect(await refusalOf(call(billingRouter.cancel, { teamId: "team-1" }, { context }))).toEqual(["FORBIDDEN", 403, "team_admin_required"]);
    expect(await refusalOf(call(billingRouter.resume, { teamId: "team-1" }, { context }))).toEqual(["FORBIDDEN", 403, "team_admin_required"]);
    expect(applied).toEqual([]);
    accessOk = true;
    await call(billingRouter.resume, { teamId: "team-1" }, { context });
    expect(applied).toEqual([{ scope: "team", ownerId: "team-1", action: "resume" }]);
  });

  test("cancel or resume without an active subscription is a declared conflict", async () => {
    applyResult = false;
    expect(await refusalOf(call(billingRouter.resume, {}, { context }))).toEqual(["CONFLICT", 409, "no_subscription"]);
  });
});
