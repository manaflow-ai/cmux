import { describe, expect, test } from "bun:test";

import type { AccountDeletionUserMutationLease } from "../services/account/deletionLock";
import {
  isNextPlanId,
  nextPlanIdFromMetadata,
} from "../services/billing/nextPlans";
import { nextUpgradePlanId, planIncludes, planTier } from "../services/billing/planTier";
import {
  FREE_PLAN_ID,
  classicManualVmPlanOverride,
  isPaidPlanId,
  isPersonalPlanId,
  reconcileProPlanMetadata,
  resolveProPlanStatus,
  syncProPlanMetadata,
  type FreshProMetadataUserMutation,
  type ProMetadataJson,
} from "../services/billing/pro";
import {
  billingPlanIdFromMetadata,
  resolveBillingTeamFromTeams,
} from "../services/billing/teamResolution";
import {
  isPaidVmPlan,
  maxActiveVmsForPlan,
  maxMemoryMbForPlan,
  resolveVmEntitlements,
} from "../services/vms/entitlements";

const NEXT_IDS = ["next_plus", "next_pro", "next_max"] as const;

type MetadataUser = {
  id?: string;
  clientReadOnlyMetadata?: unknown;
  update: (options: { clientReadOnlyMetadata: ProMetadataJson }) => Promise<void>;
  updates: ProMetadataJson[];
};

function metadataUser(metadata: unknown, id?: string): MetadataUser {
  const user: MetadataUser = {
    id,
    clientReadOnlyMetadata: metadata,
    updates: [],
    update: async (options) => {
      user.updates.push(options.clientReadOnlyMetadata);
      user.clientReadOnlyMetadata = options.clientReadOnlyMetadata;
    },
  };
  return user;
}

const lease: AccountDeletionUserMutationLease = { refresh: async () => undefined };

function fresh(user: MetadataUser): FreshProMetadataUserMutation {
  return async (_userId, operation) => await operation(user, lease);
}

describe("cmux NEXT plan ids in the classic app", () => {
  test("are never paid, personal, tiered, or upgrade targets", () => {
    for (const id of NEXT_IDS) {
      expect(isNextPlanId(id)).toBe(true);
      expect(isPaidPlanId(id)).toBe(false);
      expect(isPersonalPlanId(id)).toBe(false);
      expect(isPaidVmPlan(id)).toBe(false);
      expect(planTier(id)).toBeNull();
      expect(planIncludes(id, "go")).toBe(false);
      expect(nextUpgradePlanId(id)).toBe("pro");
      expect(maxMemoryMbForPlan(id, {})).toBe(maxMemoryMbForPlan(FREE_PLAN_ID, {}));
      expect(maxActiveVmsForPlan(id, {})).toBe(maxActiveVmsForPlan(FREE_PLAN_ID, {}));
    }
    expect(isNextPlanId("pro")).toBe(false);
    expect(isNextPlanId("max")).toBe(false);
  });

  test("billing metadata reads a NEXT plan as no classic plan, never as an error or restriction", () => {
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: "next_pro" })).toBeNull();
    expect(billingPlanIdFromMetadata({ cmuxPlan: "next_max" })).toBeNull();
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: "next_max", cmuxPlan: "next_pro" })).toBeNull();
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: " NEXT_PRO " })).toBeNull();
  });

  test("a classic plan held alongside a NEXT plan stays the classic plan", () => {
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: "next_pro", cmuxPlan: "pro" })).toBe("pro");
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: "next_pro", cmuxPlan: "max" })).toBe("max");
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: "founders", cmuxPlan: "next_max" })).toBe("founders");
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: "pro", cmuxPlan: "next_max" })).toBe("pro");
    // An explicit free override keeps its operator restriction.
    expect(billingPlanIdFromMetadata({ cmuxVmPlan: "free", cmuxPlan: "next_pro" })).toBe("free");
  });

  test("a team with only a NEXT plan is not picked as the paid classic billing team", () => {
    const team = resolveBillingTeamFromTeams([
      { id: "a-next", displayName: "Next", clientReadOnlyMetadata: { cmuxVmPlan: "next_max" } },
      { id: "b-pro", displayName: "Pro", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
    ]);
    expect(team?.id).toBe("b-pro");
    expect(resolveBillingTeamFromTeams([
      { id: "a", displayName: null, clientReadOnlyMetadata: { cmuxPlan: "next_pro" } },
      { id: "b", displayName: null, clientReadOnlyMetadata: {} },
    ])).toBeNull();
  });

  test("Cloud VM entitlements for a NEXT-only account are free, and a classic plan wins", () => {
    const base = {
      id: "u1",
      displayName: null,
      primaryEmail: "pat@example.com",
      billingCustomerType: "user" as const,
      billingTeamId: "u1",
      selectedTeamId: null,
      teams: [],
      teamIds: [],
      billingSeats: null,
    };
    const nextOnly = resolveVmEntitlements({
      ...base,
      userBillingPlanId: billingPlanIdFromMetadata({ cmuxVmPlan: "next_max" }),
      billingPlanId: billingPlanIdFromMetadata({ cmuxVmPlan: "next_max" }),
    }, {});
    expect(nextOnly.planId).toBe("free");
    const both = billingPlanIdFromMetadata({ cmuxVmPlan: "next_max", cmuxPlan: "pro" });
    const classic = resolveVmEntitlements({ ...base, userBillingPlanId: both, billingPlanId: both }, {});
    expect(classic.planId).toBe("pro");
    expect(classic.maxActiveVms).toBeGreaterThan(0);
  });

  test("the NEXT grant slot (cmuxNextVmPlan) is invisible to classic readers and read by NEXT readers", () => {
    expect(billingPlanIdFromMetadata({ cmuxNextVmPlan: "next_max" })).toBeNull();
    expect(billingPlanIdFromMetadata({ cmuxNextVmPlan: "next_max", cmuxVmPlan: "pro" })).toBe("pro");
    expect(billingPlanIdFromMetadata({ cmuxNextVmPlan: "free", cmuxPlan: "pro" })).toBe("pro");
    expect(classicManualVmPlanOverride({ cmuxNextVmPlan: "next_pro" })).toBeNull();
    expect(classicManualVmPlanOverride({ cmuxNextVmPlan: "next_pro", cmuxVmPlan: "founders" })).toBe("founders");
    expect(nextPlanIdFromMetadata({ cmuxNextVmPlan: "next_max", cmuxVmPlan: "pro" })).toBe("next_max");
    expect(nextPlanIdFromMetadata({ cmuxNextVmPlan: "free", cmuxVmPlan: "next_pro" })).toBe("next_pro");
    expect(nextPlanIdFromMetadata({ cmuxNextVmPlan: "pro" })).toBeNull();
  });

  test("a NEXT grant is not a classic override, so classic plan status ignores it", async () => {
    expect(classicManualVmPlanOverride({ cmuxVmPlan: "next_pro" })).toBeNull();
    expect(classicManualVmPlanOverride({ cmuxVmPlan: "pro" })).toBe("pro");
    const user = metadataUser({ cmuxVmPlan: "next_max" }, "u1");
    const status = await resolveProPlanStatus(user, {
      activePersonalPlan: async () => null,
      activeApplePlan: async () => null,
      hasStripeCustomer: async () => false,
      withFreshMetadataUser: fresh(user),
      environment: {},
    });
    expect(status.planId).toBe(FREE_PLAN_ID);
    expect(status.isPro).toBe(false);
    expect(status.hasManualVmPlanOverride).toBe(false);
    expect(user.updates).toEqual([]);
  });

  test("a NEXT grant does not freeze the classic mirror: a Stripe Pro purchase still lands", async () => {
    const user = metadataUser({ cmuxVmPlan: "next_pro" }, "u1");
    const status = await resolveProPlanStatus(user, {
      activePersonalPlan: async () => "pro",
      activeApplePlan: async () => null,
      hasStripeCustomer: async () => true,
      withFreshMetadataUser: fresh(user),
      environment: {},
    });
    expect(status.planId).toBe("pro");
    expect(user.clientReadOnlyMetadata).toEqual({ cmuxVmPlan: "next_pro", cmuxPlan: "pro" });

    const lapsed = metadataUser({ cmuxVmPlan: "next_pro", cmuxPlan: "pro" }, "u2");
    expect(await reconcileProPlanMetadata(lapsed, {
      activePersonalPlan: async () => null,
      activeApplePlan: async () => null,
      withFreshMetadataUser: fresh(lapsed),
    })).toBe(true);
    expect(lapsed.clientReadOnlyMetadata).toEqual({ cmuxVmPlan: "next_pro" });
  });

  test("the classic mirror never clears a NEXT subscription and hands cmuxPlan back to it", async () => {
    const nextOnly = metadataUser({ cmuxPlan: "next_pro", cmuxNextPlan: "next_pro" }, "u1");
    await syncProPlanMetadata(nextOnly, false, lease, "pro", null);
    expect(nextOnly.updates).toEqual([]);

    const both = metadataUser({ cmuxPlan: "next_max", cmuxNextPlan: "next_max" }, "u2");
    await syncProPlanMetadata(both, true, lease, "pro", null);
    expect(both.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro", cmuxNextPlan: "next_max" });
    expect(nextPlanIdFromMetadata(both.clientReadOnlyMetadata)).toBe("next_max");
    expect(billingPlanIdFromMetadata(both.clientReadOnlyMetadata)).toBe("pro");

    await syncProPlanMetadata(both, false, lease, "pro", null);
    expect(both.clientReadOnlyMetadata).toEqual({ cmuxPlan: "next_max", cmuxNextPlan: "next_max" });
    expect(billingPlanIdFromMetadata(both.clientReadOnlyMetadata)).toBeNull();
  });
});
