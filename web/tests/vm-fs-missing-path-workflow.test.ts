import { describe, expect, test } from "bun:test";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import { VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { listVmFiles, readVmFile, statVmFile } from "../services/vms/workflows";

// GET /api/vm/[id]/fs/{stat,read,dir} of a missing path answers 404 vm_file_not_found.
// Staging rehearsal 2026-10-04: stat of a removed file answered 502 vm_cloud_service_unavailable
// ("VM not found"), a retryable outage for an ordinary missing path.

const row = (): CloudVmRow => ({
  id: "row-1", userId: "user-1", billingTeamId: "team-1", ownerTeamId: "team-1", coderouterPoolId: null, billingPlanId: "pro",
  provider: "freestyle", providerVmId: "fs-1", displayName: null, slug: "brave-otter", imageId: "sh-devbox", imageVersion: null,
  status: "running", idempotencyKey: null, createdAt: new Date(0), updatedAt: new Date(0), destroyedAt: null, failureCode: null,
  failureMessage: null, providerMetadata: {},
}) as CloudVmRow;

const missingPath = (path: string) => Object.assign(new Error(`not found: ${path}: No such file or directory (os error 2)`), { name: "FreestyleApiError", status: 404, code: "NOT_FOUND" });
const missingVm = () => Object.assign(new Error("vm not found"), { status: 404, code: "VM_NOT_FOUND" });

function layerFailing(cause: unknown) {
  const fail = (operation: string) => () => Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation, cause }));
  const repo = { findUserVm: () => Effect.succeed(row()) } as unknown as VmRepositoryShape;
  const provider = {
    getStats: () => Effect.succeed({ cpus: 4, memoryTotalMb: 8192, diskTotalMb: 32768 }),
    statFile: fail("statFile"),
    readFile: fail("readFile"),
    listFiles: fail("listFiles"),
  } as unknown as VmProviderGatewayShape;
  return Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider));
}

const caller = { userId: "user-1", billingTeamId: "team-1", callerPlanId: "pro", teamIds: ["team-1"], providerVmId: "fs-1" };
const ops = { stat: statVmFile, read: readVmFile, dir: listVmFiles } as const;

async function failureTag(op: keyof typeof ops, cause: unknown, path: string): Promise<string | null> {
  const program = (ops[op] as (input: typeof caller, path: string) => Effect.Effect<unknown, unknown, VmRepository | VmProviderGateway>)(caller, path);
  const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(layerFailing(cause))) as Effect.Effect<unknown, unknown>);
  if (Exit.isSuccess(exit)) return null;
  const failure = Cause.failureOption(exit.cause);
  return failure._tag === "Some" ? ((failure.value as { _tag?: string })._tag ?? "unknown") : "die";
}

describe("file reads of a missing path", () => {
  for (const op of ["stat", "read", "dir"] as const) {
    test(`${op}: a missing path is VmFileNotFoundError (404 vm_file_not_found)`, async () => {
      expect(await failureTag(op, missingPath("/tmp/gone"), "/tmp/gone")).toBe("VmFileNotFoundError");
    });
    test(`${op}: a missing VM stays a provider failure`, async () => {
      expect(await failureTag(op, missingVm(), "/tmp/a")).toBe("VmProviderOperationError");
    });
  }
});

// A file op on a paused machine wakes it through the shared resume preflight.
// That preflight must judge the machine against the caller's current plan, not
// the plan the row was created on: a legacy machine made on Free (no capacity
// marker) on a team that is now on Team resumes as grandfathered, with no
// active-limit re-gate, exactly as open and exec resume it. Judged as Free it
// would be re-gated against the Free limits instead.
describe("file op resume of a paused machine", () => {
  test("uses the caller's current plan, not the row's create-time plan", async () => {
    const skipActiveLimits: boolean[] = [];
    let statusProbes = 0;
    const paused = { ...row(), status: "paused", billingPlanId: "free" } as CloudVmRow;
    const repo = {
      findUserVm: () => Effect.succeed(paused),
      markProviderObservedStatus: () => Effect.succeed(true),
      recordUsageEvent: () => Effect.void,
      reservePausedResume: (input: { skipActiveLimit?: boolean }) => {
        skipActiveLimits.push(input.skipActiveLimit === true);
        return Effect.succeed({ ...paused, status: "running" } as CloudVmRow);
      },
    } as unknown as VmRepositoryShape;
    const provider = {
      getStats: () => Effect.succeed({ state: "awake", sampledAt: 0, cpus: 4, memoryTotalMb: 8192, diskTotalMb: 32768 }),
      getStatus: () => {
        statusProbes += 1;
        return Effect.succeed(statusProbes === 1 ? "paused" : "running");
      },
      resume: (_provider: string, providerVmId: string) =>
        Effect.succeed({ provider: "freestyle", providerVmId, status: "running", image: "sh-devbox", createdAt: 0 }),
      statFile: () => Effect.succeed({ path: "/tmp/a", kind: "file", size: 0, mode: 0o644, modifiedAt: 0 }),
    } as unknown as VmProviderGatewayShape;
    const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider));
    const exit = await Effect.runPromiseExit(
      statVmFile({ ...caller, callerPlanId: "team", maxActiveVms: 40 }, "/tmp/a").pipe(Effect.provide(layer)) as Effect.Effect<unknown, unknown>,
    );
    expect(Exit.isSuccess(exit) ? "ok" : Cause.pretty(exit.cause)).toBe("ok");
    expect(skipActiveLimits).toEqual([true]);
  });

  // When the stored size can be measured and repaired, the resume judges the
  // machine on those dimensions against the caller's plan and the team's deal:
  // a 32 GB machine is above the Team ceiling (grandfathered, no pool gate),
  // but within a deal that allows 64 GB machines (gated on the deal's pool).
  for (const [label, entitlementOverride, grandfathered] of [
    ["above the Team ceiling without a deal", null, true],
    ["within a 64 GB deal", { maxActiveVms: 40, poolVcpus: 320, poolMemoryMb: 655_360, maxMemoryMb: 65_536, planLabel: null, monthlyPriceCents: null }, false],
  ] as const) {
    test(`a measured 32 GB machine resumes on the caller's plan and deal: ${label}`, async () => {
      const reservations: Array<{ skipActiveLimit: boolean; poolVcpus: number | null; poolMemoryMb: number | null }> = [];
      const repaired: Array<{ vcpus: number; memoryMb: number }> = [];
      let statusProbes = 0;
      const paused = { ...row(), status: "paused", billingPlanId: "free" } as CloudVmRow;
      const repo = {
        findUserVm: () => Effect.succeed(paused),
        markProviderObservedStatus: () => Effect.succeed(true),
        recordUsageEvent: () => Effect.void,
        setResourceReservation: (input: { reservation: { vcpus: number; memoryMb: number } }) => Effect.sync(() => {
          repaired.push({ vcpus: input.reservation.vcpus, memoryMb: input.reservation.memoryMb });
          return true;
        }),
        reservePausedResume: (input: { skipActiveLimit?: boolean; resourcePool?: { capacity: { vcpus: number; memoryMb: number } } | null }) => {
          reservations.push({
            skipActiveLimit: input.skipActiveLimit === true,
            poolVcpus: input.resourcePool?.capacity.vcpus ?? null,
            poolMemoryMb: input.resourcePool?.capacity.memoryMb ?? null,
          });
          return Effect.succeed({ ...paused, status: "running" } as CloudVmRow);
        },
      } as unknown as VmRepositoryShape;
      const provider = {
        getStats: () => Effect.succeed({ state: "awake", sampledAt: 0, cpus: 8, memoryTotalMb: 32_768, diskTotalMb: 32_768 }),
        getStatus: () => {
          statusProbes += 1;
          return Effect.succeed(statusProbes === 1 ? "paused" : "running");
        },
        resume: (_provider: string, providerVmId: string) =>
          Effect.succeed({ provider: "freestyle", providerVmId, status: "running", image: "sh-devbox", createdAt: 0 }),
        statFile: () => Effect.succeed({ path: "/tmp/a", kind: "file", size: 0, mode: 0o644, modifiedAt: 0 }),
      } as unknown as VmProviderGatewayShape;
      const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider));
      const exit = await Effect.runPromiseExit(
        statVmFile({ ...caller, callerPlanId: "team", maxActiveVms: 40, entitlementOverride }, "/tmp/a").pipe(Effect.provide(layer)) as Effect.Effect<unknown, unknown>,
      );
      expect(Exit.isSuccess(exit) ? "ok" : Cause.pretty(exit.cause)).toBe("ok");
      expect(repaired).toEqual([{ vcpus: 8, memoryMb: 32_768 }]);
      expect(reservations).toHaveLength(1);
      expect(reservations[0]?.skipActiveLimit).toBe(grandfathered);
      expect(reservations[0]?.poolVcpus).toBe(grandfathered ? null : 320);
      expect(reservations[0]?.poolMemoryMb).toBe(grandfathered ? null : 655_360);
    });
  }
});
