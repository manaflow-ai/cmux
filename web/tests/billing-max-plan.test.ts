import { describe, expect, test } from "bun:test";

import {
  GO_PLAN_ID,
  MAX_PLAN_ID,
  PRO_PLAN_ID,
  highestPersonalPlanId,
  isPaidPlanId,
  isPersonalPlanId,
  resolveProPlanStatus,
  syncProPlanMetadata,
} from "../services/billing/pro";
import { personalPlanIdForSubscription } from "../services/billing/purchase";
import { MAX_PRICING_USD } from "../services/billing/plans";
import { resolveVmEntitlements, maxMemoryMbForPlan } from "../services/vms/entitlements";

const lease = { refresh: async () => undefined } as never;

describe("Max as a personal plan", () => {
  test("Go is a paid personal plan below Pro", () => {
    expect(isPaidPlanId(GO_PLAN_ID)).toBe(true);
    expect(isPersonalPlanId(GO_PLAN_ID)).toBe(true);
    expect(highestPersonalPlanId([GO_PLAN_ID, "pro", "max"])).toBe("max");
    expect(personalPlanIdForSubscription({
      items: { data: [{ price: { lookup_key: "cmux-go-monthly-10" } }] },
      metadata: {},
    } as never)).toBe(GO_PLAN_ID);
  });
  test("a personal Max plan unlocks large machines in a Team without changing its seat limit", () => {
    const user = { update: async () => undefined, id: "user-max", isAnonymous: false, billingCustomerType: "team", billingTeamId: "team-1", billingPlanId: "team", billingSeats: 3, userBillingPlanId: "max", teams: [{ id: "team-1", billingPlanId: "team", billingSeats: 3 }] } as never;
    for (const options of [{}, { requestedBillingTeamId: "team-1" }]) {
      const result = resolveVmEntitlements(user, {}, options);
      expect(result.planId).toBe("max");
      expect(result.maxActiveVms).toBe(150);
      expect(result.billingTeamId).toBe("team-1");
    }
  });

  test("legacy memory overrides cannot sell Max sizes to Pro", () => {
    expect(maxMemoryMbForPlan("pro", { CMUX_VM_PAID_MAX_MEMORY_MB: "65536" })).toBe(24576);
    expect(maxMemoryMbForPlan("pro", { CMUX_VM_PLAN_PRO_MAX_MEMORY_MB: "65536" })).toBe(24576);
  });
  test("max is paid, personal, and outranks pro", () => {
    expect(isPaidPlanId("max")).toBe(true);
    expect(isPersonalPlanId("max")).toBe(true);
    expect(isPersonalPlanId("team")).toBe(false);
    expect(highestPersonalPlanId(["pro", "max", "team", null])).toBe("max");
    expect(highestPersonalPlanId(["pro"])).toBe("pro");
    expect(highestPersonalPlanId(["team", "founders"])).toBeNull();
  });

  test("a subscription's plan comes from its Price lookup key or known metadata; unknown data grants nothing", () => {
    const withKey = (lookup_key: string | null) => ({
      items: { data: [{ price: { lookup_key } }] },
      metadata: { plan: "pro" },
    }) as never;
    expect(personalPlanIdForSubscription(withKey(MAX_PRICING_USD.month.lookupKey))).toBe(MAX_PLAN_ID);
    expect(personalPlanIdForSubscription(withKey("cmux-pro-monthly"))).toBe(PRO_PLAN_ID);
    // A future Max price keeps the prefix and stays Max even before the code knows it.
    expect(personalPlanIdForSubscription(withKey("cmux-max-monthly-250"))).toBe(MAX_PLAN_ID);
    expect(personalPlanIdForSubscription({
      items: { data: [{ price: {} }] },
      metadata: { plan: "max" },
    } as never)).toBe(MAX_PLAN_ID);
    expect(personalPlanIdForSubscription({
      items: { data: [] },
      metadata: {},
    } as never, { plan: "max" } as never)).toBe(MAX_PLAN_ID);
    expect(personalPlanIdForSubscription({ items: { data: [] }, metadata: {} } as never)).toBeNull();
    expect(personalPlanIdForSubscription(withKey("unrelated-product"))).toBeNull();
  });

  test("the cmuxPlan mirror is rewritten from pro to max on upgrade and cleared on lapse", async () => {
    const writes: unknown[] = [];
    const user = {
      clientReadOnlyMetadata: { cmuxPlan: "pro", other: 1 },
      update: async (options: { clientReadOnlyMetadata: unknown }) => {
        writes.push(options.clientReadOnlyMetadata);
      },
    };
    await syncProPlanMetadata(user, true, lease, "max");
    expect(writes).toEqual([{ cmuxPlan: "max", other: 1 }]);

    const maxUser = { ...user, clientReadOnlyMetadata: { cmuxPlan: "max" } };
    writes.length = 0;
    await syncProPlanMetadata(maxUser, true, lease, "max");
    expect(writes).toEqual([]);
    await syncProPlanMetadata(maxUser, false, lease);
    expect(writes).toEqual([{}]);
  });

  test("plan status reports max and reconciles a stale pro mirror to max", async () => {
    const written: unknown[] = [];
    const user = { update: async () => undefined, id: "user-max", isAnonymous: false, clientReadOnlyMetadata: { cmuxPlan: "pro" } };
    const status = await resolveProPlanStatus(user, {
      activePersonalPlan: async () => "max",
      hasStripeCustomer: async () => true,
      withFreshMetadataUser: async (_userId, operation) =>
        operation({
          ...user,
          update: async (options: { clientReadOnlyMetadata: unknown }) => {
            written.push(options.clientReadOnlyMetadata);
          },
        }, lease),
    });
    expect(status.planId).toBe("max");
    expect(status.isPro).toBe(true);
    expect(status.billingManagement).toBe("stripe");
    expect(status.metadataChanged).toBe(true);
    expect(written).toEqual([{ cmuxPlan: "max" }]);
  });

  test("an operator max grant is Max without a subscription to manage", async () => {
    const status = await resolveProPlanStatus(
      { update: async () => undefined, id: "user-grant", isAnonymous: false, clientReadOnlyMetadata: { cmuxVmPlan: "max" } },
      { activePersonalPlan: async () => null, hasStripeCustomer: async () => false },
    );
    expect(status.planId).toBe("max");
    expect(status.isPro).toBe(true);
    expect(status.billingManagement).toBe("none");
    expect(status.hasManualVmPlanOverride).toBe(true);
  });

  test("the legacy boolean seam still means pro", async () => {
    const status = await resolveProPlanStatus(
      { update: async () => undefined, id: "user-legacy", isAnonymous: false, clientReadOnlyMetadata: { cmuxPlan: "pro" } },
      { hasActiveStripeSubscription: async () => true, hasStripeCustomer: async () => true },
    );
    expect(status.planId).toBe("pro");
    expect(status.metadataChanged).toBe(false);
  });
});
