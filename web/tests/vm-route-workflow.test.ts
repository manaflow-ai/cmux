import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Runtime from "effect/Runtime";

import {
  VmCreateInProgressError,
  VmNotFoundError,
  VmSnapshotNotFoundError,
  isVmWorkflowError,
  vmWorkflowErrorCause,
  type VmWorkflowError,
} from "../services/vms/errors";
import { vmErrorResponse, vmWorkflowErrorResponders } from "../services/vms/routeHelpers";
import { runVmRoute } from "../services/vms/routeWorkflow";
import { runVmWorkflow } from "../services/vms/workflows";

const notFound = new VmNotFoundError({ vmId: "vm-missing" });

describe("runVmRoute", () => {
  test("returns the program value on success", async () => {
    const run = await runVmRoute(Effect.succeed({ id: "vm-1" }));
    expect(run).toEqual({ ok: true, value: { id: "vm-1" } });
  });

  test("answers a typed failure from the shared responder table", async () => {
    const run = await runVmRoute(Effect.fail(notFound));
    expect(run.ok).toBe(false);
    if (run.ok) return;
    expect(run.response.status).toBe(404);
    const payload = await run.response.json() as { error: string; details?: { vmId?: string } };
    expect(payload.error).toBe("vm_not_found");
    expect(payload.details?.vmId).toBe("vm-missing");
  });

  test("a route override wins over the shared table and sees the narrowed error", async () => {
    const run = await runVmRoute(Effect.fail(notFound), {
      onError: {
        VmNotFoundError: (error) =>
          vmErrorResponse({
            error: "custom_not_found",
            status: 410,
            message: `gone: ${error.vmId}`,
            action: "none",
          }),
      },
    });
    expect(run.ok).toBe(false);
    if (run.ok) return;
    expect(run.response.status).toBe(410);
    expect(((await run.response.json()) as { error: string }).error).toBe("custom_not_found");
  });

  test("a failure with no responder is thrown as the typed error for the route catch-all", async () => {
    const error = new VmCreateInProgressError({ idempotencyKey: "k" });
    await expect(runVmRoute(Effect.fail(error))).rejects.toBe(error);
  });

  test("a defect is thrown as the squashed cause, never mapped to a contract error", async () => {
    const bug = new Error("boom");
    await expect(runVmRoute(Effect.die(bug))).rejects.toBe(bug);
  });

  test("locale comes from the request when no explicit locale is given", async () => {
    const request = new Request("https://cmux.com/api/vm", { headers: { "x-next-intl-locale": "ja" } });
    const run = await runVmRoute(Effect.fail(new VmSnapshotNotFoundError({ snapshotId: "s" })), { request });
    expect(run.ok).toBe(false);
    if (run.ok) return;
    expect(run.response.status).toBe(404);
  });
});

describe("runVmWorkflow", () => {
  test("throws the typed error itself, not a FiberFailure", async () => {
    let thrown: unknown;
    try {
      await runVmWorkflow(Effect.fail(notFound));
    } catch (err) {
      thrown = err;
    }
    expect(Runtime.isFiberFailure(thrown)).toBe(false);
    expect(thrown).toBe(notFound);
    expect(isVmWorkflowError(thrown)).toBe(true);
  });

  test("rethrows a defect as the underlying error", async () => {
    const bug = new Error("bug");
    await expect(runVmWorkflow(Effect.die(bug))).rejects.toBe(bug);
  });
});

describe("vmWorkflowErrorCause", () => {
  test("unwraps a FiberFailure from a raw Effect.runPromise through the public Runtime API", async () => {
    let thrown: unknown;
    try {
      await Effect.runPromise(Effect.fail(notFound));
    } catch (err) {
      thrown = err;
    }
    expect(Runtime.isFiberFailure(thrown)).toBe(true);
    expect(vmWorkflowErrorCause(thrown)).toBe(notFound);
  });

  test("walks a plain Error cause chain", () => {
    const wrapped = new Error("outer", { cause: new Error("mid", { cause: notFound }) });
    expect(vmWorkflowErrorCause(wrapped)).toBe(notFound);
  });
});

describe("vmWorkflowErrorResponders", () => {
  test("has a responder for every workflow error tag", () => {
    const tags = Object.keys(vmWorkflowErrorResponders) as Array<VmWorkflowError["_tag"]>;
    expect(tags.length).toBeGreaterThan(20);
    for (const tag of tags) {
      expect(typeof vmWorkflowErrorResponders[tag]).toBe("function");
    }
  });
});
