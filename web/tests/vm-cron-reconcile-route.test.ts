import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const workflowsModule = await import("../services/vms/workflows");
const realRunVmWorkflow = workflowsModule.runVmWorkflow;
const realReconcileVmProviderStatuses = workflowsModule.reconcileVmProviderStatuses;
const realSweepStuckProvisioningVms = workflowsModule.sweepStuckProvisioningVms;
const realReconcileCreditReservations = workflowsModule.reconcileCreditReservations;

const providerStatusResult = {
  checked: 2,
  updated: 1,
  destroyed: 0,
  skipped: 1,
  skippedNoGetStatus: false,
};
const stuckProvisioningResult = { swept: 1, supported: true };
const creditReservationResult = {
  checked: 1,
  committed: 0,
  refunded: 1,
  refundFailed: 0,
  abandoned: 0,
  skipped: 0,
  supported: true,
};

const runVmWorkflow = mock(async (program: unknown) => {
  const workflow = (program as { workflow?: string }).workflow;
  if (workflow === "stuck-provisioning") return stuckProvisioningResult;
  if (workflow === "credit-reservations") return creditReservationResult;
  return providerStatusResult;
});
const reconcileVmProviderStatuses = mock(() => ({ workflow: "vm-reconcile" }));
const sweepStuckProvisioningVms = mock(() => ({ workflow: "stuck-provisioning" }));
const reconcileCreditReservations = mock(() => ({ workflow: "credit-reservations" }));
let useWorkflowStubs = false;

function callMock(fn: unknown, args: unknown[]) {
  return (fn as (...args: unknown[]) => unknown)(...args);
}

mock.module("../services/vms/workflows", () => ({
  ...workflowsModule,
  reconcileVmProviderStatuses: ((...args: Parameters<typeof realReconcileVmProviderStatuses>) =>
    useWorkflowStubs
      ? callMock(reconcileVmProviderStatuses, args)
      : realReconcileVmProviderStatuses(...args)) as typeof realReconcileVmProviderStatuses,
  sweepStuckProvisioningVms: ((...args: Parameters<typeof realSweepStuckProvisioningVms>) =>
    useWorkflowStubs
      ? callMock(sweepStuckProvisioningVms, args)
      : realSweepStuckProvisioningVms(...args)) as typeof realSweepStuckProvisioningVms,
  reconcileCreditReservations: ((...args: Parameters<typeof realReconcileCreditReservations>) =>
    useWorkflowStubs
      ? callMock(reconcileCreditReservations, args)
      : realReconcileCreditReservations(...args)) as typeof realReconcileCreditReservations,
  runVmWorkflow: ((...args: Parameters<typeof realRunVmWorkflow>) =>
    useWorkflowStubs
      ? callMock(runVmWorkflow, args)
      : realRunVmWorkflow(...args)) as typeof realRunVmWorkflow,
}));

const { GET } = await import("../app/api/cron/vm-reconcile/route");

const originalCronSecret = process.env.CRON_SECRET;

beforeEach(() => {
  useWorkflowStubs = true;
  process.env.CRON_SECRET = "cron-secret";
  runVmWorkflow.mockClear();
  reconcileVmProviderStatuses.mockClear();
  sweepStuckProvisioningVms.mockClear();
  reconcileCreditReservations.mockClear();
});

afterEach(() => {
  useWorkflowStubs = false;
  if (originalCronSecret === undefined) {
    delete process.env.CRON_SECRET;
  } else {
    process.env.CRON_SECRET = originalCronSecret;
  }
});

describe("VM reconcile cron route", () => {
  test("rejects requests without the cron bearer secret before running workflows", async () => {
    const responses = await Promise.all([
      GET(new Request("https://cmux.test/api/cron/vm-reconcile")),
      GET(new Request("https://cmux.test/api/cron/vm-reconcile", {
        headers: { authorization: "Bearer wrong-secret" },
      })),
    ]);

    for (const response of responses) {
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(reconcileVmProviderStatuses).not.toHaveBeenCalled();
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects all requests when CRON_SECRET is not configured", async () => {
    delete process.env.CRON_SECRET;

    const response = await GET(new Request("https://cmux.test/api/cron/vm-reconcile", {
      headers: { authorization: "Bearer cron-secret" },
    }));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(reconcileVmProviderStatuses).not.toHaveBeenCalled();
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("runs the reconcile, sweep, and credit workflows for a valid cron bearer secret", async () => {
    const response = await GET(new Request("https://cmux.test/api/cron/vm-reconcile", {
      headers: { authorization: "Bearer cron-secret" },
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      ...providerStatusResult,
      stuckProvisioning: stuckProvisioningResult,
      creditReservations: creditReservationResult,
    });
    expect(reconcileVmProviderStatuses).toHaveBeenCalledWith();
    expect(sweepStuckProvisioningVms).toHaveBeenCalledWith();
    expect(reconcileCreditReservations).toHaveBeenCalledWith();
    expect(runVmWorkflow).toHaveBeenCalledWith({ workflow: "vm-reconcile" });
    expect(runVmWorkflow).toHaveBeenCalledWith({ workflow: "stuck-provisioning" });
    expect(runVmWorkflow).toHaveBeenCalledWith({ workflow: "credit-reservations" });
  });

  test("rejected requests never run the sweep or credit workflows", async () => {
    const response = await GET(new Request("https://cmux.test/api/cron/vm-reconcile"));
    expect(response.status).toBe(401);
    expect(sweepStuckProvisioningVms).not.toHaveBeenCalled();
    expect(reconcileCreditReservations).not.toHaveBeenCalled();
  });
});
