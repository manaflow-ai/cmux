import { beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";

import { providerConflictKind } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  FLEET_CAPACITY_COOLDOWN_MS,
  admitFleetCapacity,
  alertTeamQuotaUsage,
  fleetMaxActiveVms,
  noteProviderStartRefusal,
  providerCapacityCooldownMs,
  quotaAlertThreshold,
  resetFleetAdmissionForTest,
} from "../services/vms/fleetAdmission";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

const PROVIDER = "freestyle" as const;
const CAPACITY_REFUSAL = { status: 409, code: "CONFLICT", message: "no manager has enough capacity for vm" };

function repoLive(count: number | "error") {
  let reads = 0;
  return {
    reads: () => reads,
    repo: {
      countLiveProviderVms: () => {
        reads += 1;
        return count === "error" ? Effect.fail(new Error("db down") as never) : Effect.succeed(count);
      },
    },
  };
}

function failure(exit: Exit.Exit<unknown, VmProviderOperationError>): VmProviderOperationError {
  if (!Exit.isFailure(exit) || exit.cause._tag !== "Fail") throw new Error("expected a failure");
  return exit.cause.error;
}

beforeEach(() => resetFleetAdmissionForTest());

describe("provider start capacity", () => {
  test("a placement refusal starts a cooldown that refuses creates before the provider start", async () => {
    const now = 1_000_000;
    expect(noteProviderStartRefusal(PROVIDER, CAPACITY_REFUSAL, now)).toBe(true);
    const { repo, reads } = repoLive(0);
    const exit = await Effect.runPromiseExit(admitFleetCapacity(repo, { provider: PROVIDER, now: now + 5_000, env: {} }));
    const error = failure(exit);
    expect(providerConflictKind(error.cause)).toBe("capacity");
    expect(reads()).toBe(0);
    const response = await vmWorkflowErrorResponse(error);
    expect(response).not.toBeNull();
    expect(response!.status).toBe(503);
    expect(await response!.json()).toMatchObject({ error: "vm_provider_capacity" });
  });

  test("the cooldown ends, and other refusals never start one", async () => {
    const now = 2_000_000;
    noteProviderStartRefusal(PROVIDER, CAPACITY_REFUSAL, now);
    expect(providerCapacityCooldownMs(PROVIDER, now + FLEET_CAPACITY_COOLDOWN_MS)).toBe(0);
    expect(noteProviderStartRefusal(PROVIDER, { status: 409, code: "CONFLICT", message: "slug taken" }, now)).toBe(false);
    expect(noteProviderStartRefusal(PROVIDER, new Error("socket hang up"), now)).toBe(false);
    expect(noteProviderStartRefusal(PROVIDER, { status: 429, message: "rate limited" }, now)).toBe(false);
    const exit = await Effect.runPromiseExit(admitFleetCapacity(repoLive(0).repo, { provider: PROVIDER, now: now + FLEET_CAPACITY_COOLDOWN_MS, env: {} }));
    expect(Exit.isSuccess(exit)).toBe(true);
  });
});

test("the 429 start-capacity throttle, wrapped in the create error, starts the cooldown too", () => {
  const now = 3_000_000;
  const wrapped = new VmProviderOperationError({
    provider: PROVIDER,
    operation: "create",
    cause: { status: 429, message: "infrastructure overloaded: VM start capacity reached, retry later" },
  });
  expect(noteProviderStartRefusal(PROVIDER, wrapped, now)).toBe(true);
  expect(providerCapacityCooldownMs(PROVIDER, now + 1_000)).toBe(FLEET_CAPACITY_COOLDOWN_MS - 1_000);
});

describe("fleet machine cap", () => {
  test("unset reads nothing and admits", async () => {
    const { repo, reads } = repoLive(10_000);
    const exit = await Effect.runPromiseExit(admitFleetCapacity(repo, { provider: PROVIDER, env: {} }));
    expect(Exit.isSuccess(exit)).toBe(true);
    expect(reads()).toBe(0);
    expect(fleetMaxActiveVms({ CMUX_VM_FLEET_MAX_ACTIVE_VMS: "nope" })).toBeNull();
    expect(fleetMaxActiveVms({ CMUX_VM_FLEET_MAX_ACTIVE_VMS: "0" })).toBeNull();
    expect(fleetMaxActiveVms({ CMUX_VM_FLEET_MAX_ACTIVE_VMS: " 300 " })).toBe(300);
  });

  test("the count includes the new row: at the cap admits, past it refuses with the capacity answer", async () => {
    const env = { CMUX_VM_FLEET_MAX_ACTIVE_VMS: "100" };
    expect(Exit.isSuccess(await Effect.runPromiseExit(admitFleetCapacity(repoLive(100).repo, { provider: PROVIDER, env })))).toBe(true);
    const error = failure(await Effect.runPromiseExit(admitFleetCapacity(repoLive(101).repo, { provider: PROVIDER, env })));
    expect(providerConflictKind(error.cause)).toBe("capacity");
    expect(String((error.cause as Error).message)).toContain("fleet holds 100 of 100 machines");
  });

  test("the fleet cap waits as its own state, waiting_for_fleet, not as provider capacity", async () => {
    const { createWaitStateForCause } = await import("../services/vms/createWait");
    const env = { CMUX_VM_FLEET_MAX_ACTIVE_VMS: "100" };
    const error = failure(await Effect.runPromiseExit(admitFleetCapacity(repoLive(101).repo, { provider: PROVIDER, env })));
    expect(createWaitStateForCause(error)).toBe("waiting_for_fleet");
  });

  test("an unreadable count admits: admission is never the outage", async () => {
    const exit = await Effect.runPromiseExit(admitFleetCapacity(repoLive("error").repo, { provider: PROVIDER, env: { CMUX_VM_FLEET_MAX_ACTIVE_VMS: "1" } }));
    expect(Exit.isSuccess(exit)).toBe(true);
  });
});

describe("team quota alert", () => {
  test("fires once at 80% of the plan limit, not below, not without a limit", () => {
    expect(quotaAlertThreshold(10)).toBe(8);
    expect(alertTeamQuotaUsage({ provider: PROVIDER, billingTeamId: "team-1", activeAfter: 7, limit: 10, now: 1 })).toBe(false);
    expect(alertTeamQuotaUsage({ provider: PROVIDER, billingTeamId: "team-1", activeAfter: 8, limit: 10, now: 1 })).toBe(true);
    expect(alertTeamQuotaUsage({ provider: PROVIDER, billingTeamId: "team-1", activeAfter: 9, limit: 10, now: 2 })).toBe(false);
    expect(alertTeamQuotaUsage({ provider: PROVIDER, billingTeamId: "team-2", activeAfter: 50, limit: null, now: 1 })).toBe(false);
  });
});

test("fleet refusals and the 429 throttle wait for capacity, other errors do not", async () => {
  const { createWaitStateForCause } = await import("../services/vms/createWait");
  noteProviderStartRefusal(PROVIDER, CAPACITY_REFUSAL, 5_000_000);
  const refused = failure(await Effect.runPromiseExit(admitFleetCapacity(repoLive(0).repo, { provider: PROVIDER, now: 5_001_000, env: {} })));
  expect(createWaitStateForCause(refused)).toBe("waiting_for_capacity");
  expect(createWaitStateForCause({ status: 429, message: "infrastructure overloaded: VM start capacity reached" })).toBe("waiting_for_capacity");
  expect(createWaitStateForCause({ status: 429, message: "rate limited" })).toBeNull();
  expect(createWaitStateForCause(new Error("socket hang up"))).toBeNull();
});
