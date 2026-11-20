import { describe, expect, test } from "bun:test";

import {
  nextUpgradePlanId,
  planIncludes,
  planTier,
  planTierRank,
} from "../services/billing/planTier";
import {
  isPaidVmPlan,
  lockedMemoryOptionsMbForPlan,
  maxActiveVmsForPlan,
  maxDiskMbForPlan,
  maxMemoryMbForPlan,
  maxVcpusForPlan,
  memoryOptionsMbForPlan,
  resourcePoolForPlan,
  upgradePlanForMemory,
} from "../services/vms/entitlements";

// Defaults only: operator env overrides are covered by the entitlement suites.
const env: Record<string, string | undefined> = {};
const GB = 1024;

describe("plan tier ordering", () => {
  test("every plan ID maps to a tier, with Team and Founder's Edition counted as Pro", () => {
    expect(planTier("free")).toBe("free");
    expect(planTier("go")).toBe("go");
    expect(planTier(" PRO ")).toBe("pro");
    expect(planTier("team")).toBe("pro");
    expect(planTier("founders")).toBe("pro");
    expect(planTier("max")).toBe("max");
    expect(planTier("enterprise")).toBeNull();
    expect(planTier("constructor")).toBeNull();
    expect(planTier(null)).toBeNull();
    expect(planTierRank("free")).toBeLessThan(planTierRank("go"));
    expect(planTierRank("go")).toBeLessThan(planTierRank("pro"));
    expect(planTierRank("pro")).toBeLessThan(planTierRank("max"));
  });

  test("Max includes everything Pro includes, and Pro does not include Max", () => {
    expect(planIncludes("max", "pro")).toBe(true);
    expect(planIncludes("max", "max")).toBe(true);
    expect(planIncludes("pro", "pro")).toBe(true);
    expect(planIncludes("pro", "max")).toBe(false);
    expect(planIncludes("team", "pro")).toBe(true);
    expect(planIncludes("go", "pro")).toBe(false);
    expect(planIncludes("free", "go")).toBe(false);
    expect(planIncludes("unknown", "go")).toBe(false);
  });

  test("the next upgrade is the tier above, and nothing above Max", () => {
    expect(nextUpgradePlanId("free")).toBe("pro");
    expect(nextUpgradePlanId("go")).toBe("pro");
    expect(nextUpgradePlanId("pro")).toBe("max");
    expect(nextUpgradePlanId("team")).toBe("max");
    expect(nextUpgradePlanId("max")).toBeNull();
  });
});

/**
 * Free / Pro / Max across every server-side Cloud gate. Max must get every
 * Pro gate plus the Max-only sizes and pool; Pro must be refused the Max-only
 * rows with Max as the upgrade; Free gets neither.
 */
describe("Cloud entitlement matrix", () => {
  const rows = [
    {
      plan: "free",
      paid: false,
      maxMemoryMb: 8 * GB,
      maxVcpus: 4,
      maxDiskMb: 128 * GB,
      maxActiveVms: 0,
      pool: null,
      lockedUpgrade: "pro",
    },
    {
      plan: "go",
      paid: true,
      maxMemoryMb: 16 * GB,
      maxVcpus: 8,
      maxDiskMb: 128 * GB,
      maxActiveVms: 1,
      pool: null,
      lockedUpgrade: "max",
    },
    {
      plan: "pro",
      paid: true,
      maxMemoryMb: 16 * GB,
      maxVcpus: 8,
      maxDiskMb: 128 * GB,
      maxActiveVms: 5,
      pool: { vcpus: 20, memoryMb: 40 * GB },
      lockedUpgrade: "max",
    },
    {
      plan: "max",
      paid: true,
      maxMemoryMb: 64 * GB,
      maxVcpus: 32,
      maxDiskMb: 256 * GB,
      maxActiveVms: 5,
      pool: { vcpus: 80, memoryMb: 160 * GB },
      lockedUpgrade: null,
    },
  ] as const;

  for (const row of rows) {
    test(`${row.plan}: provisioning, size ceilings, machine count and pool`, () => {
      expect(isPaidVmPlan(row.plan)).toBe(row.paid);
      expect(maxMemoryMbForPlan(row.plan, env)).toBe(row.maxMemoryMb);
      expect(maxVcpusForPlan(row.plan, env)).toBe(row.maxVcpus);
      expect(maxDiskMbForPlan(row.plan, env)).toBe(row.maxDiskMb);
      expect(maxActiveVmsForPlan(row.plan, env)).toBe(row.maxActiveVms);
      const pool = resourcePoolForPlan(row.plan, maxActiveVmsForPlan(row.plan, env));
      expect(pool).toEqual(row.pool);
      expect(lockedMemoryOptionsMbForPlan(row.plan, env).upgradePlanId).toBe(row.lockedUpgrade);
    });
  }

  test("Max can start every Max-only size, and Pro is refused each with Max as the upgrade", () => {
    for (const memoryMb of [24 * GB, 32 * GB, 64 * GB]) {
      expect(memoryOptionsMbForPlan("max", env)).toContain(memoryMb);
      expect(memoryOptionsMbForPlan("pro", env)).not.toContain(memoryMb);
      expect(upgradePlanForMemory(memoryMb, "pro", env)).toBe("max");
      expect(upgradePlanForMemory(memoryMb, "max", env)).toBeNull();
    }
  });

  test("Max keeps every size Pro can start", () => {
    for (const memoryMb of memoryOptionsMbForPlan("pro", env)) {
      expect(memoryOptionsMbForPlan("max", env)).toContain(memoryMb);
    }
    expect(maxActiveVmsForPlan("max", env)!).toBeGreaterThanOrEqual(maxActiveVmsForPlan("pro", env)!);
  });

  test("Free is offered Pro for a Pro size, not Max", () => {
    expect(upgradePlanForMemory(16 * GB, "free", env)).toBe("pro");
    expect(upgradePlanForMemory(16 * GB, "go", env)).toBe("pro");
  });
});
