import { describe, expect, test } from "bun:test";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import { VmDatabaseError, VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { deleteVmSnapshot, listVmSnapshots } from "../services/vms/workflows";

// `cmux vm snapshot ls <m>` / `cmux vm snapshot rm <m> <snapshot>`: the
// inventory and deletion of a machine's snapshots, scoped to a machine the
// caller owns. Fake repository and gateway layers pin the contract without a
// database or a provider (the pattern of vm-pause-resume-workflow.test.ts).

type Recorded = {
  listed: Array<[string, string]>;
  deleted: Array<[string, string, string]>;
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

const snapshots = [
  { id: "snap-old", createdAt: Date.parse("2026-09-01T00:00:00Z"), name: "before-upgrade" },
  { id: "snap-new", createdAt: Date.parse("2026-09-03T00:00:00Z") },
];

function fakes(options: {
  row: CloudVmRow;
  withList?: boolean;
  withDelete?: boolean;
  deleteFailure?: unknown;
  pending?: string[];
  finalWriteFailures?: number;
  intentWriteFails?: boolean;
}) {
  const recorded: Recorded = { listed: [], deleted: [], events: [] };
  let finalFailures = options.finalWriteFailures ?? 0;
  const pending = new Set(options.pending ?? []);
  const repo = {
    pendingSnapshotDeletions: () => Effect.sync(() => [...pending]),
    findUserVm: (input: { providerVmId: string }) =>
      Effect.succeed(input.providerVmId === options.row.providerVmId ? options.row : null),
    recordUsageEvent: (input: { eventType: string; metadata?: Record<string, unknown> }) => {
      return Effect.suspend(() => {
        if ((input.eventType === "vm.snapshot.deleted" && finalFailures-- > 0) ||
            (input.eventType === "vm.snapshot.delete_requested" && options.intentWriteFails)) {
          return Effect.fail(new VmDatabaseError({ operation: "recordUsageEvent", cause: new Error("database offline") }));
        }
        recorded.events.push({ eventType: input.eventType, metadata: input.metadata ?? {} });
        if (input.eventType === "vm.snapshot.delete_requested") pending.add(String(input.metadata?.snapshotId));
        if (input.eventType === "vm.snapshot.deleted") pending.delete(String(input.metadata?.snapshotId));
        return Effect.void;
      });
    },
  } as unknown as VmRepositoryShape;
  const provider = {
    ...(options.withList === false
      ? {}
      : {
        listSnapshots: (providerId: string, vmId: string) => {
          recorded.listed.push([providerId, vmId]);
          // Oldest first on purpose: the workflow orders newest first.
          return Effect.succeed(snapshots);
        },
      }),
    ...(options.withDelete === false
      ? {}
      : {
        deleteSnapshot: (providerId: string, vmId: string, snapshotId: string) => {
          recorded.deleted.push([providerId, vmId, snapshotId]);
          return options.deleteFailure === undefined
            ? Effect.void
            : Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "deleteSnapshot", cause: options.deleteFailure }));
        },
      }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider));
  return { recorded, layer };
}

const caller = { userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: "fs-1" };

async function failureTag(
  program: Effect.Effect<unknown, unknown, VmRepository | VmProviderGateway>,
  layer: Layer.Layer<VmRepository | VmProviderGateway>,
): Promise<string | null> {
  const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(layer)));
  if (Exit.isSuccess(exit)) return null;
  const failure = Cause.failureOption(exit.cause);
  return failure._tag === "Some" ? ((failure.value as { _tag?: string })._tag ?? "unknown") : "die";
}

describe("listVmSnapshots", () => {
  test("lists the provider's snapshots of the owned machine, newest first", async () => {
    const { recorded, layer } = fakes({ row: machineRow() });
    const result = await Effect.runPromise(listVmSnapshots(caller).pipe(Effect.provide(layer)));
    expect(result.map((snapshot) => snapshot.id)).toEqual(["snap-new", "snap-old"]);
    expect(result[1]).toEqual(snapshots[0]);
    expect(recorded.listed).toEqual([["freestyle", "fs-1"]]);
  });

  test("a machine the caller does not own is not found before the provider is asked", async () => {
    const { recorded, layer } = fakes({ row: machineRow() });
    expect(await failureTag(listVmSnapshots({ ...caller, providerVmId: "fs-other" }), layer)).toBe("VmNotFoundError");
    expect(recorded.listed).toEqual([]);
  });

  test("a provider that cannot enumerate snapshots fails with the unsupported error (the route's 501)", async () => {
    const { layer } = fakes({ row: machineRow(), withList: false });
    expect(await failureTag(listVmSnapshots(caller), layer)).toBe("VmOperationUnsupportedError");
  });
});

describe("deleteVmSnapshot", () => {
  test("deletes through the provider, scoped to the machine, and records the ledger row", async () => {
    const { recorded, layer } = fakes({ row: machineRow() });
    const result = await Effect.runPromise(deleteVmSnapshot({ ...caller, snapshotId: "snap-old" }).pipe(Effect.provide(layer)));
    expect(result).toEqual({ id: "snap-old", deleted: true });
    expect(recorded.deleted).toEqual([["freestyle", "fs-1", "snap-old"]]);
    expect(recorded.events).toEqual([
      { eventType: "vm.snapshot.delete_requested", metadata: { snapshotId: "snap-old" } },
      { eventType: "vm.snapshot.deleted", metadata: { snapshotId: "snap-old" } },
    ]);
  });

  test("a snapshot the provider does not know for this machine is snapshot-not-found, with no ledger row", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), deleteFailure: { status: 404, message: "snapshot not found" } });
    expect(await failureTag(deleteVmSnapshot({ ...caller, snapshotId: "snap-foreign" }), layer)).toBe("VmSnapshotNotFoundError");
    expect(recorded.events).toEqual([]);
  });

  test("any other provider failure stays a provider failure", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), deleteFailure: new Error("upstream 503") });
    expect(await failureTag(deleteVmSnapshot({ ...caller, snapshotId: "snap-old" }), layer)).toBe("VmProviderOperationError");
    expect(recorded.events).toEqual([{ eventType: "vm.snapshot.delete_requested", metadata: { snapshotId: "snap-old" } }]);
  });

  test("never deletes before its intent is durable", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), intentWriteFails: true });
    expect(await failureTag(deleteVmSnapshot({ ...caller, snapshotId: "snap-old" }), layer)).toBe("VmDatabaseError");
    expect(recorded.deleted).toEqual([]);
  });

  test("retries final ledger writes without repeating deletion", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), finalWriteFailures: 2 });
    expect(await failureTag(deleteVmSnapshot({ ...caller, snapshotId: "snap-old" }), layer)).toBeNull();
    expect(recorded.deleted).toHaveLength(1);
    expect(recorded.events.at(-1)?.eventType).toBe("vm.snapshot.deleted");
  });

  test("a pending delete reconciles provider 404 on retry", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pending: ["snap-gone"], deleteFailure: { status: 404 } });
    expect(await failureTag(deleteVmSnapshot({ ...caller, snapshotId: "snap-gone" }), layer)).toBeNull();
    expect(recorded.events).toEqual([{ eventType: "vm.snapshot.deleted", metadata: { snapshotId: "snap-gone" } }]);
  });

  test("inventory repairs a final ledger write left by an interrupted delete", async () => {
    const { recorded, layer } = fakes({ row: machineRow(), pending: ["snap-gone"] });
    await Effect.runPromise(listVmSnapshots(caller).pipe(Effect.provide(layer)));
    expect(recorded.events).toEqual([{ eventType: "vm.snapshot.deleted", metadata: { snapshotId: "snap-gone" } }]);
    expect(recorded.deleted).toEqual([]);
  });

  test("a machine the caller does not own is not found, and a provider without delete is unsupported", async () => {
    const owned = fakes({ row: machineRow() });
    expect(await failureTag(deleteVmSnapshot({ ...caller, providerVmId: "fs-other", snapshotId: "snap-old" }), owned.layer)).toBe("VmNotFoundError");
    expect(owned.recorded.deleted).toEqual([]);
    const without = fakes({ row: machineRow(), withDelete: false });
    expect(await failureTag(deleteVmSnapshot({ ...caller, snapshotId: "snap-old" }), without.layer)).toBe("VmOperationUnsupportedError");
  });
});
