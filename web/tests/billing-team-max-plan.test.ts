import { describe, expect, test } from "bun:test";

import { planIncludes, planTier, planTierRank } from "../services/billing/planTier";
import {
  PAID_PLAN_IDS,
  TEAM_MAX_PLAN_ID,
  TEAM_PLAN_ID,
  isPaidPlanId,
  isPersonalPlanId,
  isTeamPlanId,
  syncTeamPlanMetadata,
} from "../services/billing/pro";
import { TEAM_MAX_PRICING_USD, TEAM_PRICING_USD } from "../services/billing/plans";
import { teamPlanIdForSubscription } from "../services/billing/subscriptionPlan";
import { seatDecision } from "../services/billing/teamSeats";
import { billingPlanIdFromMetadata } from "../services/billing/teamResolution";
import {
  isPaidVmPlan,
  lockedMemoryOptionsMbForPlan,
  maxActiveVmsForPlan,
  installedClientPlanId,
  maxDiskMbForPlan,
  maxMemoryMbForPlan,
  maxTierUpgradePlanId,
  maxVcpusForPlan,
  memoryOptionsMbForPlan,
  resolveVmEntitlements,
  resourcePoolForPlan,
  upgradePlanForMemory,
} from "../services/vms/entitlements";

const env: Record<string, string | undefined> = {};
const GB = 1024;

describe("Team Max plan identity and price", () => {
  test("team_max is a paid, team-scoped plan at the Max tier, not a personal plan", () => {
    expect(TEAM_MAX_PLAN_ID).toBe("team_max");
    expect(PAID_PLAN_IDS).toContain("team_max");
    expect(isPaidPlanId("team_max")).toBe(true);
    expect(isPaidVmPlan("team_max")).toBe(true);
    expect(isPersonalPlanId("team_max")).toBe(false);
    expect(isTeamPlanId("team")).toBe(true);
    expect(isTeamPlanId("team_max")).toBe(true);
    expect(isTeamPlanId("max")).toBe(false);
    expect(planTier("team_max")).toBe("max");
    expect(planIncludes("team_max", "max")).toBe(true);
    expect(planIncludes("team", "max")).toBe(false);
    expect(planTierRank("team_max")).toBeGreaterThan(planTierRank("team"));
  });

  test("Team Max is $220 per seat per month on its own lookup key, monthly only", () => {
    expect(TEAM_MAX_PRICING_USD.month).toEqual({
      billedAmount: 220,
      monthlyEquivalent: 220,
      discountPercent: 0,
      lookupKey: "cmux-team-max-monthly-220",
    });
    expect("year" in TEAM_MAX_PRICING_USD).toBe(false);
    expect(TEAM_PRICING_USD.month.lookupKey).toBe("cmux-team-monthly-60");
  });
});

/**
 * Free / Team / Team Max across every server-side Cloud gate, at one and at
 * three paid seats. Team Max gets the Max sizes for every member and the Max
 * pool per seat; Team keeps the Pro sizes and is offered Team Max.
 */
describe("Free / Team / Team Max entitlement matrix", () => {
  const rows = [
    {
      plan: "free",
      maxMemoryMb: 8 * GB,
      maxVcpus: 4,
      maxDiskMb: 128 * GB,
      machines: { 1: 0, 3: 0 },
      pool: { 1: null, 3: null },
      lockedUpgrade: "pro",
    },
    {
      plan: "team",
      maxMemoryMb: 16 * GB,
      maxVcpus: 8,
      maxDiskMb: 128 * GB,
      machines: { 1: 5, 3: 15 },
      pool: { 1: { vcpus: 20, memoryMb: 40 * GB }, 3: { vcpus: 60, memoryMb: 120 * GB } },
      lockedUpgrade: "team_max",
    },
    {
      plan: "team_max",
      maxMemoryMb: 64 * GB,
      maxVcpus: 32,
      maxDiskMb: 256 * GB,
      machines: { 1: 5, 3: 15 },
      pool: { 1: { vcpus: 80, memoryMb: 160 * GB }, 3: { vcpus: 240, memoryMb: 480 * GB } },
      lockedUpgrade: null,
    },
  ] as const;

  for (const row of rows) {
    test(`${row.plan}: size ceilings, disk, machines per seat, and pool per seat`, () => {
      expect(maxMemoryMbForPlan(row.plan, env)).toBe(row.maxMemoryMb);
      expect(maxVcpusForPlan(row.plan, env)).toBe(row.maxVcpus);
      expect(maxDiskMbForPlan(row.plan, env)).toBe(row.maxDiskMb);
      for (const seats of [1, 3] as const) {
        const machines = maxActiveVmsForPlan(row.plan, env, { seats });
        expect(machines).toBe(row.machines[seats]);
        expect(resourcePoolForPlan(row.plan, machines)).toEqual(row.pool[seats]);
      }
      expect(lockedMemoryOptionsMbForPlan(row.plan, env).upgradePlanId).toBe(row.lockedUpgrade);
    });
  }

  test("Team Max starts the 24, 32, and 64 GB sizes; Team is offered Team Max for each, not personal Max", () => {
    for (const memoryMb of [24 * GB, 32 * GB, 64 * GB]) {
      expect(memoryOptionsMbForPlan("team_max", env)).toContain(memoryMb);
      expect(memoryOptionsMbForPlan("team", env)).not.toContain(memoryMb);
      expect(upgradePlanForMemory(memoryMb, "team", env)).toBe("team_max");
      expect(upgradePlanForMemory(memoryMb, "team_max", env)).toBeNull();
    }
    expect(lockedMemoryOptionsMbForPlan("team_max", env).memoryOptionsMb).toEqual([]);
  });

  test("installed clients that predate Team Max see its tier, Max, as the plan id", () => {
    expect(installedClientPlanId("team_max")).toBe("max");
    for (const plan of ["free", "go", "pro", "max", "team", "founders"]) {
      expect(installedClientPlanId(plan)).toBe(plan);
    }
  });

  test("the pool upgrade names Team Max for a Team, Max for personal plans, nothing at the Max tier", () => {
    expect(maxTierUpgradePlanId("team")).toBe("team_max");
    expect(maxTierUpgradePlanId("pro")).toBe("max");
    expect(maxTierUpgradePlanId("founders")).toBe("max");
    expect(maxTierUpgradePlanId("team_max")).toBeNull();
    expect(maxTierUpgradePlanId("max")).toBeNull();
  });
});

describe("Team Max VM entitlements for team members", () => {
  const member = (input: { personal: string | null; team: string; seats: number }) => ({
    id: "user-1",
    isAnonymous: false,
    billingCustomerType: "team",
    billingTeamId: "team-1",
    billingPlanId: input.team,
    billingSeats: input.seats,
    userBillingPlanId: input.personal,
    teams: [{ id: "team-1", billingPlanId: input.team, billingSeats: input.seats }],
  }) as never;

  test("every member of a 3-seat Team Max team gets Max sizes and the per-seat Max pool", () => {
    for (const personal of [null, "pro", "go"]) {
      for (const options of [{}, { requestedBillingTeamId: "team-1" }]) {
        const result = resolveVmEntitlements(member({ personal, team: "team_max", seats: 3 }), env, options);
        expect(result.planId).toBe("team_max");
        expect(result.maxActiveVms).toBe(15);
        expect(result.resourcePool).toEqual({ vcpus: 240, memoryMb: 480 * GB });
        expect(maxMemoryMbForPlan(result.planId, env)).toBe(64 * GB);
      }
    }
  });

  test("a personal Max member of a Team Max team uses the larger Team Max pool", () => {
    const result = resolveVmEntitlements(member({ personal: "max", team: "team_max", seats: 3 }), env);
    expect(result.planId).toBe("team_max");
    expect(result.maxActiveVms).toBe(15);
    expect(result.resourcePool).toEqual({ vcpus: 240, memoryMb: 480 * GB });
  });

  test("a personal Max member of a Team team keeps Max sizes inside the Team allowance", () => {
    const result = resolveVmEntitlements(member({ personal: "max", team: "team", seats: 3 }), env);
    expect(result.planId).toBe("max");
    expect(result.maxActiveVms).toBe(15);
    expect(result.resourcePool).toEqual({ vcpus: 80, memoryMb: 160 * GB });
  });

  test("a 1-seat Team Max team gets 5 machines and 80 vCPU / 160 GB", () => {
    const result = resolveVmEntitlements(member({ personal: null, team: "team_max", seats: 1 }), env);
    expect(result.maxActiveVms).toBe(5);
    expect(result.resourcePool).toEqual({ vcpus: 80, memoryMb: 160 * GB });
  });
});

describe("Team Max subscriptions", () => {
  const subscriptionOn = (lookupKey: string | null, plan = "team") => ({
    items: { data: [{ price: { lookup_key: lookupKey } }] },
    metadata: { app: "cmux", plan, stackTeamId: "team-1" },
  }) as never;

  test("the team plan comes from the Price, so an in-place switch relabels the row", () => {
    expect(teamPlanIdForSubscription(subscriptionOn("cmux-team-max-monthly-220"))).toBe("team_max");
    // Checkout stamped plan=team before the switch; the Price wins.
    expect(teamPlanIdForSubscription(subscriptionOn("cmux-team-max-monthly-220", "team"))).toBe("team_max");
    expect(teamPlanIdForSubscription(subscriptionOn("cmux-team-monthly-60", "team_max"))).toBe("team");
    expect(teamPlanIdForSubscription(subscriptionOn("cmux-team-yearly-576"))).toBe("team");
    // Without a lookup key the checkout metadata decides.
    expect(teamPlanIdForSubscription(subscriptionOn(null, "team_max"))).toBe("team_max");
    expect(teamPlanIdForSubscription(subscriptionOn(null, "team"))).toBe("team");
  });

  test("the team metadata mirror writes cmuxPlan team_max with seats, and clears it on lapse", async () => {
    const writes: unknown[] = [];
    const team = (metadata: Record<string, unknown>) => ({
      clientReadOnlyMetadata: metadata,
      update: async (options: { clientReadOnlyMetadata: unknown }) => {
        writes.push(options.clientReadOnlyMetadata);
      },
    });
    await syncTeamPlanMetadata(team({ cmuxPlan: "team", cmuxSeats: 3, other: 1 }), true, 3, TEAM_MAX_PLAN_ID);
    expect(writes).toEqual([{ cmuxPlan: "team_max", cmuxSeats: 3, other: 1 }]);
    writes.length = 0;
    await syncTeamPlanMetadata(team({ cmuxPlan: "team_max", cmuxSeats: 3 }), true, 3, TEAM_MAX_PLAN_ID);
    expect(writes).toEqual([]);
    await syncTeamPlanMetadata(team({ cmuxPlan: "team_max", cmuxSeats: 3 }), true, 3, TEAM_PLAN_ID);
    expect(writes).toEqual([{ cmuxPlan: "team", cmuxSeats: 3 }]);
    writes.length = 0;
    await syncTeamPlanMetadata(team({ cmuxPlan: "team_max", cmuxSeats: 3, cmuxVmPlan: "pro" }), false);
    expect(writes).toEqual([{ cmuxVmPlan: "pro" }]);
  });

  test("the seat reconciler bills Team Max seats like Team seats", () => {
    expect(seatDecision({ planId: "team_max", hasTeamSubscription: true, memberCount: 4, quantity: 3 }))
      .toEqual({ action: "update", from: 3, to: 4 });
    expect(seatDecision({ planId: "team_max", hasTeamSubscription: true, memberCount: 3, quantity: 3 }))
      .toEqual({ action: "noop", quantity: 3 });
  });

  test("a paid Team Max mirror is not hidden by a lower operator grant", () => {
    expect(billingPlanIdFromMetadata({ cmuxPlan: "team_max" })).toBe("team_max");
    expect(billingPlanIdFromMetadata({ cmuxPlan: "team_max", cmuxVmPlan: "team" })).toBe("team_max");
    expect(billingPlanIdFromMetadata({ cmuxPlan: "team_max", cmuxVmPlan: "pro" })).toBe("team_max");
    expect(billingPlanIdFromMetadata({ cmuxPlan: "team_max", cmuxVmPlan: "free" })).toBe("free");
  });
});
