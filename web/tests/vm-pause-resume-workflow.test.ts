import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Cause from "effect/Cause";
import * as Layer from "effect/Layer";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { pauseVm, resumeVm } from "../services/vms/workflows";

// `cmux vm pause` / `cmux vm resume`: park a machine and wake it through the
// same suspended-resume path every open and exec uses. Fake repository and
// gateway layers, so the contract is pinned without a database or a provider.

type Recorded = {
  paused: string[];
  resumed: string[];
  statusProbes: string[];
  statuses: Array<{ id: string; status: string }>;
  reservations: string[];
  events: Array<{ eventType: string; metadata: Record<string, unknown> }>;
};

function machineRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "row-1",
    userId: "user-1",
    billingTeamId: "team-1",
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
    ...overrides,
  } as unknown as CloudVmRow;
}

function fakes(options: {
  row: CloudVmRow;
  providerStatus?: "running" | "paused";
  withPause?: boolean;
  withResume?: boolean;
}) {
  const recorded: Recorded = { paused: [], resumed: [], statusProbes: [], statuses: [], reservations: [], events: [] };
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
    reservePausedResume: (input: { providerVmId: string }) => {
      recorded.reservations.push(input.providerVmId);
      return Effect.succeed({ ...options.row, status: "running" } as CloudVmRow);
    },
  } as unknown as VmRepositoryShape;
  const provider = {
    ...(options.withPause === false
      ? {}
      : {
        pause: (_provider: string, providerVmId: string) => {
          recorded.paused.push(providerVmId);
          return Effect.void;
        },
      }),
    ...(options.withResume === false
      ? {}
      : {
        resume: (_provider: string, providerVmId: string) => {
          recorded.resumed.push(providerVmId);
          return Effect.succeed({ provider: "freestyle", providerVmId, status: "running", image: "sh-devbox", createdAt: 0 });
        },
        getStatus: (_provider: string, providerVmId: string) => {
          recorded.statusProbes.push(providerVmId);
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
    expect(recorded.resumed).toEqual(["fs-1"]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "running" }]);
    expect(recorded.events).toEqual([{ eventType: "vm.resumed", metadata: { source: "user" } }]);
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

  test("a provider without resume: running rows answer running, paused rows fail as unsupported", async () => {
    const running = fakes({ row: machineRow(), withResume: false });
    expect(await Effect.runPromise(resumeVm(resumeCaller).pipe(Effect.provide(running.layer)))).toEqual({ id: "fs-1", status: "running" });
    const paused = fakes({ row: machineRow({ status: "paused" }), withResume: false });
    expect(await failureTag(resumeVm(resumeCaller), paused.layer)).toBe("VmOperationUnsupportedError");
  });
});
