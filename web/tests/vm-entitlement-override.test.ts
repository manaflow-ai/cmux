import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  VM_ENTITLEMENT_OVERRIDE_MEMORY_OPTIONS_MB,
  validateVmEntitlementOverride,
  vmEntitlementOverrideFromMetadata,
  type VmEntitlementOverride,
} from "../services/vms/entitlementOverride";
import {
  VM_MEMORY_OPTIONS_MB,
  lockedMemoryOptionsMbForPlan,
  maxDiskMbForPlan,
  maxMemoryMbForPlan,
  maxVcpusForPlan,
  memoryOptionsMbForPlan,
  resolveVmEntitlements,
} from "../services/vms/entitlements";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { createVm } from "../services/vms/workflows";
import { vmWorkflowErrorCause } from "../services/vms/errors";

// The issue's example deal: a team of 8 at $800/mo with 40 machines, a
// 320 vCPU / 640 GB pool, and machines up to 32 vCPU / 64 GB.
const DEAL: VmEntitlementOverride = {
  maxActiveVms: 40,
  poolVcpus: 320,
  poolMemoryMb: 640 * 1024,
  maxMemoryMb: 64 * 1024,
  planLabel: "Acme Team",
  monthlyPriceCents: 80_000,
};

function teamUser(input: {
  readonly planId: string;
  readonly userPlanId?: string | null;
  readonly override?: VmEntitlementOverride | null;
}) {
  return {
    id: "user-1",
    isAnonymous: false,
    displayName: null,
    primaryEmail: "a@example.com",
    billingCustomerType: "team",
    billingTeamId: "team-1",
    selectedTeamId: "team-1",
    teamIds: ["team-1"],
    userBillingPlanId: input.userPlanId ?? null,
    billingPlanId: input.planId,
    billingSeats: 8,
    teams: [{
      id: "team-1",
      displayName: "Acme",
      billingPlanId: input.planId,
      billingSeats: 8,
      vmEntitlementOverride: input.override ?? null,
    }],
  } as never;
}

describe("team entitlement override validation", () => {
  test("accepts the example deal and rejects bad fields", () => {
    expect(validateVmEntitlementOverride(DEAL)).toEqual({ ok: true, override: DEAL });
    expect(validateVmEntitlementOverride({})).toEqual({ ok: true, override: null });
    expect(validateVmEntitlementOverride(null)).toEqual({ ok: true, override: null });
    expect(validateVmEntitlementOverride({ maxActiveVms: 0 }).ok).toBe(false);
    expect(validateVmEntitlementOverride({ maxActiveVms: 1.5 }).ok).toBe(false);
    expect(validateVmEntitlementOverride({ maxMemoryMb: 12_000 }).ok).toBe(false);
    expect(validateVmEntitlementOverride({ poolMemoryMb: 4097 }).ok).toBe(false);
    expect(validateVmEntitlementOverride({ maxVms: 40 })).toEqual({ ok: false, field: "maxVms", message: "is not an override field" });
    expect(validateVmEntitlementOverride({ planLabel: "x".repeat(65) }).ok).toBe(false);
    expect(validateVmEntitlementOverride({ monthlyPriceCents: -1 }).ok).toBe(false);
    expect(validateVmEntitlementOverride({ maxMemoryMb: 65536, poolMemoryMb: 32768 }).ok).toBe(false);
    expect(validateVmEntitlementOverride({ maxMemoryMb: 65536, poolVcpus: 16 }).ok).toBe(false);
  });

  test("a malformed stored override is ignored rather than trusted", () => {
    expect(vmEntitlementOverrideFromMetadata({ cmuxVmEntitlementOverride: DEAL })).toEqual(DEAL);
    expect(vmEntitlementOverrideFromMetadata({ cmuxVmEntitlementOverride: { maxActiveVms: "40" } })).toBeNull();
    expect(vmEntitlementOverrideFromMetadata({})).toBeNull();
    // A field from a newer server is dropped, not a reason to lose the deal.
    expect(vmEntitlementOverrideFromMetadata({ cmuxVmEntitlementOverride: { ...DEAL, futureField: 1 } })).toEqual(DEAL);
  });

  test("the override's size ladder matches the create ladder", () => {
    expect(VM_ENTITLEMENT_OVERRIDE_MEMORY_OPTIONS_MB).toEqual(VM_MEMORY_OPTIONS_MB);
  });
});

describe("resolveVmEntitlements with a team override", () => {
  test("the example deal replaces seats x 5 and the per-seat pool", () => {
    const withoutDeal = resolveVmEntitlements(teamUser({ planId: "team" }), {});
    expect(withoutDeal.maxActiveVms).toBe(40);
    expect(withoutDeal.resourcePool).toEqual({ vcpus: 160, memoryMb: 320 * 1024 });

    const result = resolveVmEntitlements(teamUser({ planId: "team", override: DEAL }), {});
    expect(result.planId).toBe("team");
    expect(result.maxActiveVms).toBe(40);
    expect(result.resourcePool).toEqual({ vcpus: 320, memoryMb: 640 * 1024 });
    expect(result.override).toEqual(DEAL);
    // The explicit-team path reads the same team.
    expect(resolveVmEntitlements(teamUser({ planId: "team", override: DEAL }), {}, { requestedBillingTeamId: "team-1" }).resourcePool)
      .toEqual({ vcpus: 320, memoryMb: 640 * 1024 });
  });

  test("a smaller deal lowers the caps; unset fields keep plan defaults", () => {
    const result = resolveVmEntitlements(teamUser({ planId: "team", override: { maxActiveVms: 3, poolVcpus: 12 } }), {});
    expect(result.maxActiveVms).toBe(3);
    // Memory pool keeps the 8-seat plan default instead of following the machine count.
    expect(result.resourcePool).toEqual({ vcpus: 12, memoryMb: 320 * 1024 });
    // A count-only deal keeps both pool dimensions of the plan.
    expect(resolveVmEntitlements(teamUser({ planId: "team", override: { maxActiveVms: 500 } }), {}).resourcePool)
      .toEqual({ vcpus: 160, memoryMb: 320 * 1024 });
  });

  test("a deal on a team without a paid plan never rides a member's personal plan", () => {
    for (const userPlanId of ["pro", "max"]) {
      // As auth resolves it: the team has no plan, so billing falls back to the member's.
      const member = (override: VmEntitlementOverride | null) => ({
        ...(teamUser({ planId: "free", userPlanId }) as Record<string, unknown>),
        billingPlanId: userPlanId,
        teams: [{ id: "team-1", displayName: "Acme", billingPlanId: null, billingSeats: 8, vmEntitlementOverride: override }],
      }) as never;
      for (const options of [{}, { requestedBillingTeamId: "team-1" }]) {
        const withDeal = resolveVmEntitlements(member(DEAL), {}, options);
        const withoutDeal = resolveVmEntitlements(member(null), {}, options);
        expect(withDeal.planId).toBe(userPlanId);
        expect(withDeal.override).toBeUndefined();
        expect(withDeal.maxActiveVms).toBe(withoutDeal.maxActiveVms);
        expect(withDeal.resourcePool).toEqual(withoutDeal.resourcePool);
      }
    }
  });

  test("an override never grants a plan to a free team", () => {
    const result = resolveVmEntitlements(teamUser({ planId: "free", override: DEAL }), {});
    expect(result.planId).toBe("free");
    expect(result.maxActiveVms).toBe(0);
    expect(result.resourcePool).toBeNull();
  });

  test("a personal Max member keeps Max's pool and sizes; the team's deal still sets the machine count", () => {
    const result = resolveVmEntitlements(teamUser({ planId: "team", userPlanId: "max", override: { maxActiveVms: 2, poolVcpus: 10, maxMemoryMb: 8192 } }), {});
    expect(result.planId).toBe("max");
    expect(result.maxActiveVms).toBe(2);
    expect(result.resourcePool?.vcpus).toBeGreaterThanOrEqual(80);
    expect(maxMemoryMbForPlan(result.planId, {}, result.override)).toBe(65536);
  });
});

describe("machine size helpers with an override", () => {
  test("the deal's largest machine opens the 64 GB row and Max's disk tier on Team", () => {
    expect(maxMemoryMbForPlan("team", {})).toBe(16384);
    expect(maxMemoryMbForPlan("team", {}, DEAL)).toBe(65536);
    expect(maxVcpusForPlan("team", {}, DEAL)).toBe(32);
    expect(maxDiskMbForPlan("team", {}, DEAL)).toBe(256 * 1024);
    expect(memoryOptionsMbForPlan("team", {}, DEAL)).toEqual(VM_MEMORY_OPTIONS_MB);
    expect(lockedMemoryOptionsMbForPlan("team", {}, DEAL).memoryOptionsMb).toEqual([]);
  });

  test("Go ignores an override", () => {
    expect(maxMemoryMbForPlan("go", {}, DEAL)).toBe(maxMemoryMbForPlan("go", {}));
  });
});

test("createVm admits a 64 GB machine on Team only with the deal", async () => {
  let creates = 0;
  const repo = {
    beginCreate: () => Effect.sync(() => { creates++; throw new Error("stop after admission"); }),
  } as unknown as VmRepositoryShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, {} as VmProviderGatewayShape),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const caller = {
    userId: "user-1",
    billingCustomerType: "team" as const,
    billingTeamId: "team-1",
    billingPlanId: "team",
    maxActiveVms: 40,
    provider: "freestyle" as const,
    image: "snapshot",
    memoryMb: 65536,
  };
  const outcome = async (program: Effect.Effect<unknown, unknown, never>) => {
    try {
      await Effect.runPromise(program);
      return "ok";
    } catch (error) {
      return vmWorkflowErrorCause(error)?._tag ?? String(error);
    }
  };
  expect(await outcome(createVm(caller).pipe(Effect.provide(layer)) as never)).toBe("VmMemoryPlanError");
  expect(creates).toBe(0);
  await outcome(createVm({ ...caller, entitlementOverride: DEAL }).pipe(Effect.provide(layer)) as never);
  expect(creates).toBe(1);
});
