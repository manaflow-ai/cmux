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
  const provider = { statFile: fail("statFile"), readFile: fail("readFile"), listFiles: fail("listFiles") } as unknown as VmProviderGatewayShape;
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
