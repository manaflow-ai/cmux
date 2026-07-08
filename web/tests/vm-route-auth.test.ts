import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

const getUser = mock(async () => null);
const runVmWorkflow = mock(async () => {
  throw new Error("unauthenticated VM routes must not reach the VM workflow");
});
const createVm = mock(() => ({ workflow: "create" }));
const openBaseVm = mock(() => ({ workflow: "base.open" }));
const resetBaseVm = mock(() => ({ workflow: "base.reset" }));
const listUserVms = mock(() => ({ workflow: "list" }));
const getVm = mock(() => ({ workflow: "get" }));
const destroyVm = mock(() => ({ workflow: "destroy" }));
const execVm = mock(() => ({ workflow: "exec" }));
const forkVm = mock(() => ({ workflow: "fork" }));
const openAttachEndpoint = mock(() => ({ workflow: "attach" }));
const openSshEndpoint = mock(() => ({ workflow: "ssh" }));
const restoreVm = mock(() => ({ workflow: "restore" }));
const snapshotVm = mock(() => ({ workflow: "snapshot" }));
const VM_ENV_KEYS = [
  "CMUX_VM_CREATE_ENABLED",
  "CMUX_VM_E2B_ENABLED",
  "CMUX_VM_FREESTYLE_ENABLED",
  "CMUX_VM_ALLOWED_ORIGINS",
  "CMUX_VM_ALLOW_UNMANIFESTED_IMAGES",
  "E2B_CMUXD_WS_TEMPLATE",
  "FREESTYLE_SANDBOX_SNAPSHOT",
  "CMUX_VM_FREE_MAX_ACTIVE_VMS",
  "CMUX_VM_PAID_MAX_ACTIVE_VMS",
  "CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS",
  "CMUX_VM_REQUIRE_PRO",
  "VERCEL",
  "VERCEL_ENV",
] as const;
const originalEnv = Object.fromEntries(
  VM_ENV_KEYS.map((key) => [key, process.env[key]]),
) as Record<(typeof VM_ENV_KEYS)[number], string | undefined>;

// Capture the real implementations BY VALUE before mocking. bun's
// mock.module can mutate an already-loaded module namespace in place, so a
// captured namespace object would resolve to the mock at call time and a
// delegating wrapper would recurse into itself. Copied function references
// keep pointing at the originals under either registry semantics.
const workflowsModule = await import("../services/vms/workflows");
const realCreateVm = workflowsModule.createVm;
const realDestroyVm = workflowsModule.destroyVm;
const realExecVm = workflowsModule.execVm;
const realForkVm = workflowsModule.forkVm;
const realGetVm = workflowsModule.getVm;
const realListUserVms = workflowsModule.listUserVms;
const realOpenBaseVm = workflowsModule.openBaseVm;
const realOpenAttachEndpoint = workflowsModule.openAttachEndpoint;
const realOpenSshEndpoint = workflowsModule.openSshEndpoint;
const realResetBaseVm = workflowsModule.resetBaseVm;
const realRestoreVm = workflowsModule.restoreVm;
const realRunVmWorkflow = workflowsModule.runVmWorkflow;
const realSnapshotVm = workflowsModule.snapshotVm;
const realVmWorkflowLive = workflowsModule.VmWorkflowLive;
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let useWorkflowStubs = false;
let useStubDb = false;

function callMock(fn: unknown, args: unknown[]) {
  return (fn as (...args: unknown[]) => unknown)(...args);
}

function rejectRunVmWorkflowWith(error: unknown): void {
  (runVmWorkflow as unknown as { mockImplementation(next: () => Promise<never>): void })
    .mockImplementation(async () => {
      throw error;
    });
}

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../services/vms/workflows", () => ({
  VmWorkflowLive: realVmWorkflowLive,
  createVm: ((...args: Parameters<typeof realCreateVm>) =>
    useWorkflowStubs ? callMock(createVm, args) : realCreateVm(...args)) as typeof realCreateVm,
  destroyVm: ((...args: Parameters<typeof realDestroyVm>) =>
    useWorkflowStubs ? callMock(destroyVm, args) : realDestroyVm(...args)) as typeof realDestroyVm,
  execVm: ((...args: Parameters<typeof realExecVm>) =>
    useWorkflowStubs ? callMock(execVm, args) : realExecVm(...args)) as typeof realExecVm,
  forkVm: ((...args: Parameters<typeof realForkVm>) =>
    useWorkflowStubs ? callMock(forkVm, args) : realForkVm(...args)) as typeof realForkVm,
  getVm: ((...args: Parameters<typeof realGetVm>) =>
    useWorkflowStubs ? callMock(getVm, args) : realGetVm(...args)) as typeof realGetVm,
  listUserVms: ((...args: Parameters<typeof realListUserVms>) =>
    useWorkflowStubs ? callMock(listUserVms, args) : realListUserVms(...args)) as typeof realListUserVms,
  openBaseVm: ((...args: Parameters<typeof realOpenBaseVm>) =>
    useWorkflowStubs ? callMock(openBaseVm, args) : realOpenBaseVm(...args)) as typeof realOpenBaseVm,
  openAttachEndpoint: ((...args: Parameters<typeof realOpenAttachEndpoint>) =>
    useWorkflowStubs ? callMock(openAttachEndpoint, args) : realOpenAttachEndpoint(...args)) as typeof realOpenAttachEndpoint,
  openSshEndpoint: ((...args: Parameters<typeof realOpenSshEndpoint>) =>
    useWorkflowStubs ? callMock(openSshEndpoint, args) : realOpenSshEndpoint(...args)) as typeof realOpenSshEndpoint,
  resetBaseVm: ((...args: Parameters<typeof realResetBaseVm>) =>
    useWorkflowStubs ? callMock(resetBaseVm, args) : realResetBaseVm(...args)) as typeof realResetBaseVm,
  restoreVm: ((...args: Parameters<typeof realRestoreVm>) =>
    useWorkflowStubs ? callMock(restoreVm, args) : realRestoreVm(...args)) as typeof realRestoreVm,
  runVmWorkflow: ((...args: Parameters<typeof realRunVmWorkflow>) =>
    useWorkflowStubs ? callMock(runVmWorkflow, args) : realRunVmWorkflow(...args)) as typeof realRunVmWorkflow,
  snapshotVm: ((...args: Parameters<typeof realSnapshotVm>) =>
    useWorkflowStubs ? callMock(snapshotVm, args) : realSnapshotVm(...args)) as typeof realSnapshotVm,
}));

// Self-shield from other suites' process-global db mocks AND from the real
// pool: the VM route's Pro-plan reconcile calls cloudDb(), and without this
// stub the real client can sit retrying a connection (hang) or another
// suite's fixture data leaks in. The thrown message must match pro.ts's
// isMissingDatabaseConfig so the reconcile degrades exactly like a
// DATABASE_URL-less environment.
mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => {
    if (!useStubDb) return realCloudDb();
    throw new Error("DATABASE_URL is required for Cloud VM database access");
  },
}));

const { GET, POST, withBillingReconcileDeadline } = await import("../app/api/vm/route");
const baseOpenRoute = await import("../app/api/vm/base/open/route");
const baseResetRoute = await import("../app/api/vm/base/reset/route");
const vmIdRoute = await import("../app/api/vm/[id]/route");
const { DELETE } = vmIdRoute;
const attachRoute = await import("../app/api/vm/[id]/attach-endpoint/route");
const execRoute = await import("../app/api/vm/[id]/exec/route");
const forkRoute = await import("../app/api/vm/[id]/fork/route");
const snapshotRoute = await import("../app/api/vm/[id]/snapshot/route");
const sshRoute = await import("../app/api/vm/[id]/ssh-endpoint/route");
const restoreRoute = await import("../app/api/vm/restore/route");
const {
  VmCreateCreditsInsufficientError,
  VmCreateFailedError,
  VmProviderOperationError,
} = await import("../services/vms/errors");
const { verifyRequest } = await import("../services/vms/auth");
const { withAuthedVmApiRoute } = await import("../services/vms/routeHelpers");

beforeAll(() => {
  useWorkflowStubs = true;
  useStubDb = true;
});

afterAll(() => {
  useWorkflowStubs = false;
  useStubDb = false;
});

beforeEach(() => {
  restoreVmEnv();
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  runVmWorkflow.mockClear();
  createVm.mockClear();
  openBaseVm.mockClear();
  resetBaseVm.mockClear();
  destroyVm.mockClear();
  execVm.mockClear();
  forkVm.mockClear();
  getVm.mockClear();
  listUserVms.mockClear();
  openAttachEndpoint.mockClear();
  openSshEndpoint.mockClear();
  restoreVm.mockClear();
  snapshotVm.mockClear();
});

afterEach(() => {
  restoreVmEnv();
});

describe("VM REST auth", () => {
  test("rejects unauthenticated provisioning before reaching Postgres or providers", async () => {
    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(getUser).toHaveBeenCalled();
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects unauthenticated VM listing before reaching Postgres", async () => {
    const response = await GET(new Request("https://cmux.test/api/vm"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects unauthenticated VM mutations before reaching workflows", async () => {
    const context = { params: Promise.resolve({ id: "provider-vm-1" }) };
    const responses = await Promise.all([
      DELETE(new Request("https://cmux.test/api/vm/provider-vm-1", { method: "DELETE" }), context),
      attachRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/attach-endpoint", { method: "POST" }), context),
      sshRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/ssh-endpoint", { method: "POST" }), context),
      execRoute.POST(
        new Request("https://cmux.test/api/vm/provider-vm-1/exec", {
          method: "POST",
          body: JSON.stringify({ command: "true" }),
        }),
        context,
      ),
    ]);

    for (const response of responses) {
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects unauthenticated Base open and reset before reaching workflows", async () => {
    const responses = await Promise.all([
      baseOpenRoute.POST(new Request("https://cmux.test/api/vm/base/open", { method: "POST", body: "{}" })),
      baseResetRoute.POST(new Request("https://cmux.test/api/vm/base/reset", { method: "POST", body: "{}" })),
    ]);

    for (const response of responses) {
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(openBaseVm).not.toHaveBeenCalled();
    expect(resetBaseVm).not.toHaveBeenCalled();
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("authenticated provisioning runs the Effect VM workflow", async () => {
    const listTeams = mock(async () => [{
      id: "team-1",
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
    }]);
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      },
      listTeams,
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-1",
      provider: "freestyle",
      image: "snapshot-test",
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "idempotency-key": "idem-1", origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      id: "provider-vm-1",
      provider: "freestyle",
      image: "snapshot-test",
      createdAt: 1_777_000_000_000,
    });
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "user-1",
      billingCustomerType: "team",
      billingTeamId: "team-1",
      billingPlanId: "pro",
      maxActiveVms: 10,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      idempotencyKey: "idem-1",
    }));
    expect(listTeams).not.toHaveBeenCalled();
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("passes configured plan active VM limits into the create workflow", async () => {
    process.env.CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS = "25";
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-plan-limit",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      billingTeamId: "team-1",
      billingPlanId: "pro",
      maxActiveVms: 25,
    }));
  });

  test("blocks a free plan from provisioning when CMUX_VM_REQUIRE_PRO is enforced", async () => {
    process.env.CMUX_VM_REQUIRE_PRO = "1";
    getUser.mockResolvedValue(freePlanStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(402);
    expect((await response.json() as { error: string }).error).toBe("vm_requires_pro");
    expect(createVm).not.toHaveBeenCalled();
  });

  test("lets a pro plan provision even when CMUX_VM_REQUIRE_PRO is enforced", async () => {
    process.env.CMUX_VM_REQUIRE_PRO = "1";
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-pro-gate-ok",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalled();
  });

  test("still lists VMs for a free plan under Pro enforcement (management is not gated)", async () => {
    process.env.CMUX_VM_REQUIRE_PRO = "1";
    getUser.mockResolvedValue(freePlanStackUser());
    runVmWorkflow.mockResolvedValue([]);

    const response = await GET(new Request("https://cmux.test/api/vm"));
    expect(response.status).toBe(200);
    expect(createVm).not.toHaveBeenCalled();
  });

  test("includes original failed create cause in the idempotency failure response", async () => {
    getUser.mockResolvedValue(authedStackUser());
    rejectRunVmWorkflowWith(
      new VmCreateFailedError({
        idempotencyKey: "idem-failed",
        code: "create",
        message: "provider unavailable",
      }),
    );

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "idempotency-key": "idem-failed", origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(500);
    expect(await response.json()).toMatchObject({
      error: "vm_create_failed",
      details: {
        idempotencyKeySet: true,
        failureCode: "create",
        failureMessage: "provider unavailable",
      },
    });
  });

  test("maps create credit exhaustion to a clean payment response", async () => {
    getUser.mockResolvedValue(authedStackUser());
    rejectRunVmWorkflowWith(
      new VmCreateCreditsInsufficientError({
        itemId: "cmux-vm-create-credit",
        billingCustomerId: "team-1",
        amount: 1,
      }),
    );

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "idempotency-key": "idem-credits", origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(402);
    expect(await response.json()).toMatchObject({
      error: "vm_create_credits_insufficient",
      amount: 1,
      details: { amount: 1 },
    });
  });

  test("uses the native client's requested Stack team for billing", async () => {
    const listTeams = mock(async () => [
      {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      },
      {
        id: "team-2",
        clientReadOnlyMetadata: { cmuxVmPlan: "free" },
      },
    ]);
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      },
      listTeams,
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-team-2",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-team-id": "team-2",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      billingCustomerType: "team",
      billingTeamId: "team-2",
      billingPlanId: "free",
      maxActiveVms: 5,
    }));
    expect(listTeams).toHaveBeenCalledTimes(1);
  });

  test("validates a JSON body team id only when it differs from the selected team", async () => {
    const listTeams = mock(async () => [
      {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      },
      {
        id: "team-2",
        clientReadOnlyMetadata: { cmuxVmPlan: "free" },
      },
    ]);
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      },
      listTeams,
      listProducts: async () => Object.assign([], { nextCursor: null }),
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-body-team",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          provider: "freestyle",
          image: "snapshot-test",
          teamId: "team-2",
        }),
      }),
    );

    expect(response.status).toBe(200);
    // initial auth + team-mismatch re-verify + pro-plan reconcile user fetch
    expect(getUser).toHaveBeenCalledTimes(3);
    expect(listTeams).toHaveBeenCalledTimes(1);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      billingCustomerType: "team",
      billingTeamId: "team-2",
      billingPlanId: "free",
      maxActiveVms: 5,
    }));
  });

  test("rejects blank team ids before reaching workflows", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const requests = [
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test", teamId: "   " }),
      }),
      new Request("https://cmux.test/api/vm?teamId=%20%20", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test", "x-cmux-team-id": "  " },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    ];

    for (const request of requests) {
      const response = await POST(request);
      expect(response.status).toBe(400);
      const payload = await response.json();
      expect(payload).toMatchObject({
        error: "vm_invalid_request",
        details: { field: "teamId" },
      });
      expect(payload.message).toContain("non-empty");
      expectNoCloudVmImplementationLeaks(payload);
    }
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects a requested Stack team the caller does not belong to", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-team-id": "team-other",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(403);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_billing_team_not_found",
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.message).toContain("team");
    expect(payload.action).toContain("cmux auth login");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("uses the single Stack team when personal team auto-create populated listTeams", async () => {
    const listTeams = mock(async () => [{
      id: "team-personal",
      clientReadOnlyMetadata: { cmuxVmPlan: "free" },
    }]);
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: null,
      listTeams,
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-personal-team",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      billingCustomerType: "team",
      billingTeamId: "team-personal",
      billingPlanId: "free",
    }));
    expect(listTeams).toHaveBeenCalledTimes(1);
  });

  test("rejects VM create when Stack Auth returns no teams", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: null,
      listTeams: async () => [],
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(409);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_billing_team_required",
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.message).toContain("team");
    expect(payload.action).toContain("Select a team");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects VM create when Stack Auth returns multiple teams but no selected/requested team", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } },
        { id: "team-2", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
      ],
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(409);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_billing_team_required",
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.message).toContain("team");
    expect(payload.action).toContain("Select a team");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("filters VM list to the requested Stack team", async () => {
    const listTeams = mock(async () => [
      { id: "team-1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } },
      { id: "team-2", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
    ]);
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "free" },
      },
      listTeams,
    });
    runVmWorkflow.mockResolvedValue([{
      providerVmId: "provider-vm-team-2",
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
      status: "paused",
      createdAt: 1_777_000_000_000,
    }]);

    const response = await GET(
      new Request("https://cmux.test/api/vm", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-team-id": "team-2",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(listUserVms).toHaveBeenCalledWith("user-1", "team-2");
    expect(listTeams).toHaveBeenCalledTimes(1);
    expect(await response.json()).toMatchObject({
      vms: [{ id: "provider-vm-team-2", provider: "e2b", status: "paused" }],
    });
  });

  test("passes the selected Stack team to VM child route workflows", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-team-1" }) };

    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-team-1",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      status: "running",
      createdAt: 1_777_000_000_000,
    });
    await vmIdRoute.GET(
      new Request("https://cmux.test/api/vm/provider-vm-team-1"),
      context,
    );
    expect(getVm).toHaveBeenCalledWith({
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "provider-vm-team-1",
    });

    runVmWorkflow.mockResolvedValue(undefined);
    await DELETE(
      new Request("https://cmux.test/api/vm/provider-vm-team-1", {
        method: "DELETE",
        headers: { origin: "https://cmux.test" },
      }),
      context,
    );
    expect(destroyVm).toHaveBeenCalledWith({
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "provider-vm-team-1",
    });

    runVmWorkflow.mockResolvedValue({
      transport: "websocket",
      url: "wss://example.invalid/pty",
      headers: {},
      token: "token",
      sessionId: "session-1",
      attachmentId: "attach-1",
      expiresAtUnix: 1_777_000_300,
    });
    await attachRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/attach-endpoint", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: "{}",
      }),
      context,
    );
    expect(openAttachEndpoint).toHaveBeenCalledWith(expect.objectContaining({
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "provider-vm-team-1",
    }));

    runVmWorkflow.mockResolvedValue({
      transport: "ssh",
      host: "vm-ssh.example.invalid",
      port: 22,
      username: "cmux",
      publicKeyFingerprint: null,
      credential: { kind: "password", value: "token" },
    });
    await sshRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/ssh-endpoint", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
      }),
      context,
    );
    expect(openSshEndpoint).toHaveBeenCalledWith({
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "provider-vm-team-1",
    });

    runVmWorkflow.mockResolvedValue({ exitCode: 0, stdout: "", stderr: "" });
    await execRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/exec", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ command: "true" }),
      }),
      context,
    );
    expect(execVm).toHaveBeenCalledWith({
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "provider-vm-team-1",
      command: "true",
      timeoutMs: 30_000,
    });
  });

  test("blocks authenticated cookie mutations from cross-site origins before workflow", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("finalizes route observers with wrapper-mapped workflow statuses", async () => {
    getUser.mockResolvedValue(authedStackUser());
    let finalizedStatus: number | null = null;
    const originalError = console.error;
    console.error = mock(() => {}) as unknown as typeof console.error;
    try {
      const response = await withAuthedVmApiRoute(
        new Request("https://cmux.test/api/vm", {
          method: "POST",
          headers: { origin: "https://cmux.test" },
          body: "{}",
        }),
        "/api/vm",
        { "cmux.vm.operation": "create" },
        "/api/vm POST failed",
        async ({ setResponseFinalizer }) => {
          setResponseFinalizer((mappedResponse) => {
            finalizedStatus = mappedResponse.status;
          });
          throw new VmProviderOperationError({
            provider: "freestyle",
            operation: "create",
            cause: new Error("provider unavailable"),
          });
        },
      );

      expect(response.status).toBe(502);
      expect(finalizedStatus).toBe(502);
    } finally {
      console.error = originalError;
    }
  });

  test("does not block VM create past the billing reconcile deadline or leak late rejections", async () => {
    const originalSetTimeout = globalThis.setTimeout;
    const originalClearTimeout = globalThis.clearTimeout;
    const originalConsoleError = console.error;
    const unhandledRejections: unknown[] = [];
    const onUnhandledRejection = (reason: unknown) => {
      unhandledRejections.push(reason);
    };
    let scheduledDelay: number | undefined;
    let rejectReconcile: ((reason?: unknown) => void) | undefined;

    process.on("unhandledRejection", onUnhandledRejection);
    console.error = mock(() => {}) as unknown as typeof console.error;
    globalThis.setTimeout = ((handler: TimerHandler, timeout?: number) => {
      scheduledDelay = timeout;
      queueMicrotask(() => {
        if (typeof handler === "function") handler();
      });
      return 0 as unknown as ReturnType<typeof setTimeout>;
    }) as unknown as typeof setTimeout;
    globalThis.clearTimeout = mock(() => undefined) as unknown as typeof clearTimeout;

    try {
      const reconcile = new Promise<boolean>((_resolve, reject) => {
        rejectReconcile = reject;
      });

      await expect(withBillingReconcileDeadline(reconcile)).resolves.toBe(false);
      expect(scheduledDelay).toBe(5_000);

      rejectReconcile?.(new Error("late reconcile failure"));
      await new Promise((resolve) => originalSetTimeout(resolve, 0));

      expect(unhandledRejections).toEqual([]);
      const consoleErrorCalls = (console.error as unknown as {
        mock: { calls: unknown[][] };
      }).mock.calls;
      expect(consoleErrorCalls[0]?.[0]).toBe("[VM] Pro plan reconcile failed");
      expect(consoleErrorCalls[0]?.[1]).toBeInstanceOf(Error);
    } finally {
      process.off("unhandledRejection", onUnhandledRejection);
      globalThis.setTimeout = originalSetTimeout;
      globalThis.clearTimeout = originalClearTimeout;
      console.error = originalConsoleError;
    }
  });

  test("maps attach provider internal errors to concise retryable VM state", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const originalError = console.error;
    console.error = mock(() => {}) as unknown as typeof console.error;
    try {
      const providerCause = new Error("INTERNAL_ERROR: Internal server error");
      const response = await withAuthedVmApiRoute(
        new Request("https://cmux.test/api/vm/provider-vm-1/attach-endpoint", {
          method: "POST",
          headers: { origin: "https://cmux.test" },
          body: "{}",
        }),
        "/api/vm/[id]/attach-endpoint",
        { "cmux.vm.operation": "open_attach" },
        "/api/vm/[id]/attach-endpoint failed",
        async () => {
          throw new VmProviderOperationError({
            provider: "freestyle",
            operation: "openAttach",
            cause: providerCause,
          });
        },
      );

      expect(response.status).toBe(502);
      expect(response.headers.get("retry-after")).toBe("2");
      const payload = await response.json();
      expect(payload).toMatchObject({
        error: "vm_cloud_service_unavailable",
        message: "cmux could not attach to the Cloud VM yet.",
        phase: "attach",
        retryable: true,
        retryAfterSeconds: 2,
        ui: {
          title: "Reconnecting Cloud VM",
          message: "cmux could not attach to the Cloud VM yet. Retrying in 2s.",
          phase: "attach",
          severity: "warning",
          retryable: true,
          retryAfterSeconds: 2,
        },
        details: {
          operation: "openAttach",
          providerCode: "provider_internal",
          providerMessage: "internal service error",
          retryable: true,
        },
      });
      expect(JSON.stringify(payload)).not.toContain("INTERNAL_ERROR");
      expect(JSON.stringify(payload)).not.toContain("Freestyle");
    } finally {
      console.error = originalError;
    }
  });

  test("requires an Origin header for cookie-authenticated mutations", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "sec-fetch-site": "same-origin" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("blocks cross-site cookie mutations on VM child routes before workflow", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-1" }) };
    const headers = {
      origin: "https://evil.example",
      "sec-fetch-site": "cross-site",
    };

    const responses = await Promise.all([
      DELETE(new Request("https://cmux.test/api/vm/provider-vm-1", { method: "DELETE", headers }), context),
      attachRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/attach-endpoint", { method: "POST", headers }), context),
      sshRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/ssh-endpoint", { method: "POST", headers }), context),
      execRoute.POST(
        new Request("https://cmux.test/api/vm/provider-vm-1/exec", {
          method: "POST",
          headers,
          body: JSON.stringify({ command: "true" }),
        }),
        context,
      ),
    ]);

    for (const response of responses) {
      expect(response.status).toBe(403);
      expect(await response.json()).toEqual({ error: "forbidden" });
    }
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("returns actionable validation errors from VM exec route", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-1" }) };

    const response = await execRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-1/exec", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ command: "   " }),
      }),
      context,
    );

    expect(response.status).toBe(400);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_invalid_command",
      details: { field: "command" },
    });
    expect(payload.message).toContain("command");
    expect(payload.action).toContain("cmux vm exec");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("does not echo unsupported VM service override values", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "aws" }),
      }),
    );

    expect(response.status).toBe(400);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_invalid_provider",
      details: { field: "provider" },
    });
    expect(JSON.stringify(payload)).not.toContain("aws");
    expect(payload.message).toContain("Cloud VM service");
    expect(payload.action).toContain("default Cloud VM service");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("returns client errors for invalid restore request bodies", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const malformed = await restoreRoute.POST(
      new Request("https://cmux.test/api/vm/restore", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: "{",
      }),
    );

    expect(malformed.status).toBe(400);
    expect(await malformed.json()).toMatchObject({
      error: "vm_json_parse_failed",
    });
    expect(runVmWorkflow).not.toHaveBeenCalled();

    const invalidProvider = await restoreRoute.POST(
      new Request("https://cmux.test/api/vm/restore", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ snapshotId: "snap-1", provider: "aws" }),
      }),
    );

    expect(invalidProvider.status).toBe(400);
    expect(await invalidProvider.json()).toMatchObject({
      error: "vm_invalid_provider",
      details: { field: "provider" },
    });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("allows native bearer mutations without browser CSRF headers", async () => {
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-native",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("native-only auth does not fall back to browser cookies", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const nativeOnlyUser = await verifyRequest(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: { cookie: "stack-auth-cookie=present" },
        body: "{}",
      }),
      { allowCookie: false },
    );

    expect(nativeOnlyUser).toBeNull();
    expect(getUser).not.toHaveBeenCalled();

    const cookieUser = await verifyRequest(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: { cookie: "stack-auth-cookie=present" },
        body: "{}",
      }),
    );

    expect(cookieUser?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("blocks VM create kill switch before workflow", async () => {
    process.env.CMUX_VM_CREATE_ENABLED = "0";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(503);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_create_disabled",
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.message).toContain("disabled");
    expect(payload.action).toContain("enable Cloud VM creation");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("blocks provider kill switch before workflow", async () => {
    process.env.CMUX_VM_E2B_ENABLED = "false";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "e2b", image: "cmuxd-ws:proxy-20260424a" }),
      }),
    );

    expect(response.status).toBe(503);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_create_disabled",
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.action).toContain("enable Cloud VM creation");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("requires manifest images in deployed environments before workflow", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "unknown-snapshot" }),
      }),
    );

    expect(response.status).toBe(503);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_image_config_error",
      details: {
        imageRequested: true,
      },
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.action).toContain("supported image");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("omits image from image config errors when no image was resolved", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    const payload = await response.json();
    expect(response.status).toBe(503);
    expect(payload).toMatchObject({
      error: "vm_image_config_error",
      details: {
        imageRequested: false,
      },
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.action).toContain("default Cloud VM image");
    expect(payload).not.toHaveProperty("image");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("records manifest image version on create workflow input", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    process.env.FREESTYLE_SANDBOX_SNAPSHOT = "sh-6ch5p9k23xrcx24056n8";
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-manifest",
      provider: "freestyle",
      image: "sh-6ch5p9k23xrcx24056n8",
      imageVersion: "freestyle-rpclease-20260502a",
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      image: "sh-6ch5p9k23xrcx24056n8",
      imageVersion: "freestyle-rpclease-20260502a",
    }));
  });
});

function restoreVmEnv(): void {
  for (const key of VM_ENV_KEYS) {
    const value = originalEnv[key];
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
}

function authedStackUser() {
  return {
    id: "user-1",
    displayName: null,
    primaryEmail: "user@example.com",
    selectedTeam: {
      id: "team-1",
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
    },
    listTeams: async () => [{
      id: "team-1",
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
    }],
  };
}

function freePlanStackUser() {
  return {
    id: "user-1",
    displayName: null,
    primaryEmail: "user@example.com",
    selectedTeam: {
      id: "team-1",
      clientReadOnlyMetadata: { cmuxVmPlan: "free" },
    },
    listTeams: async () => [{
      id: "team-1",
      clientReadOnlyMetadata: { cmuxVmPlan: "free" },
    }],
  };
}

function expectNoCloudVmImplementationLeaks(payload: unknown): void {
  expect(JSON.stringify(payload)).not.toMatch(
    /Stack Auth|Freestyle|E2B|freestyle|e2b|CMUX_VM_|FREESTYLE_|E2B_|billingTeamId|itemId|billingCustomerId|manifest|snapshot|database|migration|\bsh-[a-z0-9]{8,24}\b|\bteam-[a-z0-9-]+\b/,
  );
}
