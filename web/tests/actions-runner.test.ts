import { beforeEach, describe, expect, mock, test } from "bun:test";

const assertVmCreateEnabled = mock(() => undefined);
const resolveVmImage = mock(() => ({
  image: "base-image",
  imageVersion: "base-version",
}));
const resolveVmEntitlements = mock(() => ({
  billingCustomerType: "team" as const,
  billingTeamId: "team-actions-runner",
  planId: "free",
  maxActiveVms: 5,
}));
const isVmBillingTeamResolutionError = mock(() => false);
let failCacheLookup = false;
const findFreestyleActionSnapshotByName = mock(async () => {
  if (failCacheLookup) throw new Error("vendor failure reason should stay hidden");
  return null;
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
      return {
        exitCode: 42,
        stdout: "",
        stderr: "SECRET_SHOULD_NOT_REACH_CLIENT",
      };
    case "snapshot":
    case "destroy":
      return undefined;
    default:
      throw new Error(`unexpected workflow ${kind}`);
  }
});

const { isActionRunError, runAction } = await import("../services/actions/runner");

beforeEach(() => {
  assertVmCreateEnabled.mockClear();
  resolveVmImage.mockClear();
  resolveVmEntitlements.mockClear();
  isVmBillingTeamResolutionError.mockClear();
  findFreestyleActionSnapshotByName.mockClear();
  failCacheLookup = false;
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
          isVmBillingTeamResolutionError,
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
      expect(JSON.stringify(err.details)).not.toContain("SECRET_SHOULD_NOT_REACH_CLIENT");
    }

    expect(destroyVm).toHaveBeenCalledWith({
      userId: "user-actions-runner",
      providerVmId: "vm-actions-runner-fail",
    });
  });

  test("converts cache lookup failures into safe action errors", async () => {
    failCacheLookup = true;

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
          isVmBillingTeamResolutionError,
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
      expect(err.code).toBe("actions_cache_unavailable");
      expect(err.message).not.toContain("vendor");
      expect(err.action).toContain("--no-cache");
      expect(err.details).toEqual({ phase: "cache_lookup" });
    }

    expect(createVm).not.toHaveBeenCalled();
  });
});
