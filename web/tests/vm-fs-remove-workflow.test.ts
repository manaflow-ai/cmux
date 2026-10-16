import { describe, expect, test } from "bun:test";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import { VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { removeVmFile } from "../services/vms/workflows";

// DELETE /api/vm/[id]/fs/remove: a missing path answers 404 vm_file_not_found, so a retry is correct.
// Freestyle (verified on our dev VM 2026-10-04): fs.remove of a missing path succeeds (200) and
// fs.stat answers FreestyleApiError 404 NOT_FOUND "not found: <path>: No such file or directory (os error 2)".

const row = (): CloudVmRow => ({
  id: "row-1", userId: "user-1", billingTeamId: "team-1", ownerTeamId: "team-1", coderouterPoolId: null, billingPlanId: "pro",
  provider: "freestyle", providerVmId: "fs-1", displayName: null, slug: "brave-otter", imageId: "sh-devbox", imageVersion: null,
  status: "running", idempotencyKey: null, createdAt: new Date(0), updatedAt: new Date(0), destroyedAt: null, failureCode: null,
  failureMessage: null, providerMetadata: {},
}) as CloudVmRow;

const missingPath = (path: string) => Object.assign(new Error(`not found: ${path}: No such file or directory (os error 2)`), { name: "FreestyleApiError", status: 404, code: "NOT_FOUND" });

function fakes(statFailure?: unknown) {
  const removed: string[] = [];
  const repo = { findUserVm: () => Effect.succeed(row()) } as unknown as VmRepositoryShape;
  const provider = {
    getStats: () => Effect.succeed({ cpus: 4, memoryTotalMb: 8192, diskTotalMb: 32768 }),
    statFile: (_p: string, _vm: string, path: string) =>
      statFailure === undefined
        ? Effect.succeed({ path, kind: "file" as const })
        : Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "statFile", cause: statFailure })),
    removeFile: (_p: string, _vm: string, path: string) => Effect.sync(() => void removed.push(path)),
  } as unknown as VmProviderGatewayShape;
  return { removed, layer: Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider)) };
}

const caller = { userId: "user-1", billingTeamId: "team-1", callerPlanId: "pro", teamIds: ["team-1"], providerVmId: "fs-1" };

async function failureTag(layer: Layer.Layer<VmRepository | VmProviderGateway>, path: string): Promise<string | null> {
  const exit = await Effect.runPromiseExit(removeVmFile(caller, path).pipe(Effect.provide(layer)) as Effect.Effect<void, unknown>);
  if (Exit.isSuccess(exit)) return null;
  const failure = Cause.failureOption(exit.cause);
  return failure._tag === "Some" ? ((failure.value as { _tag?: string })._tag ?? "unknown") : "die";
}

describe("removeVmFile", () => {
  test("removes an existing file", async () => {
    const { removed, layer } = fakes();
    expect(await failureTag(layer, "/home/user/a.txt")).toBeNull();
    expect(removed).toEqual(["/home/user/a.txt"]);
  });

  test("a missing path is VmFileNotFoundError (404 vm_file_not_found) and nothing is removed", async () => {
    const { removed, layer } = fakes(missingPath("/home/user/gone.txt"));
    expect(await failureTag(layer, "/home/user/gone.txt")).toBe("VmFileNotFoundError");
    expect(removed).toEqual([]);
  });

  test("any other stat failure stays a provider failure (a missing VM is not a missing file)", async () => {
    const { layer } = fakes(Object.assign(new Error("vm not found"), { status: 404, code: "VM_NOT_FOUND" }));
    expect(await failureTag(layer, "/home/user/a.txt")).toBe("VmProviderOperationError");
  });
});
