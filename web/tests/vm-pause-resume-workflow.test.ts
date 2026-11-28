import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Cause from "effect/Cause";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as TestClock from "effect/TestClock";
import * as TestContext from "effect/TestContext";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { PAUSE_OPERATION_TIMEOUT_MS, PAUSE_STATE_PROBE_TIMEOUT_MS, pauseVm, resumeVm } from "../services/vms/workflows";
import { VmProviderOperationError } from "../services/vms/errors";
import { providerConflictKind } from "../services/vms/drivers/types";

// `cmux vm pause` / `cmux vm resume`: park a machine and wake it through the
// same suspended-resume path every open and exec uses. Fake repository and
// gateway layers, so the contract is pinned without a database or a provider.

type Recorded = {
  paused: string[];
  resumed: string[];
  statusProbes: string[];
  runtimeBudgets: Array<{ id: string; seconds: number | null }>;
  statuses: Array<{ id: string; status: string }>;
  reservations: string[];
  skipActiveLimits: boolean[];
  reservationWrites: Array<{ vcpus: number; memoryMb: number; diskMb: number }>;
  events: Array<{ eventType: string; metadata: Record<string, unknown> }>;
};

function machineRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "row-1",
    userId: "user-1",
    billingTeamId: "team-1",
    ownerTeamId: "team-1",
    coderouterPoolId: null,
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "fs-1",
    displayName: null,
    slug: "brave-otter",
    imageId: "sh-devbox",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: new Date("2026-09-01T00:00:00Z"),
    updatedAt: new Date("2026-09-01T00:00:00Z"),
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ...overrides,
  };
}

/** Build repository and provider layers that record pause/resume side effects. */
function fakes(options: {
  row: CloudVmRow;
  providerStatus?: "running" | "paused";
  /** Successive getStatus answers; the last one repeats. */
  providerStatuses?: Array<"creating" | "running" | "paused" | "probe_fails">;
  pauseState?: "paused" | "in_progress" | "not_paused" | "stopped" | "destroyed" | "probe_fails" | "probe_hangs";
  pauseHangs?: boolean;
  runtimeBudgetHangs?: boolean;
  withPause?: boolean;
  withResume?: boolean;
  stats?: { cpus: number; memoryTotalMb: number; diskTotalMb: number };
  onReservation?: (reservation: { vcpus: number; memoryMb: number; diskMb: number }) => void;
}) {
  const recorded: Recorded = { paused: [], resumed: [], statusProbes: [], runtimeBudgets: [], statuses: [], reservations: [], skipActiveLimits: [], reservationWrites: [], events: [] };
  const repo = {
    findUserVm: (input: { providerVmId: string }) =>
      Effect.succeed(input.providerVmId === options.row.providerVmId ? options.row : null),
    markProviderObservedStatus: (input: { id: string; status: string }) => {
      recorded.statuses.push({ id: input.id, status: input.status });
      return Effect.succeed(true);
    },
    recordUsageEvent: (input: { eventType: string; metadata?: Record<string, unknown> }) => {
      recorded.events.push({ eventType: input.eventType, metadata: input.metadata ?? {} });
      return Effect.void;
    },
    reservePausedResume: (input: { providerVmId: string; skipActiveLimit?: boolean }) => {
      recorded.reservations.push(input.providerVmId);
      recorded.skipActiveLimits.push(input.skipActiveLimit === true);
      return Effect.succeed({ ...options.row, status: "running" } as CloudVmRow);
    },
    ...(options.onReservation
      ? {
        setResourceReservation: (input: { reservation: { vcpus: number; memoryMb: number; diskMb: number } }) => Effect.sync(() => {
          recorded.reservationWrites.push(input.reservation);
          options.onReservation?.(input.reservation);
          return true;
        }),
      }
      : {}),
  } as unknown as VmRepositoryShape;
  const provider = {
    getStats: () => Effect.succeed({
      state: "awake" as const,
      sampledAt: Date.now(),
      cpus: options.stats?.cpus ?? 4,
      memoryTotalMb: options.stats?.memoryTotalMb ?? 8 * 1024,
      diskTotalMb: options.stats?.diskTotalMb ?? 32768,
    }),
    ...(options.pauseState
      ? {
        getPauseState: () => options.pauseState === "probe_fails"
          ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "getPauseState", cause: new Error("Status: 500") }))
          : options.pauseState === "probe_hangs" ? Effect.never : Effect.succeed(options.pauseState),
      }
      : {}),
    ...(options.withPause === false
      ? {}
      : {
        pause: (_provider: string, providerVmId: string) => {
          recorded.paused.push(providerVmId);
          return options.pauseHangs ? Effect.never : Effect.void;
        },
      }),
    setRuntimeBudget: (_provider: string, providerVmId: string, seconds: number | null) => {
      recorded.runtimeBudgets.push({ id: providerVmId, seconds });
      return options.runtimeBudgetHangs ? Effect.never : Effect.void;
    },
    ...(options.withResume === false
      ? {}
      : {
        resume: (_provider: string, providerVmId: string) => {
          recorded.resumed.push(providerVmId);
          return Effect.succeed({ provider: "freestyle", providerVmId, status: "running", image: "sh-devbox", createdAt: 0 });
        },
        getStatus: (_provider: string, providerVmId: string) => {
          recorded.statusProbes.push(providerVmId);
          const sequence = options.providerStatuses;
          if (sequence && sequence.length > 0) {
            const next = sequence[Math.min(recorded.statusProbes.length - 1, sequence.length - 1)];
            return next === "probe_fails"
              ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "getStatus", cause: new Error("Status: 500") }))
              : Effect.succeed(next);
          }
          return Effect.succeed(options.providerStatus ?? "running");
        },
      }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider));
  return { recorded, layer };
}

const caller = { userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: "fs-1" };
// Resume is an access verb: the caller's plan decides the free window, as the route passes it.
const resumeCaller = { ...caller, callerPlanId: "pro" };

async function failureTag(
  program: Effect.Effect<unknown, unknown, VmRepository | VmProviderGateway>,
  layer: Layer.Layer<VmRepository | VmProviderGateway>,
): Promise<string | null> {
  const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(layer)));
  if (Exit.isSuccess(exit)) return null;
  const failure = Cause.failureOption(exit.cause);
  return failure._tag === "Some" ? ((failure.value as { _tag?: string })._tag ?? "unknown") : "die";
}

describe("retries during an in-flight first call", () => {
  // A resume the route answered as in progress is still starting at the
  // provider. The retry waits for it instead of resuming twice.
  test("a resume retry while the first resume is starting waits for it", async () => {
    const { recorded, layer } = fakes({ row: machineRow({ status: "paused" }), providerStatuses: ["creating", "running"] });
    const result = await Effect.runPromise(resumeVm(resumeCaller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "running" });
    expect(recorded.resumed).toEqual([]);
  });
});

describe("a resume that never settles", () => {
  // Another caller's resume stays "creating". Only a status the provider
  // reported is a machine-state conflict; failed status reads stay the
  // provider's failure (an outage, not "the machine is busy").
  async function settleFailure(providerStatuses: Array<"creating" | "probe_fails">): Promise<unknown> {
    const { layer } = fakes({ row: machineRow({ status: "paused" }), providerStatuses });
    const exit = await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(resumeVm(resumeCaller).pipe(Effect.provide(layer)));
      yield* TestClock.adjust("2 minutes");
      return yield* Fiber.await(fiber);
    }).pipe(Effect.provide(TestContext.TestContext)));
    expect(Exit.isFailure(exit)).toBe(true);
    return Exit.isFailure(exit) ? Cause.squash(exit.cause) : null;
  }

  test("a machine that stays starting is a state conflict", async () => {
    expect(providerConflictKind(await settleFailure(["creating"]))).toBe("state");
  });

  test("status reads that all fail are not a state conflict", async () => {
    expect(providerConflictKind(await settleFailure(["creating", "probe_fails"]))).toBeNull();
  });
});

describe("pauseVm", () => {
  test("parks a running machine: provider pause, row paused, usage event", async () => {
    const { recorded, layer } = fakes({ row: machineRow() });
    const result = await Effect.runPromise(pauseVm(caller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "paused" });
    expect(recorded.paused).toEqual(["fs-1"]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused" }]);
    expect(recorded.events).toEqual([{ eventType: "vm.paused", metadata: { source: "user" } }]);
  });

  test("is idempotent: a paused machine answers paused without touching the provider", async () => {
    const { recorded, layer } = fakes({ row: machineRow({ status: "paused" }) });
    const result = await Effect.runPromise(pauseVm(caller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "paused" });
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([]);
    expect(recorded.events).toEqual([]);
  });

  // A pause whose route answered "in progress" (routeDeadline.ts) may finish
  // at the provider after the response. The retry must not pause twice: it
  // reconciles the row with the provider's observed status.
  test("a retry after a pause that finished in the background records it without pausing again", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "paused" });
    const result = await Effect.runPromise(pauseVm(caller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "paused" });
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused" }]);
    expect(recorded.events).toEqual([{ eventType: "vm.paused", metadata: { source: "user" } }]);
  });

  test("a retry while the first pause is still pausing answers in progress without pausing again", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "in_progress" });
    expect(await failureTag(pauseVm(caller), layer)).toBe("VmOperationDeadlineError");
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([]);
  });

  test("a machine gone at the provider answers not found without a pause call", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "destroyed" });
    expect(await failureTag(pauseVm(caller), layer)).toBe("VmNotFoundError");
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([]);
  });

  // Freestyle refuses to pause a stopped machine: it is recorded as parked
  // (its compute is already off) without a pause call.
  test("a powered-off machine is recorded as parked without a pause the provider would refuse", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "stopped" });
    const result = await Effect.runPromise(pauseVm(caller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "paused" });
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused" }]);
    expect(recorded.events).toEqual([{ eventType: "vm.paused", metadata: { source: "provider_stopped" } }]);
  });

  test("a running machine is paused", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "not_paused" });
    const result = await Effect.runPromise(pauseVm(caller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "paused" });
    expect(recorded.paused).toEqual(["fs-1"]);
  });

  test("a state probe that cannot tell answers in progress and never pauses a second time", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "probe_fails" });
    expect(await failureTag(pauseVm(caller), layer)).toBe("VmOperationDeadlineError");
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([]);
  });

  test("a hanging state probe fails within its bound and does not leave pause running", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "probe_hangs" });
    const exit = await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(pauseVm(caller).pipe(Effect.provide(layer), Effect.either));
      yield* TestClock.adjust(PAUSE_STATE_PROBE_TIMEOUT_MS);
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(TestContext.TestContext)));
    expect(exit._tag).toBe("Left");
    expect(exit._tag === "Left" ? exit.left._tag : null).toBe("VmOperationDeadlineError");
    expect(exit._tag === "Left" && exit.left._tag === "VmOperationDeadlineError" ? exit.left.waitedMs : null)
      .toBe(PAUSE_STATE_PROBE_TIMEOUT_MS);
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([]);
  });

  test("a provider pause that never answers fails within its bound and leaves the row running", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pauseState: "not_paused", pauseHangs: true });
    const exit = await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(pauseVm(caller).pipe(Effect.provide(layer), Effect.either));
      yield* TestClock.adjust(PAUSE_OPERATION_TIMEOUT_MS);
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(TestContext.TestContext)));
    expect(exit._tag).toBe("Left");
    expect(exit._tag === "Left" ? exit.left._tag : null).toBe("VmOperationDeadlineError");
    expect(recorded.paused).toEqual(["fs-1"]);
    expect(recorded.statuses).toEqual([]);
  });

  test("a Go runtime-budget update that never answers fails within the pause bound", async () => {
    const { recorded, layer } = fakes({
      row: machineRow({ billingPlanId: "go" }), pauseState: "not_paused", runtimeBudgetHangs: true,
    });
    const exit = await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(pauseVm(caller).pipe(Effect.provide(layer), Effect.either));
      yield* TestClock.adjust(PAUSE_OPERATION_TIMEOUT_MS);
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(TestContext.TestContext)));
    expect(exit._tag).toBe("Left");
    expect(exit._tag === "Left" ? exit.left._tag : null).toBe("VmOperationDeadlineError");
    expect(recorded.runtimeBudgets).toEqual([{ id: "fs-1", seconds: 0 }]);
    expect(recorded.paused).toEqual([]);
    expect(recorded.statuses).toEqual([]);
  });

  test("a provider without pause fails with the unsupported error (the route's 501)", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), withPause: false });
    expect(await failureTag(pauseVm(caller), layer)).toBe("VmOperationUnsupportedError");
    expect(recorded.statuses).toEqual([]);
  });

  test("a machine the caller does not own is not found", async () => {
    const { layer } = fakes({ row: machineRow() });
    expect(await failureTag(pauseVm({ ...caller, providerVmId: "fs-other" }), layer)).toBe("VmNotFoundError");
  });
});

describe("resumeVm", () => {
  test("wakes a paused team machine through the reservation, records running, and bills the resume", async () => {
    const { recorded, layer } = fakes({ row: machineRow({ status: "paused" }), providerStatus: "paused" });
    const result = await Effect.runPromise(resumeVm({ ...resumeCaller, maxActiveVms: 3 }).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "running" });
    expect(recorded.statusProbes).toEqual(["fs-1"]);
    expect(recorded.reservations).toEqual(["fs-1"]);
    // Markerless legacy rows are grandfathered until reconciliation measures
    // them; their conservative pool claim still blocks new allocation.
    expect(recorded.skipActiveLimits).toEqual([true]);
    expect(recorded.resumed).toEqual(["fs-1"]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "running" }]);
    expect(recorded.events).toEqual([{ eventType: "vm.resumed", metadata: { source: "user" } }]);
  });

  test("grandfathered oversized paused machines can resume above the current count", async () => {
    const { recorded, layer } = fakes({
      row: machineRow({
        status: "paused",
        providerMetadata: { cmuxResourceReservation: { vcpus: 12, memoryMb: 24 * 1024, diskMb: 65536 } },
      }),
      providerStatus: "paused",
    });
    const result = await Effect.runPromise(resumeVm({ ...resumeCaller, maxActiveVms: 1 }).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "running" });
    expect(recorded.skipActiveLimits).toEqual([true]);
  });

  test("is idempotent: a machine the provider reports running answers running without a resume", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), providerStatus: "running" });
    const result = await Effect.runPromise(resumeVm(resumeCaller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "running" });
    expect(recorded.resumed).toEqual([]);
    expect(recorded.reservations).toEqual([]);
  });

  test("repairs a row that says paused when the provider already runs it", async () => {
    const { recorded, layer } = fakes({ row: machineRow({ status: "paused" }), providerStatus: "running" });
    const result = await Effect.runPromise(resumeVm(resumeCaller).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "running" });
    expect(recorded.resumed).toEqual([]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "running" }]);
  });

  test("persists a measured legacy shape before reserving a resume", async () => {
    const { recorded, layer } = fakes({
      row: machineRow({ status: "paused" }),
      providerStatus: "paused",
      // A legacy Max-sized machine has no cmuxResourceReservation marker.
      stats: { cpus: 12, memoryTotalMb: 24 * 1024, diskTotalMb: 65536 },
      onReservation: () => undefined,
    });
    const result = await Effect.runPromise(resumeVm({ ...resumeCaller, callerPlanId: "max" }).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "fs-1", status: "running" });
    expect(recorded.reservationWrites).toEqual([{ vcpus: 12, memoryMb: 24 * 1024, diskMb: 65536 }]);
    expect(recorded.reservations).toEqual(["fs-1"]);
  });

  test("a provider without resume: running rows answer running, paused rows fail as unsupported", async () => {
    const running = fakes({ row: machineRow(), withResume: false });
    expect(await Effect.runPromise(resumeVm(resumeCaller).pipe(Effect.provide(running.layer)))).toEqual({ id: "fs-1", status: "running" });
    const paused = fakes({ row: machineRow({ status: "paused" }), withResume: false });
    expect(await failureTag(resumeVm(resumeCaller), paused.layer)).toBe("VmOperationUnsupportedError");
  });
});
