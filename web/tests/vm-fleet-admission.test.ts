import { beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Either from "effect/Either";

import { ProviderStartCapacityError, isProviderStartCapacityRefusal } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  admitFleetCapacity,
  alertTeamMachineQuota,
  fleetBoundVerdict,
  fleetQuotaFromEnv,
  noteProviderStartOutcome,
  providerStartWindowMs,
  resetFleetAdmissionForTest,
} from "../services/vms/fleetAdmission";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

// Leo, 2026-11-28: "Add admission checks before starting a run: per-team
// machine cap, free addresses, and fleet capacity." and "Alert at roughly 80%
// of team and fleet address/quota usage."

const overloaded = () => new VmProviderOperationError({
  provider: "freestyle",
  operation: "create",
  cause: Object.assign(new Error("infrastructure overloaded: VM start capacity queue wait expired"), { status: 429, code: "INFRASTRUCTURE_OVERLOADED" }),
});

function repoWith(usage: { liveMachines: number; starting: number } | "error") {
  let reads = 0;
  return {
    get reads() { return reads; },
    repo: {
      fleetCapacityUsage: () => {
        reads += 1;
        return usage === "error"
          ? Effect.fail({ _tag: "VmDatabaseError" } as never)
          : Effect.succeed(usage);
      },
    },
  };
}

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(Effect.either(effect));

beforeEach(() => resetFleetAdmissionForTest());

describe("provider start-capacity refusals", () => {
  test("the provider's 429 overload and 409 placement refusal are start-capacity refusals; other answers are not", () => {
    expect(isProviderStartCapacityRefusal(overloaded().cause)).toBe(true);
    expect(isProviderStartCapacityRefusal(Object.assign(new Error("no manager has enough capacity for vm"), { status: 409, code: "CONFLICT" }))).toBe(true);
    expect(isProviderStartCapacityRefusal(Object.assign(new Error("rate limited"), { status: 429, code: "RATE_LIMITED" }))).toBe(false);
    expect(isProviderStartCapacityRefusal(Object.assign(new Error("slug taken"), { status: 409, code: "CONFLICT" }))).toBe(false);
    expect(isProviderStartCapacityRefusal(Object.assign(new Error("boom"), { status: 500 }))).toBe(false);
    expect(isProviderStartCapacityRefusal(new Error("socket hang up"))).toBe(false);
  });

  test("a refusal opens a window that refuses the next start before the provider call, then grows and closes on success", async () => {
    const now = 1_000_000;
    noteProviderStartOutcome("freestyle", overloaded(), now);
    expect(providerStartWindowMs("freestyle", now)).toBe(15_000);

    const refused = await run(admitFleetCapacity({}, { provider: "freestyle", operation: "create", now: now + 1_000, quota: { maxLiveMachines: null, maxStarting: null } }));
    expect(Either.isLeft(refused)).toBe(true);
    const err = Either.isLeft(refused) ? refused.left : null;
    expect(err?.cause).toBeInstanceOf(ProviderStartCapacityError);
    expect((err?.cause as ProviderStartCapacityError).atAdmission).toBe(true);

    // An admission refusal fed back is not news from the provider: the window does not grow.
    noteProviderStartOutcome("freestyle", err, now + 1_000);
    expect(providerStartWindowMs("freestyle", now + 1_000)).toBe(14_000);

    // A second provider refusal doubles it.
    noteProviderStartOutcome("freestyle", overloaded(), now + 20_000);
    expect(providerStartWindowMs("freestyle", now + 20_000)).toBe(30_000);
    // Past the window starts are admitted again.
    const after = await run(admitFleetCapacity({}, { provider: "freestyle", operation: "create", now: now + 60_000, quota: { maxLiveMachines: null, maxStarting: null } }));
    expect(Either.isRight(after)).toBe(true);
    // A success closes it outright.
    noteProviderStartOutcome("freestyle", overloaded(), now + 70_000);
    noteProviderStartOutcome("freestyle", null, now + 71_000);
    expect(providerStartWindowMs("freestyle", now + 71_000)).toBe(0);
  });

  test("the window is capped at two minutes", () => {
    for (let i = 0; i < 10; i += 1) noteProviderStartOutcome("freestyle", overloaded(), 0);
    expect(providerStartWindowMs("freestyle", 0)).toBe(120_000);
  });

  test("other failures leave the window closed", () => {
    noteProviderStartOutcome("freestyle", new VmProviderOperationError({ provider: "freestyle", operation: "create", cause: Object.assign(new Error("boom"), { status: 500 }) }), 0);
    expect(providerStartWindowMs("freestyle", 0)).toBe(0);
  });

  test("the route answers an admission refusal as retryable vm_provider_capacity with the window as Retry-After", async () => {
    noteProviderStartOutcome("freestyle", overloaded(), Date.now());
    const refused = await run(admitFleetCapacity({}, { provider: "freestyle", operation: "create", quota: { maxLiveMachines: null, maxStarting: null } }));
    if (!Either.isLeft(refused)) throw new Error("expected a refusal");
    const response = await vmWorkflowErrorResponse(refused.left);
    expect(response.status).toBe(503);
    const body = await response.json() as { error: string; retryable: boolean };
    expect(body.error).toBe("vm_provider_capacity");
    expect(body.retryable).toBe(true);
    const retryAfter = Number(response.headers.get("retry-after"));
    expect(retryAfter).toBeGreaterThanOrEqual(14);
    expect(retryAfter).toBeLessThanOrEqual(15);
  });

  test("the provider's own 429 overload reaches the route as vm_provider_capacity, not a generic provider error", async () => {
    const response = await vmWorkflowErrorResponse(overloaded());
    expect(response.status).toBe(503);
    expect((await response.json() as { error: string }).error).toBe("vm_provider_capacity");
  });
});

describe("fleet quota admission", () => {
  test("verdicts: admit below 80%, alert from 80%, full past the quota, nothing without a quota", () => {
    expect(fleetBoundVerdict(79, 100)).toBe("admit");
    expect(fleetBoundVerdict(80, 100)).toBe("alert");
    expect(fleetBoundVerdict(100, 100)).toBe("alert");
    expect(fleetBoundVerdict(101, 100)).toBe("full");
    expect(fleetBoundVerdict(10_000, null)).toBe("admit");
  });

  test("quota comes from the deployment's env; junk reads as unset", () => {
    expect(fleetQuotaFromEnv({ CMUX_VM_FLEET_MAX_LIVE_MACHINES: "500", CMUX_VM_FLEET_MAX_STARTING: "x" })).toEqual({ maxLiveMachines: 500, maxStarting: null });
    expect(fleetQuotaFromEnv({})).toEqual({ maxLiveMachines: null, maxStarting: null });
  });

  test("no quota reads nothing", async () => {
    const fake = repoWith({ liveMachines: 1, starting: 0 });
    await run(admitFleetCapacity(fake.repo, { provider: "freestyle", operation: "create", quota: { maxLiveMachines: null, maxStarting: null } }));
    expect(fake.reads).toBe(0);
  });

  test("the last machine under the quota is admitted and the one past it is refused", async () => {
    const quota = { maxLiveMachines: 10, maxStarting: null };
    const atNine = await run(admitFleetCapacity(repoWith({ liveMachines: 9, starting: 0 }).repo, { provider: "freestyle", operation: "create", quota, now: 1 }));
    expect(Either.isRight(atNine)).toBe(true);
    resetFleetAdmissionForTest();
    const atTen = await run(admitFleetCapacity(repoWith({ liveMachines: 10, starting: 0 }).repo, { provider: "freestyle", operation: "create", quota, now: 1 }));
    expect(Either.isLeft(atTen) && atTen.left.cause instanceof ProviderStartCapacityError).toBe(true);
    // A resume brings back a machine already counted, so it fits at ten.
    const resume = await run(admitFleetCapacity(repoWith({ liveMachines: 10, starting: 0 }).repo, { provider: "freestyle", operation: "resume", quota, now: 1 }));
    expect(Either.isRight(resume)).toBe(true);
  });

  test("in-flight starts past the start quota are refused", async () => {
    const result = await run(admitFleetCapacity(repoWith({ liveMachines: 3, starting: 4 }).repo, { provider: "freestyle", operation: "create", quota: { maxLiveMachines: null, maxStarting: 4 }, now: 1 }));
    expect(Either.isLeft(result)).toBe(true);
  });

  test("an unreadable count admits", async () => {
    const result = await run(admitFleetCapacity(repoWith("error").repo, { provider: "freestyle", operation: "create", quota: { maxLiveMachines: 1, maxStarting: 1 }, now: 1 }));
    expect(Either.isRight(result)).toBe(true);
  });

  test("the count is cached for 30 s per instance", async () => {
    const fake = repoWith({ liveMachines: 1, starting: 0 });
    const quota = { maxLiveMachines: 100, maxStarting: null };
    await run(admitFleetCapacity(fake.repo, { provider: "freestyle", operation: "create", quota, now: 1_000 }));
    await run(admitFleetCapacity(fake.repo, { provider: "freestyle", operation: "create", quota, now: 20_000 }));
    expect(fake.reads).toBe(1);
    await run(admitFleetCapacity(fake.repo, { provider: "freestyle", operation: "create", quota, now: 40_000 }));
    expect(fake.reads).toBe(2);
  });
});

describe("team machine quota alert", () => {
  test("alerts from 80% of a cap of ten or more; small caps never alert", () => {
    expect(alertTeamMachineQuota({ provider: "freestyle", billingTeamId: "t", active: 7, limit: 10, now: 0 })).toBe("admit");
    expect(alertTeamMachineQuota({ provider: "freestyle", billingTeamId: "t", active: 8, limit: 10, now: 0 })).toBe("alert");
    expect(alertTeamMachineQuota({ provider: "freestyle", billingTeamId: "t", active: 10, limit: 10, now: 0 })).toBe("full");
    expect(alertTeamMachineQuota({ provider: "freestyle", billingTeamId: "t", active: 2, limit: 2, now: 0 })).toBe("admit");
    expect(alertTeamMachineQuota({ provider: "freestyle", billingTeamId: "t", active: 500, limit: null, now: 0 })).toBe("admit");
  });
});
