import { describe, expect, test } from "bun:test";

import { readIdentitySnapshot, writeIdentitySnapshot } from "../services/auth/identitySnapshot";
import {
  lockedMemoryOptionsMbForPlan,
  maxMemoryMbForPlan,
  maxVcpusForPlan,
  memoryOptionsMbForPlan,
  resolveVmEntitlements,
  resourcePoolPolicyForPlan,
  teamVmLimits,
  upgradePlanForMemory,
} from "../services/vms/entitlements";
import type { AuthedUser } from "../services/vms/auth";
import {
  parseTeamEntitlementOverrideInput,
  teamEntitlementOverrideFromMetadata,
  TeamEntitlementOverrideInvalidError,
  type TeamEntitlementOverride,
} from "../services/vms/teamEntitlementOverride";

const GB = 1024;
const env: Record<string, string | undefined> = {};

// The example deal: a team of 8 at $800/month with 40 machines, a 320 vCPU /
// 640 GB pool, and machines up to 32 vCPU / 64 GB.
const deal: TeamEntitlementOverride = {
  maxActiveVms: 40,
  poolVcpus: 320,
  poolMemoryMb: 640 * GB,
  maxMemoryMb: 64 * GB,
  planLabel: "Team (custom)",
  monthlyPriceCents: 80_000,
};

function teamUser(input: {
  readonly planId: string | null;
  readonly seats?: number | null;
  readonly override?: TeamEntitlementOverride | null;
  readonly userPlanId?: string | null;
}): AuthedUser {
  return {
    id: "user-1",
    displayName: null,
    primaryEmail: "owner@example.com",
    billingCustomerType: "team",
    billingTeamId: "team-deal",
    selectedTeamId: "team-deal",
    teams: [{
      id: "team-deal",
      displayName: "Deal team",
      billingPlanId: input.planId,
      billingSeats: input.seats ?? 8,
      ...(input.override ? { entitlementOverride: input.override } : {}),
    }],
    teamIds: ["team-deal"],
    userBillingPlanId: input.userPlanId ?? null,
    billingPlanId: input.planId,
    billingSeats: input.seats ?? 8,
    ...(input.override ? { billingEntitlementOverride: input.override } : {}),
  };
}

describe("team entitlement override", () => {
  test("a Team with the custom deal gets its machines, pool, and sizes", () => {
    for (const options of [{}, { requestedBillingTeamId: "team-deal" }]) {
      const entitlements = resolveVmEntitlements(teamUser({ planId: "team", override: deal }), env, options);
      expect(entitlements.planId).toBe("team");
      expect(entitlements.maxActiveVms).toBe(40);
      expect(entitlements.resourcePool).toEqual({ vcpus: 320, memoryMb: 640 * GB });
      const override = entitlements.entitlementOverride;
      expect(maxMemoryMbForPlan(entitlements.planId, env, override)).toBe(64 * GB);
      expect(maxVcpusForPlan(entitlements.planId, env, override)).toBe(32);
      expect(memoryOptionsMbForPlan(entitlements.planId, env, override)).toContain(64 * GB);
      expect(lockedMemoryOptionsMbForPlan(entitlements.planId, env, override)).toEqual({ memoryOptionsMb: [], upgradePlanId: null });
      // Workflows rebuild the pool from the plan, count, and override alone.
      expect(resourcePoolPolicyForPlan(entitlements.planId, entitlements.maxActiveVms, env, override)?.capacity)
        .toEqual({ vcpus: 320, memoryMb: 640 * GB });
    }
  });

  test("without the deal the same team keeps the per-seat defaults", () => {
    const entitlements = resolveVmEntitlements(teamUser({ planId: "team" }), env);
    expect(entitlements.maxActiveVms).toBe(40);
    expect(entitlements.resourcePool).toEqual({ vcpus: 160, memoryMb: 320 * GB });
    expect(entitlements.entitlementOverride).toBeNull();
    expect(maxMemoryMbForPlan(entitlements.planId, env, entitlements.entitlementOverride)).toBe(16 * GB);
  });

  test("a partial deal keeps plan defaults for the fields it leaves blank", () => {
    const partial = { ...deal, maxActiveVms: null, poolMemoryMb: null, maxMemoryMb: null };
    const entitlements = resolveVmEntitlements(teamUser({ planId: "team", seats: 2, override: partial }), env);
    expect(entitlements.maxActiveVms).toBe(10);
    expect(entitlements.resourcePool).toEqual({ vcpus: 320, memoryMb: 80 * GB });
    expect(maxMemoryMbForPlan("team", env, entitlements.entitlementOverride)).toBe(16 * GB);

    // A count without a pool scales the pool with paid seats, not the count.
    const countOnly = { ...partial, maxActiveVms: 100, poolVcpus: null };
    const counted = resolveVmEntitlements(teamUser({ planId: "team", seats: 2, override: countOnly }), env);
    expect(counted.maxActiveVms).toBe(100);
    expect(counted.resourcePool).toEqual({ vcpus: 40, memoryMb: 80 * GB });
  });

  test("a deal never makes a free or Plus team paid", () => {
    for (const planId of [null, "free", "go"]) {
      const entitlements = resolveVmEntitlements(teamUser({ planId, override: deal }), env);
      expect(entitlements.entitlementOverride).toBeNull();
      expect(entitlements.maxActiveVms).toBe(planId === "go" ? 1 : 0);
    }
    expect(teamVmLimits({ planId: null, seats: 8, override: deal }).applies).toBe(false);
  });

  test("a member's personal Pro or Max does not switch on an unpaid team's deal", () => {
    for (const userPlanId of ["pro", "max"]) {
      for (const options of [{}, { requestedBillingTeamId: "team-deal" }]) {
        const user = { ...teamUser({ planId: null, seats: 2, override: deal, userPlanId }), billingPlanId: userPlanId };
        const entitlements = resolveVmEntitlements(user, env, options);
        expect(entitlements.entitlementOverride).toBeNull();
        expect(entitlements.maxActiveVms).not.toBe(deal.maxActiveVms);
        expect(entitlements.resourcePool?.vcpus).not.toBe(deal.poolVcpus);
      }
    }
  });

  test("a deal raises the size ceiling but never lowers it", () => {
    expect(maxMemoryMbForPlan("team", env, { ...deal, maxMemoryMb: 4 * GB })).toBe(16 * GB);
    expect(maxMemoryMbForPlan("team", env, { ...deal, maxMemoryMb: 32 * GB })).toBe(32 * GB);
  });

  test("a personal Max member keeps the larger of Max and the deal", () => {
    const small = { ...deal, poolVcpus: 40, poolMemoryMb: 80 * GB, maxMemoryMb: 16 * GB };
    const entitlements = resolveVmEntitlements(teamUser({ planId: "team", override: small, userPlanId: "max" }), env);
    expect(entitlements.planId).toBe("max");
    expect(entitlements.resourcePool).toEqual({ vcpus: 80, memoryMb: 160 * GB });
    expect(maxMemoryMbForPlan("max", env, entitlements.entitlementOverride)).toBe(64 * GB);
  });

  test("a custom size ceiling is not sold as a plan upgrade", () => {
    const capped = { ...deal, maxMemoryMb: 32 * GB };
    expect(upgradePlanForMemory(64 * GB, "team", env, capped)).toBeNull();
    expect(lockedMemoryOptionsMbForPlan("team", env, capped)).toEqual({ memoryOptionsMb: [64 * GB], upgradePlanId: null });
    expect(upgradePlanForMemory(64 * GB, "team", env)).toBe("max");
  });

  test("the admin view compares plan defaults with the deal", () => {
    expect(teamVmLimits({ planId: "team", seats: 8, override: deal })).toEqual({
      defaults: { maxActiveVms: 40, poolVcpus: 160, poolMemoryMb: 320 * GB, maxMemoryMb: 16 * GB, maxVcpus: 8 },
      effective: { maxActiveVms: 40, poolVcpus: 320, poolMemoryMb: 640 * GB, maxMemoryMb: 64 * GB, maxVcpus: 32 },
      applies: true,
      planHonorsOverride: true,
    });
    // A freshly granted Team with no deal yet is eligible, not "unpaid".
    expect(teamVmLimits({ planId: "team", seats: 1, override: null })).toMatchObject({ applies: false, planHonorsOverride: true });
    expect(teamVmLimits({ planId: "go", seats: 1, override: deal }).planHonorsOverride).toBe(false);
  });
});

describe("override parsing", () => {
  test("admin input is strict and an empty deal clears", () => {
    expect(parseTeamEntitlementOverrideInput(deal)).toEqual(deal);
    expect(parseTeamEntitlementOverrideInput(null)).toBeNull();
    expect(parseTeamEntitlementOverrideInput({ planLabel: "  " })).toBeNull();
    for (const bad of [
      { maxActiveVms: 0 },
      { poolVcpus: 1.5 },
      { maxMemoryMb: 12 * GB },
      { maxActiveVms: "40" },
      { surprise: 1 },
      { planLabel: "x".repeat(61) },
      [],
    ]) {
      expect(() => parseTeamEntitlementOverrideInput(bad)).toThrow(TeamEntitlementOverrideInvalidError);
    }
  });

  test("stored metadata is lenient: a bad field falls back instead of failing auth", () => {
    expect(teamEntitlementOverrideFromMetadata({ cmuxEntitlementOverride: deal })).toEqual(deal);
    expect(teamEntitlementOverrideFromMetadata({
      cmuxEntitlementOverride: { maxActiveVms: -3, poolVcpus: 64, maxMemoryMb: 12 * GB },
    })).toEqual({ maxActiveVms: null, poolVcpus: 64, poolMemoryMb: null, maxMemoryMb: null, planLabel: null, monthlyPriceCents: null });
    expect(teamEntitlementOverrideFromMetadata({ cmuxEntitlementOverride: "40 machines" })).toBeNull();
    expect(teamEntitlementOverrideFromMetadata(null)).toBeNull();
  });
});

describe("identity snapshot", () => {
  test("the billing team's deal survives a snapshot round trip", async () => {
    const rows: Record<string, unknown>[] = [];
    const db = {
      select: () => ({ from: () => ({ where: () => ({ limit: async () => rows }) }) }),
      insert: () => ({
        values: (values: Record<string, unknown>) => ({
          onConflictDoUpdate: async () => {
            rows.splice(0, rows.length, { ...values, refreshedAt: new Date() });
          },
        }),
      }),
      delete: () => ({ where: async () => undefined }),
    } as never;
    const user = teamUser({ planId: "team", override: deal });
    await writeIdentitySnapshot(user, { completeTeamList: true }, db);
    const read = await readIdentitySnapshot(user.id, 60_000, db);
    expect(read?.user.billingEntitlementOverride).toEqual(deal);
    expect(resolveVmEntitlements(read!.user, env).maxActiveVms).toBe(40);
  });
});
