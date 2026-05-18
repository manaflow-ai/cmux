import { beforeEach, describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import { FreestyleActionSnapshotLookupError } from "../services/actions/freestyleSnapshots";

let vmCreateEnabledError: unknown | null = null;
const assertVmCreateEnabled = mock(() => {
  if (vmCreateEnabledError) throw vmCreateEnabledError;
});
let resolveVmImageError: unknown | null = null;
const resolveVmImage = mock(() => {
  if (resolveVmImageError) throw resolveVmImageError;
  return {
    image: "base-image",
    imageVersion: "base-version",
  };
});
let resolveVmEntitlementsError: Error | null = null;
const resolveVmEntitlements = mock(() => {
  if (resolveVmEntitlementsError) throw resolveVmEntitlementsError;
  return {
    billingCustomerType: "team" as const,
    billingTeamId: "team-actions-runner",
    planId: "free",
    maxActiveVms: 5,
  };
});
let failCacheLookup = false;
let execExitCode = 42;
let execWorkflowThrowOnCall: number | null = null;
let execWorkflowCalls = 0;
let snapshotFails = false;
const findFreestyleActionSnapshotByName = mock(() => {
  if (failCacheLookup) {
    return Effect.fail(new FreestyleActionSnapshotLookupError({
      kind: "request",
      cause: new Error("vendor failure reason should stay hidden"),
    }));
  }
  return Effect.succeed(null);
});
const createVm = mock((input: unknown) => ({ kind: "create", input }));
const execVm = mock((input: unknown) => ({ kind: "exec", input }));
const snapshotVm = mock((input: unknown) => ({ kind: "snapshot", input }));
const destroyVm = mock((input: unknown) => ({ kind: "destroy", input }));
const runVmWorkflow = mock(async (workflow: unknown) => {
  const kind = typeof workflow === "object" && workflow !== null && "kind" in workflow
    ? String(workflow.kind)
    : "";
  switch (kind) {
    case "create":
      return {
        provider: "freestyle",
        providerVmId: "vm-actions-runner-fail",
        image: "base-image",
        createdAt: "2026-05-18T00:00:00.000Z",
      };
    case "exec":
      execWorkflowCalls += 1;
      if (execWorkflowThrowOnCall === execWorkflowCalls) {
        throw new Error("provider timeout should stay server-side");
      }
      return {
        exitCode: execExitCode,
        stdout: "",
        stderr: "SECRET_SHOULD_NOT_REACH_CLIENT",
      };
    case "snapshot":
      if (snapshotFails) throw new Error("provider snapshot failure should stay hidden");
      return undefined;
    case "destroy":
      return undefined;
    default:
      throw new Error(`unexpected workflow ${kind}`);
  }
});

const { isActionRunError, runAction } = await import("../services/actions/runner");
const { VmCreateDisabledError, VmImageConfigError } = await import("../services/vms/errors");

beforeEach(() => {
  assertVmCreateEnabled.mockClear();
  vmCreateEnabledError = null;
  resolveVmImageError = null;
  resolveVmImage.mockClear();
  resolveVmEntitlementsError = null;
  resolveVmEntitlements.mockClear();
  findFreestyleActionSnapshotByName.mockClear();
  failCacheLookup = false;
  execExitCode = 42;
  execWorkflowThrowOnCall = null;
  execWorkflowCalls = 0;
  snapshotFails = false;
  createVm.mockClear();
  execVm.mockClear();
  snapshotVm.mockClear();
  destroyVm.mockClear();
  runVmWorkflow.mockClear();
});

describe("cloud action runner", () => {
  test("keeps command stderr out of user-facing action failure details", async () => {
    try {
      await runAction({
        request: {
          action: "hexclave/stack-auth:fresh-env",
          ref: "dev",
        },
        user: {
          id: "user-actions-runner",
          displayName: null,
          primaryEmail: "user@example.com",
          billingCustomerType: "team",
          billingTeamId: "team-actions-runner",
          selectedTeamId: "team-actions-runner",
          teams: [{ id: "team-actions-runner", billingPlanId: "free" }],
          teamIds: ["team-actions-runner"],
          userBillingPlanId: null,
          billingPlanId: "free",
        },
        dependencies: {
          assertVmCreateEnabled,
          resolveVmImage,
          resolveVmEntitlements,
          findFreestyleActionSnapshotByName,
          createVm,
          destroyVm,
          execVm,
          runVmWorkflow,
          snapshotVm,
        },
      });
      throw new Error("expected action run to fail");
    } catch (err) {
      expect(isActionRunError(err)).toBe(true);
      if (!isActionRunError(err)) throw err;
      expect(err.code).toBe("actions_setup_failed");
      expect(err.action).toContain("--keep");
      expect(err.action).not.toContain("cmux vm ssh vm-actions-runner-fail");
      expect(err.details).toEqual({ phase: "setup", exitCode: 42, vmKept: false });
      expect(String(err)).not.toContain("SECRET_SHOULD_NOT_REACH_CLIENT");
      expect(err.message).not.toContain("SECRET_SHOULD_NOT_REACH_CLIENT");
      expect(JSON.stringify(err.details)).not.toContain("SECRET_SHOULD_NOT_REACH_CLIENT");
    }

    expect(destroyVm).toHaveBeenCalledWith({
      userId: "user-actions-runner",
      providerVmId: "vm-actions-runner-fail",
    });
    expect(runVmWorkflow).toHaveBeenCalledWith(expect.objectContaining({
      kind: "destroy",
      input: {
        userId: "user-actions-runner",
        providerVmId: "vm-actions-runner-fail",
      },
    }));
  });

  test("continues without cache when cache lookup fails", async () => {
    failCacheLookup = true;
    execExitCode = 0;
    const originalWarn = console.warn;
    console.warn = mock(() => {}) as unknown as typeof console.warn;
    try {
      const result = await runAction({
        request: {
          action: "hexclave/stack-auth:fresh-env",
          ref: "dev",
        },
        user: {
          id: "user-actions-runner",
          displayName: null,
          primaryEmail: "user@example.com",
          billingCustomerType: "team",
          billingTeamId: "team-actions-runner",
          selectedTeamId: "team-actions-runner",
          teams: [{ id: "team-actions-runner", billingPlanId: "free" }],
          teamIds: ["team-actions-runner"],
          userBillingPlanId: null,
          billingPlanId: "free",
        },
        dependencies: {
          assertVmCreateEnabled,
          resolveVmImage,
          resolveVmEntitlements,
          findFreestyleActionSnapshotByName,
          createVm,
          destroyVm,
          execVm,
          runVmWorkflow,
          snapshotVm,
        },
      });

      expect(result.started).toBe(true);
      expect(result.setupRan).toBe(true);
      expect(result.cache.hit).toBe(false);
      expect(console.warn).toHaveBeenCalled();
    } finally {
      console.warn = originalWarn;
    }

    expect(createVm).toHaveBeenCalled();
    expect(execVm).toHaveBeenCalledTimes(2);
  });

  test("keeps start phase when exec workflow throws after setup", async () => {
    execExitCode = 0;
    execWorkflowThrowOnCall = 2;

    try {
      await runAction({
        request: {
          action: "hexclave/stack-auth:fresh-env",
          ref: "dev",
        },
        user: testUser(),
        dependencies: {
          assertVmCreateEnabled,
          resolveVmImage,
          resolveVmEntitlements,
          findFreestyleActionSnapshotByName,
          createVm,
          destroyVm,
          execVm,
          runVmWorkflow,
          snapshotVm,
        },
      });
      throw new Error("expected action run to fail");
    } catch (err) {
      expect(isActionRunError(err)).toBe(true);
      if (!isActionRunError(err)) throw err;
      expect(err.code).toBe("actions_start_failed");
      expect(err.message).toBe("The action start step failed.");
      expect(err.details).toEqual({ phase: "start", vmKept: false });
      expect(JSON.stringify(err.details)).not.toContain("provider timeout");
    }

    expect(destroyVm).toHaveBeenCalledWith({
      userId: "user-actions-runner",
      providerVmId: "vm-actions-runner-fail",
    });
  });

  test("dry-run does not require VM creation to be enabled", async () => {
    vmCreateEnabledError = new Error("Cloud VM creation disabled");

    const result = await runAction({
      request: {
        action: "hexclave/stack-auth:fresh-env",
        dryRun: true,
      },
      user: testUser(),
      dependencies: {
        assertVmCreateEnabled,
        resolveVmImage,
        resolveVmEntitlements,
        findFreestyleActionSnapshotByName,
        createVm,
        destroyVm,
        execVm,
        runVmWorkflow,
        snapshotVm,
      },
    });

    expect(result.dryRun).toBe(true);
    expect(assertVmCreateEnabled).not.toHaveBeenCalled();
    expect(resolveVmImage).not.toHaveBeenCalled();
    expect(createVm).not.toHaveBeenCalled();
  });

  test("converts disabled VM creation into a safe action error", async () => {
    vmCreateEnabledError = new VmCreateDisabledError({
      provider: "freestyle",
      reason: "CMUX_VM_CREATE_ENABLED=false",
    });

    try {
      await runAction({
        request: {
          action: "hexclave/stack-auth:fresh-env",
          ref: "dev",
        },
        user: testUser(),
        dependencies: {
          assertVmCreateEnabled,
          resolveVmImage,
          resolveVmEntitlements,
          findFreestyleActionSnapshotByName,
          createVm,
          destroyVm,
          execVm,
          runVmWorkflow,
          snapshotVm,
        },
      });
      throw new Error("expected action run to fail");
    } catch (err) {
      expect(isActionRunError(err)).toBe(true);
      if (!isActionRunError(err)) throw err;
      expect(err.code).toBe("actions_vm_create_disabled");
      expect(err.status).toBe(503);
      expect(err.message).toBe("Cloud Actions are disabled for this environment.");
      expect(err.message).not.toContain("CMUX_VM_CREATE_ENABLED");
      expect(err.message).not.toContain("freestyle");
      expect(JSON.stringify(err.details)).not.toContain("CMUX_VM_CREATE_ENABLED");
      expect(JSON.stringify(err.details)).not.toContain("freestyle");
    }

    expect(resolveVmImage).not.toHaveBeenCalled();
    expect(createVm).not.toHaveBeenCalled();
  });

  test("converts action image config failures into a safe action error", async () => {
    resolveVmImageError = new VmImageConfigError({
      provider: "freestyle",
      envVar: "CMUX_VM_FREESTYLE_IMAGE",
      reason: "missing image secret",
    });

    try {
      await runAction({
        request: {
          action: "hexclave/stack-auth:fresh-env",
          ref: "dev",
        },
        user: testUser(),
        dependencies: {
          assertVmCreateEnabled,
          resolveVmImage,
          resolveVmEntitlements,
          findFreestyleActionSnapshotByName,
          createVm,
          destroyVm,
          execVm,
          runVmWorkflow,
          snapshotVm,
        },
      });
      throw new Error("expected action run to fail");
    } catch (err) {
      expect(isActionRunError(err)).toBe(true);
      if (!isActionRunError(err)) throw err;
      expect(err.code).toBe("actions_image_unavailable");
      expect(err.status).toBe(503);
      expect(err.message).toBe("The Cloud Actions VM image is unavailable in this environment.");
      expect(err.message).not.toContain("CMUX_VM_FREESTYLE_IMAGE");
      expect(err.message).not.toContain("freestyle");
      expect(JSON.stringify(err.details)).not.toContain("CMUX_VM_FREESTYLE_IMAGE");
      expect(JSON.stringify(err.details)).not.toContain("freestyle");
    }

    expect(createVm).not.toHaveBeenCalled();
  });

  test("converts entitlement config failures into safe action errors", async () => {
    resolveVmEntitlementsError = new Error("CMUX_VM_FREE_MAX_ACTIVE_VMS has secret upstream config details");

    try {
      await runAction({
        request: {
          action: "hexclave/stack-auth:fresh-env",
          ref: "dev",
        },
        user: testUser(),
        dependencies: {
          assertVmCreateEnabled,
          resolveVmImage,
          resolveVmEntitlements,
          findFreestyleActionSnapshotByName,
          createVm,
          destroyVm,
          execVm,
          runVmWorkflow,
          snapshotVm,
        },
      });
      throw new Error("expected action run to fail");
    } catch (err) {
      expect(isActionRunError(err)).toBe(true);
      if (!isActionRunError(err)) throw err;
      expect(err.code).toBe("actions_entitlements_unavailable");
      expect(err.message).not.toContain("CMUX_VM_FREE_MAX_ACTIVE_VMS");
      expect(err.action).toContain("Retry");
      expect(err.details).toEqual({ phase: "entitlements" });
    }

    expect(createVm).not.toHaveBeenCalled();
  });

  test("continues with the live VM when cache snapshot creation fails", async () => {
    execExitCode = 0;
    snapshotFails = true;
    const originalWarn = console.warn;
    console.warn = mock(() => {}) as unknown as typeof console.warn;
    try {
      const result = await runAction({
        request: {
          action: "hexclave/stack-auth:fresh-env",
          ref: "dev",
        },
        user: testUser(),
        dependencies: {
          assertVmCreateEnabled,
          resolveVmImage,
          resolveVmEntitlements,
          findFreestyleActionSnapshotByName,
          createVm,
          destroyVm,
          execVm,
          runVmWorkflow,
          snapshotVm,
        },
      });

      expect(result.started).toBe(true);
      expect(result.setupRan).toBe(true);
      expect(result.cache.hit).toBe(false);
      expect(destroyVm).not.toHaveBeenCalled();
      expect(execVm).toHaveBeenCalledTimes(2);
    } finally {
      console.warn = originalWarn;
    }
  });
});

function testUser() {
  return {
    id: "user-actions-runner",
    displayName: null,
    primaryEmail: "user@example.com",
    billingCustomerType: "team" as const,
    billingTeamId: "team-actions-runner",
    selectedTeamId: "team-actions-runner",
    teams: [{ id: "team-actions-runner", billingPlanId: "free" }],
    teamIds: ["team-actions-runner"],
    userBillingPlanId: null,
    billingPlanId: "free",
  };
}
