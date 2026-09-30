import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const workflowsModule = await import("../services/vms/workflows");
const realRunVmWorkflow = workflowsModule.runVmWorkflow;
const realReconcileVmProviderStatuses = workflowsModule.reconcileVmProviderStatuses;
const realReapStaleVmTunnels = workflowsModule.reapStaleVmTunnels;
const tunnelReap = { candidates: 3, reaped: 2, skipped: 0, failed: 1, budgetExhausted: false };
const runVmWorkflow = mock(async (program: unknown) =>
  (program as { workflow?: string }).workflow === "tunnel-reap" ? tunnelReap : {
    checked: 2,
    updated: 1,
    destroyed: 0,
    skipped: 1,
    skippedNoGetStatus: false,
  });
const reconcileVmProviderStatuses = mock(() => ({ workflow: "vm-reconcile" }));
const reapStaleVmTunnels = mock(() => ({ workflow: "tunnel-reap" }));
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
  reapStaleVmTunnels: ((...args: Parameters<typeof realReapStaleVmTunnels>) =>
    useWorkflowStubs
      ? callMock(reapStaleVmTunnels, args)
      : realReapStaleVmTunnels(...args)) as typeof realReapStaleVmTunnels,
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
  reapStaleVmTunnels.mockClear();
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
    expect(reapStaleVmTunnels).not.toHaveBeenCalled();
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

  test("runs the reconcile workflow for a valid cron bearer secret", async () => {
    const response = await GET(new Request("https://cmux.test/api/cron/vm-reconcile", {
      headers: { authorization: "Bearer cron-secret" },
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      checked: 2,
      updated: 1,
      destroyed: 0,
      skipped: 1,
      skippedNoGetStatus: false,
      staleTunnels: tunnelReap,
    });
    expect(reapStaleVmTunnels).toHaveBeenCalledTimes(1);
    // Machines the provider reports gone get their coderouter tokens revoked,
    // so the cron hands the workflow the model-plane revoker.
    const reconcileCalls = (reconcileVmProviderStatuses as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    expect(reconcileCalls).toHaveLength(1);
    const reconcileInput = reconcileCalls[0]?.[0] as { modelPlane?: { revoke?: unknown }; teamDirectory?: { listMemberIds?: unknown } } | undefined;
    expect(typeof reconcileInput?.modelPlane?.revoke).toBe("function");
    expect(typeof reconcileInput?.teamDirectory?.listMemberIds).toBe("function");
    expect(runVmWorkflow).toHaveBeenCalledWith({ workflow: "vm-reconcile" });
    expect(runVmWorkflow).toHaveBeenCalledWith({ workflow: "tunnel-reap" });
  });

  test("a failed tunnel reap does not fail the status reconcile", async () => {
    runVmWorkflow.mockImplementationOnce(async () => ({
      checked: 0, updated: 0, destroyed: 0, skipped: 0, skippedNoGetStatus: false,
    }));
    runVmWorkflow.mockImplementationOnce(async () => { throw new Error("database down"); });

    const response = await GET(new Request("https://cmux.test/api/cron/vm-reconcile", {
      headers: { authorization: "Bearer cron-secret" },
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ ok: true, staleTunnels: { error: "tunnel_reap_failed" } });
  });
});
