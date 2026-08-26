import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import {
  VmNotFoundError,
  VmSnapshotNotFoundError,
  isVmWorkflowError,
} from "../services/vms/errors";
import { runVmWorkflow, runVmWorkflowExit } from "../services/vms/workflows";

describe("runVmWorkflowExit", () => {
  test("returns the success value in the ok branch", async () => {
    const result = await runVmWorkflowExit(Effect.succeed(42));
    expect(result).toEqual({ ok: true, value: 42 });
  });

  test("returns the tagged workflow error in the failure branch", async () => {
    const error = new VmNotFoundError({ vmId: "vm-1" });
    const result = await runVmWorkflowExit(Effect.fail(error));
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBe(error);
      expect(result.error._tag).toBe("VmNotFoundError");
    }
  });

  test("unwraps VmSnapshotNotFoundError (previously missed by the tag walk)", async () => {
    const error = new VmSnapshotNotFoundError({ snapshotId: "snap-1" });
    const result = await runVmWorkflowExit(Effect.fail(error));
    expect(result).toEqual({ ok: false, error });
  });

  test("rethrows defects raw so the route boundary can 500 and capture them", async () => {
    const defect = new Error("boom");
    await expect(runVmWorkflowExit(Effect.die(defect))).rejects.toBe(defect);
  });
});

describe("runVmWorkflow", () => {
  test("resolves with the success value", async () => {
    await expect(runVmWorkflow(Effect.succeed("ok"))).resolves.toBe("ok");
  });

  test("rejects with the tagged error itself, never a FiberFailure wrapper", async () => {
    const error = new VmNotFoundError({ vmId: "vm-2" });
    const caught: unknown = await runVmWorkflow(Effect.fail(error)).then(
      () => null,
      (err: unknown) => err,
    );
    expect(caught).toBe(error);
    expect(isVmWorkflowError(caught)).toBe(true);
    const fiberFailureSymbols = Object.getOwnPropertySymbols(caught as object).filter(
      (symbol) => symbol.description === "effect/Runtime/FiberFailure/Cause",
    );
    expect(fiberFailureSymbols).toHaveLength(0);
  });

  test("rejects with the raw defect for unmodeled failures", async () => {
    const defect = new Error("bug, not a modeled failure");
    await expect(runVmWorkflow(Effect.die(defect))).rejects.toBe(defect);
  });
});
