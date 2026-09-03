import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import manifestJson from "../services/vms/images/manifest.json";
import { pickVmImageSizeForMemory } from "../services/vms/images/sizes";

// The manifest is the only source of truth for images: the base default at the
// plan's memory is what a create with no image (and no kind) resolves to, in
// every environment. The manifest keeps one snapshot per Freestyle size, and
// the pro plan machine (20 GiB, `memoryMb: 20480` below) boots the smallest
// size with at least that much memory.
const PRO_PLAN_MEMORY_MB = 20480;
const PRO_PLAN_SIZE = pickVmImageSizeForMemory(PRO_PLAN_MEMORY_MB)!.name;
const MANIFEST_BASE_DEFAULT = (manifestJson.images as Array<{
  imageId: string;
  version: string;
  kind?: string;
  defaultForKind?: boolean;
  size?: { name: string };
}>).find((entry) => (entry.kind ?? "base") === "base" && entry.defaultForKind && entry.size?.name === PRO_PLAN_SIZE)!;

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
const openVmCmuxRemote = mock(() => ({ workflow: "cmux-remote" }));
const approveVmCmuxRemoteEnrollment = mock(() => ({ workflow: "cmux-remote-approve" }));
const restoreVm = mock(() => ({ workflow: "restore" }));
const snapshotVm = mock(() => ({ workflow: "snapshot" }));
const revokeUserVmAccess = mock(() => ({ workflow: "revoke-access" }));
const VM_ENV_KEYS = [
  "CMUX_VM_CREATE_ENABLED",
  "CMUX_VM_FREESTYLE_ENABLED",
  "CMUX_VM_ALLOWED_ORIGINS",
  "CMUX_VM_ALLOW_UNMANIFESTED_IMAGES",
  "CMUX_VM_FREE_MAX_ACTIVE_VMS",
  "CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS",
  "CMUX_VM_FREE_MAX_MEMORY_MB",
  "CMUX_VM_PAID_MAX_MEMORY_MB",
  "CMUX_VM_PLAN_PRO_MAX_MEMORY_MB",
  "CMUX_VM_PLAN_PRO_DEFAULT_MEMORY_MB",
  "CMUX_VM_REQUIRE_PRO",
  "CMUX_VM_ALLOW_FREE_PROVISIONING",
  "CMUX_VM_DEFAULT_PLAN",
  "CMUX_VM_DEFAULT_PROVIDER",
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
const realOpenVmCmuxRemote = workflowsModule.openVmCmuxRemote;
const realApproveVmCmuxRemoteEnrollment = workflowsModule.approveVmCmuxRemoteEnrollment;
const realResetBaseVm = workflowsModule.resetBaseVm;
const realRestoreVm = workflowsModule.restoreVm;
const realRunVmWorkflow = workflowsModule.runVmWorkflow;
const realSnapshotVm = workflowsModule.snapshotVm;
const realRevokeUserVmAccess = workflowsModule.revokeUserVmAccess;
const realVmWorkflowLive = workflowsModule.VmWorkflowLive;
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let useWorkflowStubs = false;
let useStubDb = false;
let authTombstoneRows: Array<{ userIdHash: string; status: string; updatedAt: Date | null }> = [];

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
  openVmCmuxRemote: ((...args: Parameters<typeof realOpenVmCmuxRemote>) =>
    useWorkflowStubs ? callMock(openVmCmuxRemote, args) : realOpenVmCmuxRemote(...args)) as typeof realOpenVmCmuxRemote,
  approveVmCmuxRemoteEnrollment: ((...args: Parameters<typeof realApproveVmCmuxRemoteEnrollment>) =>
    useWorkflowStubs ? callMock(approveVmCmuxRemoteEnrollment, args) : realApproveVmCmuxRemoteEnrollment(...args)) as typeof realApproveVmCmuxRemoteEnrollment,
  resetBaseVm: ((...args: Parameters<typeof realResetBaseVm>) =>
    useWorkflowStubs ? callMock(resetBaseVm, args) : realResetBaseVm(...args)) as typeof realResetBaseVm,
  restoreVm: ((...args: Parameters<typeof realRestoreVm>) =>
    useWorkflowStubs ? callMock(restoreVm, args) : realRestoreVm(...args)) as typeof realRestoreVm,
  runVmWorkflow: ((...args: Parameters<typeof realRunVmWorkflow>) =>
    useWorkflowStubs ? callMock(runVmWorkflow, args) : realRunVmWorkflow(...args)) as typeof realRunVmWorkflow,
  snapshotVm: ((...args: Parameters<typeof realSnapshotVm>) =>
    useWorkflowStubs ? callMock(snapshotVm, args) : realSnapshotVm(...args)) as typeof realSnapshotVm,
  revokeUserVmAccess: ((...args: Parameters<typeof realRevokeUserVmAccess>) =>
    useWorkflowStubs ? callMock(revokeUserVmAccess, args) : realRevokeUserVmAccess(...args)) as typeof realRevokeUserVmAccess,
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
    if (authTombstoneRows.length > 0) {
      return {
        select: () => ({
          from: () => ({
            where: () => ({
              limit: async () => authTombstoneRows,
            }),
          }),
        }),
      };
    }
    if (!useStubDb) return realCloudDb();
    throw new Error("DATABASE_URL is required for Cloud VM database access");
  },
}));

const { VmAttachTransportUnsupportedError } = await import("../services/vms/errors");
const { GET, POST, withBillingReconcileDeadline } = await import("../app/api/vm/route");
const baseOpenRoute = await import("../app/api/vm/base/open/route");
const baseResetRoute = await import("../app/api/vm/base/reset/route");
const vmIdRoute = await import("../app/api/vm/[id]/route");
const { DELETE } = vmIdRoute;
const attachRoute = await import("../app/api/vm/[id]/attach-endpoint/route");
const cmuxRemoteApproveRoute = await import("../app/api/vm/[id]/cmux-remote/approve/route");
const execRoute = await import("../app/api/vm/[id]/exec/route");
const forkRoute = await import("../app/api/vm/[id]/fork/route");
const _snapshotRoute = await import("../app/api/vm/[id]/snapshot/route");
const restoreRoute = await import("../app/api/vm/restore/route");
const revokeAccessRoute = await import("../app/api/vm/leases/revoke/route");
const {
  VmAccountDeletionInProgressError,
  VmCreateCreditsInsufficientError,
  VmCreateDisabledError,
  VmCreateFailedError,
  VmModelPlaneError,
  VmProviderOperationError,
} = await import("../services/vms/errors");
const { verifyRequest, clearNativeAuthCacheForTests } = await import("../services/vms/auth");
const { withAuthedVmApiRoute } = await import("../services/vms/routeHelpers");
const { accountDeletionUserHash } = await import("../services/account/deletionLock");

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
  clearNativeAuthCacheForTests();
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  authTombstoneRows = [];
  runVmWorkflow.mockClear();
  (runVmWorkflow as unknown as { mockImplementation(next: () => Promise<never>): void }).mockImplementation(
    async () => {
      throw new Error("unauthenticated VM routes must not reach the VM workflow");
    },
  );
  createVm.mockClear();
  openBaseVm.mockClear();
  resetBaseVm.mockClear();
  destroyVm.mockClear();
  openVmCmuxRemote.mockClear();
  approveVmCmuxRemoteEnrollment.mockClear();
  openAttachEndpoint.mockClear();
  execVm.mockClear();
  forkVm.mockClear();
  getVm.mockClear();
  listUserVms.mockClear();
  openAttachEndpoint.mockClear();
  restoreVm.mockClear();
  snapshotVm.mockClear();
  revokeUserVmAccess.mockClear();
});

afterEach(() => {
  restoreVmEnv();
});

describe("VM REST auth", () => {
  test("rejects unauthenticated Cloud VM lease revocation before the workflow", async () => {
    const response = await revokeAccessRoute.POST(
      new Request("https://cmux.test/api/vm/leases/revoke", { method: "POST" }),
    );

    expect(response.status).toBe(401);
    expect(revokeUserVmAccess).not.toHaveBeenCalled();
  });

  test("revokes only the authenticated account's endpoint leases", async () => {
    (getUser as unknown as { mockResolvedValue(value: unknown): void }).mockResolvedValue({
      id: "user-signout",
      displayName: "Signout User",
      primaryEmail: "signout@example.com",
      selectedTeam: null,
      clientReadOnlyMetadata: {},
      listTeams: async () => [],
    });
    (runVmWorkflow as unknown as { mockImplementation(next: () => Promise<unknown>): void }).mockImplementation(
      async () => ({ revoked: 2, cleanupFailures: 0 }),
    );

    const response = await revokeAccessRoute.POST(
      new Request("https://cmux.test/api/vm/leases/revoke", {
        method: "POST",
        headers: {
          authorization: "Bearer access-signout",
          "x-stack-refresh-token": "refresh-signout",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ ok: true, revoked: 2 });
    expect(revokeUserVmAccess).toHaveBeenCalledWith({ userId: "user-signout" });
  });

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

  test("rejects account-deleting users before reaching workflows", async () => {
    authTombstoneRows = [accountDeletionAuthTombstone("user-1", "pending", new Date())];
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      selectedTeam: null,
      listTeams: async () => [],
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("allows stale account-deleting metadata after tombstone lease expires", async () => {
    authTombstoneRows = [accountDeletionAuthTombstone("user-1", "pending", new Date(0))];
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      selectedTeam: null,
      listTeams: async () => [],
    });

    const user = await verifyRequest(
      new Request("https://cmux.test/api/vm", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
    );

    expect(user?.id).toBe("user-1");
  });

  test("rejects unauthenticated VM mutations before reaching workflows", async () => {
    const context = { params: Promise.resolve({ id: "provider-vm-1" }) };
    const responses = await Promise.all([
      DELETE(new Request("https://cmux.test/api/vm/provider-vm-1", { method: "DELETE" }), context),
      attachRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/attach-endpoint", { method: "POST" }), context),
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
      kind: "base",
      createdAt: 1_777_000_000_000,
    });
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "user-1",
      billingCustomerType: "team",
      billingTeamId: "team-1",
      billingPlanId: "pro",
      maxActiveVms: 50,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      idempotencyKey: "idem-1",
      memoryMb: 20480,
    }));
    expect(listTeams).not.toHaveBeenCalled();
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("rejects an unknown `kind` on create and base open before touching workflows", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const create = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ kind: "gpu" }),
      }),
    );
    expect(create.status).toBe(400);
    expect(await create.json()).toMatchObject({
      error: "vm_invalid_request",
      details: { field: "kind", allowedKinds: ["desktop", "base"] },
    });

    const open = await baseOpenRoute.POST(
      new Request("https://cmux.test/api/vm/base/open", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ kind: 7 }),
      }),
    );
    expect(open.status).toBe(400);
    expect(await open.json()).toMatchObject({
      error: "vm_invalid_request",
      details: { field: "kind" },
    });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("creates by kind without an image and echoes the resolved kind", async () => {
    // The deployed shape: the manifest's defaultForKind entry names the image,
    // and the client only asks for a kind.
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-kind",
      provider: "freestyle",
      image: MANIFEST_BASE_DEFAULT.imageId,
      imageVersion: MANIFEST_BASE_DEFAULT.version,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", kind: "base" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ id: "provider-vm-kind", kind: "base" });
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      provider: "freestyle",
      image: MANIFEST_BASE_DEFAULT.imageId,
      imageVersion: MANIFEST_BASE_DEFAULT.version,
    }));
  });

  test("a plan size the manifest ladder cannot serve fails with an actionable image config error", async () => {
    // Both kinds have a manifest ladder, so the only way nothing resolves is a
    // plan machine above the ladder's largest snapshot (2xl, 64 GiB). The
    // route must 503 with a config error rather than boot a smaller machine.
    process.env.CMUX_VM_PLAN_PRO_MAX_MEMORY_MB = "131072";
    process.env.CMUX_VM_PLAN_PRO_DEFAULT_MEMORY_MB = "131072";
    getUser.mockResolvedValue(authedStackUser());

    const create = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", kind: "desktop" }),
      }),
    );
    expect(create.status).toBe(503);
    const createPayload = await create.json();
    expect(createPayload).toMatchObject({
      error: "vm_image_config_error",
      message: "No desktop Cloud VM image is available in this environment.",
      details: {
        imageRequested: false,
        kind: "desktop",
        source: "default",
        // What the provider serves at its smallest size, so a client can still
        // offer both kinds.
        allowedKinds: ["desktop", "base"],
      },
    });
    expectNoCloudVmImplementationLeaks(createPayload);

    const open = await baseOpenRoute.POST(
      new Request("https://cmux.test/api/vm/base/open", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", kind: "desktop" }),
      }),
    );
    expect(open.status).toBe(503);
    expect(await open.json()).toMatchObject({
      error: "vm_image_config_error",
      details: { imageRequested: false, kind: "desktop", source: "default" },
    });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("lists the kinds the default provider can serve alongside plan limits", async () => {
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue([
      { providerVmId: "devbox", provider: "freestyle", image: "sh-unlisted-shell", imageVersion: "v", status: "running", createdAt: 1_777_000_000_000 },
      { providerVmId: "base", provider: "freestyle", image: "sh-fb3dcf7b47894114889b10186626af5b", imageVersion: null, status: "running", createdAt: 1_777_000_000_000 },
    ]);

    const response = await GET(new Request("https://cmux.test/api/vm"));
    expect(response.status).toBe(200);
    const payload = await response.json() as {
      vms: Array<{ id: string; kind: string }>;
      limits: { imageKinds: Array<{ kind: string; image: string }> };
    };
    // Neither stored image is a manifest desktop image, so both echo kind "base".
    expect(payload.vms).toMatchObject([{ id: "devbox", kind: "base" }, { id: "base", kind: "base" }]);
    const { listVmImageKinds } = await import("../services/vms/images/resolver");
    const { defaultProviderId } = await import("../services/vms/drivers");
    const { defaultMemoryMbForPlan } = await import("../services/vms/entitlements");
    // Kinds are listed at the plan's memory, so the image each names is the
    // snapshot size a create would actually boot.
    expect(payload.limits.imageKinds).toEqual(
      listVmImageKinds(defaultProviderId(), process.env, { memoryMb: defaultMemoryMbForPlan("pro", process.env) }),
    );
    expect(payload.limits.imageKinds.map((entry) => entry.kind)).toEqual(["desktop", "base"]);
    expect(payload.limits.imageKinds.map((entry) => entry.image)).toEqual([
      MANIFEST_BASE_DEFAULT.imageId,
      MANIFEST_BASE_DEFAULT.imageId,
    ]);
    for (const entry of payload.limits.imageKinds) {
      expect(["desktop", "base"]).toContain(entry.kind);
      expect(typeof entry.image).toBe("string");
    }
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

  test("passes an explicit memory size through the create workflow", async () => {
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-memory",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test", memoryMb: 20480 }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({ memoryMb: 20480 }));
  });

  test("resolves a legacy client's oversized memory request to the plan machine", async () => {
    // Nightlies built before the 2026-09-02 pricing change send their old
    // 24 GB default on every create; the server must still hand them the
    // plan machine instead of failing every New Machine until they update.
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "1";
    getUser.mockResolvedValue(freePlanStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-legacy-size",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test", memoryMb: 24576 }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({ memoryMb: 20480 }));
  });

  test("resolves a memory request below the plan machine to the plan machine", async () => {
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "1";
    getUser.mockResolvedValue(freePlanStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-small-size",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test", memoryMb: 8192 }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({ memoryMb: 20480 }));
  });

  test("rejects malformed memory sizes before billing or provider work", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test", memoryMb: "8g" }),
      }),
    );

    expect(response.status).toBe(400);
    const payload = await response.json();
    expect(payload).toMatchObject({ error: "vm_invalid_request", details: { field: "memoryMb" } });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("blocks a free plan by default even when its legacy active limit is permissive", async () => {
    process.env.CMUX_VM_FREE_MAX_ACTIVE_VMS = "5";
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

  test("the paid-plan gate answers in the client's locale", async () => {
    getUser.mockResolvedValue(freePlanStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test", "x-next-intl-locale": "ja" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(402);
    const payload = await response.json() as {
      error: string; message: string; action: string; upgradeUrl: string; ui: { title: string };
    };
    expect(payload.error).toBe("vm_requires_pro");
    expect(payload.message).toBe("Cloud VM を利用するには cmux Pro プランが必要です。");
    expect(payload.ui.title).toBe("cmux Pro が必要です");
    expect(payload.action).toContain("https://cmux.com/pricing");
    expect(payload.upgradeUrl).toBe("https://cmux.com/pricing");
    expect(createVm).not.toHaveBeenCalled();
  });

  test("an explicit free-provisioning switch reopens the configured demo allowance", async () => {
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "1";
    process.env.CMUX_VM_FREE_MAX_ACTIVE_VMS = "5";
    getUser.mockResolvedValue(freePlanStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-free-demo",
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
      billingPlanId: "free",
      maxActiveVms: 5,
    }));
  });

  test("a paid deployment default cannot grant a paid plan to an account without metadata", async () => {
    process.env.CMUX_VM_DEFAULT_PLAN = "pro";
    getUser.mockResolvedValue(stackUserForPlan(undefined));

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

  test("blocks a team-less free account from provisioning when CMUX_VM_REQUIRE_PRO is enforced", async () => {
    // The user-scoped billing fallback (#11225) must never widen access: an
    // account with zero Stack teams and no subscription resolves to the free
    // plan and hits the same Pro gate as team-based free users.
    process.env.CMUX_VM_REQUIRE_PRO = "1";
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

    expect(response.status).toBe(402);
    expect((await response.json() as { error: string }).error).toBe("vm_requires_pro");
    expect(createVm).not.toHaveBeenCalled();
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("a team-less free account gets exactly the free-plan allowance", async () => {
    // With free provisioning explicitly allowed (the gate is on by default),
    // the freemium policy still applies unchanged: user-scoped billing carries
    // the free plan's machine ceiling into the create workflow, where the
    // active-VM limit is enforced.
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "1";
    process.env.CMUX_VM_FREE_MAX_ACTIVE_VMS = "1";
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: null,
      listTeams: async () => [],
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-free-user-billing",
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
      userId: "user-1",
      billingCustomerType: "user",
      billingTeamId: "user-1",
      billingPlanId: "free",
      maxActiveVms: 1,
    }));
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

  test("every provisioning route applies the paid-plan gate before workflow/provider work", async () => {
    const provisioningRoutes = [
      {
        name: "create",
        constructor: createVm,
        invoke: () => POST(
          new Request("https://cmux.test/api/vm", {
            method: "POST",
            headers: { origin: "https://cmux.test" },
            // Deliberately use an unknown image and disable provider creates:
            // a free caller must still receive the entitlement response first.
            body: JSON.stringify({ provider: "freestyle", image: "not-a-real-image" }),
          }),
        ),
      },
      {
        name: "base-open",
        constructor: openBaseVm,
        invoke: () => baseOpenRoute.POST(
          new Request("https://cmux.test/api/vm/base/open", {
            method: "POST",
            headers: { origin: "https://cmux.test" },
            body: JSON.stringify({ provider: "freestyle", image: "not-a-real-image" }),
          }),
        ),
      },
      {
        name: "base-reset",
        constructor: resetBaseVm,
        invoke: () => baseResetRoute.POST(
          new Request("https://cmux.test/api/vm/base/reset", {
            method: "POST",
            headers: { origin: "https://cmux.test" },
            body: JSON.stringify({ provider: "freestyle", image: "not-a-real-image" }),
          }),
        ),
      },
      {
        name: "fork",
        constructor: forkVm,
        invoke: () => forkRoute.POST(
          new Request("https://cmux.test/api/vm/provider-vm-1/fork", {
            method: "POST",
            headers: { origin: "https://cmux.test" },
            body: "{}",
          }),
          { params: Promise.resolve({ id: "provider-vm-1" }) },
        ),
      },
      {
        name: "restore",
        constructor: restoreVm,
        invoke: () => restoreRoute.POST(
          new Request("https://cmux.test/api/vm/restore", {
            method: "POST",
            headers: { origin: "https://cmux.test" },
            body: JSON.stringify({ snapshotId: "snapshot-1", provider: "freestyle" }),
          }),
        ),
      },
    ] as const;

    const provisioningConstructors = [createVm, openBaseVm, resetBaseVm, forkVm, restoreVm];
    const workflowResult = (name: (typeof provisioningRoutes)[number]["name"]): unknown => {
      if (name === "fork") {
        return {
          snapshot: null,
          fork: {
            providerVmId: "provider-vm-forked",
            provider: "freestyle",
            image: "snapshot-test",
            imageVersion: null,
            status: "running",
            createdAt: 1_777_000_000_000,
          },
        };
      }
      if (name === "base-open" || name === "base-reset") {
        return {
          providerVmId: `provider-vm-${name}`,
          provider: "freestyle",
          image: "snapshot-test",
          imageVersion: null,
          status: "running",
          createdAt: 1_777_000_000_000,
          baseId: "base-1",
          baseName: "Base",
          generation: 1,
          retainedProviderVmId: null,
        };
      }
      return {
        providerVmId: `provider-vm-${name}`,
        provider: "freestyle",
        image: "snapshot-test",
        imageVersion: null,
        status: "running",
        createdAt: 1_777_000_000_000,
      };
    };

    // Free and no-plan accounts are denied on every allocation surface. The
    // provider kill switch is also off here to prove entitlement wins before
    // provider/configuration checks.
    for (const plan of ["free", undefined]) {
      process.env.CMUX_VM_CREATE_ENABLED = "0";
      process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "0";
      delete process.env.CMUX_VM_REQUIRE_PRO;
      delete process.env.CMUX_VM_DEFAULT_PLAN;
      process.env.CMUX_VM_FREE_MAX_ACTIVE_VMS = "5";
      getUser.mockResolvedValue(stackUserForPlan(plan));
      for (const route of provisioningRoutes) {
        for (const constructor of provisioningConstructors) constructor.mockClear();
        runVmWorkflow.mockClear();
        const response = await route.invoke();
        expect(response.status).toBe(402);
        const payload = await response.json() as {
          error?: string;
          upgradeRequired?: boolean;
          upgradeUrl?: string;
        };
        expect(payload.error).toBe("vm_requires_pro");
        expect(payload.upgradeRequired).toBe(true);
        expect(payload.upgradeUrl).toBe("https://cmux.com/pricing");
        for (const constructor of provisioningConstructors) {
          expect(constructor).not.toHaveBeenCalled();
        }
        expect(runVmWorkflow).not.toHaveBeenCalled();
      }
    }

    // All paid plan ids recognized by the server gate continue through their
    // corresponding workflow, including Founder's Edition operator grants.
    process.env.CMUX_VM_CREATE_ENABLED = "1";
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "0";
    process.env.CMUX_VM_ALLOW_UNMANIFESTED_IMAGES = "1";
    process.env.CMUX_VM_FREESTYLE_ENABLED = "1";
    delete process.env.CMUX_VM_REQUIRE_PRO;
    for (const plan of ["pro", "team", "founders"] as const) {
      getUser.mockResolvedValue(stackUserForPlan(plan));
      for (const route of provisioningRoutes) {
        for (const constructor of provisioningConstructors) constructor.mockClear();
        runVmWorkflow.mockClear();
        runVmWorkflow.mockResolvedValue(workflowResult(route.name));
        const response = await route.invoke();
        expect(response.status).toBe(200);
        expect(runVmWorkflow).toHaveBeenCalledTimes(1);
        expect(route.constructor).toHaveBeenCalledTimes(1);
      }
    }
  });

  test("still lists VMs for a free plan under Pro enforcement (management is not gated)", async () => {
    process.env.CMUX_VM_REQUIRE_PRO = "1";
    getUser.mockResolvedValue(freePlanStackUser());
    runVmWorkflow.mockResolvedValue([]);

    const response = await GET(new Request("https://cmux.test/api/vm"));
    expect(response.status).toBe(200);
    expect(createVm).not.toHaveBeenCalled();
  });

  test("lists free-plan machines with a server-authoritative free access expiry", async () => {
    getUser.mockResolvedValue(freePlanStackUser());
    runVmWorkflow.mockResolvedValue([
      { providerVmId: "older", provider: "freestyle", image: "sh-fb3dcf7b47894114889b10186626af5b", imageVersion: "v", status: "running", createdAt: 1_777_000_000_000 },
      { providerVmId: "newer", provider: "freestyle", image: "sh-fb3dcf7b47894114889b10186626af5b", imageVersion: "v", status: "running", createdAt: 1_777_100_000_000 },
    ]);

    const response = await GET(new Request("https://cmux.test/api/vm"));
    expect(response.status).toBe(200);
    const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
    expect(await response.json()).toMatchObject({
      vms: [
        { id: "older", freeAccessExpiresAt: 1_777_000_000_000 + sevenDaysMs },
        { id: "newer", freeAccessExpiresAt: 1_777_100_000_000 + sevenDaysMs },
      ],
      limits: {
        maxActiveVms: 0,
        planId: "free",
        freeAccessWindowDays: 7,
        freeAccessExpiresAt: 1_777_000_000_000 + sevenDaysMs,
      },
    });
  });

  test("paid plans list machines without a free access expiry", async () => {
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue([
      { providerVmId: "pro-vm", provider: "freestyle", image: "sh-fb3dcf7b47894114889b10186626af5b", imageVersion: "v", status: "running", createdAt: 1_777_000_000_000 },
    ]);

    const response = await GET(new Request("https://cmux.test/api/vm"));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      vms: [{ id: "pro-vm", freeAccessExpiresAt: null }],
      limits: { planId: "pro", freeAccessWindowDays: 0, freeAccessExpiresAt: null },
    });
  });

  test("every listed machine carries its provider's capabilities (no driver forks)", async () => {
    // The app hides Checkpoint/Fork when these are false instead of offering verbs
    // that can only answer 502 "not implemented". Freestyle snapshots and
    // restores; no driver implements fork.
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue([
      { providerVmId: "desk", provider: "freestyle", image: "sh-fb3dcf7b47894114889b10186626af5b", imageVersion: "v", status: "running", createdAt: 1_777_000_000_000 },
    ]);
    const response = await GET(new Request("https://cmux.test/api/vm"));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      vms: [{ id: "desk", capabilities: { snapshot: true, restore: true, fork: false } }],
    });
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
      message: "This team has no Cloud VM create credits left.",
    });
  });

  test("maps a coderouter outage during create to a retryable 503 without leaking the cause", async () => {
    getUser.mockResolvedValue(authedStackUser());
    rejectRunVmWorkflowWith(
      new VmModelPlaneError({ kind: "unavailable", cause: new Error("Freestyle database connection refused") }),
    );

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "idempotency-key": "idem-model-plane", origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_model_plane_unavailable",
      phase: "create",
      retryable: true,
      ui: { severity: "warning", retryable: true },
    });
    expect(payload.action).toContain("retry");
    expectNoCloudVmImplementationLeaks(payload);
  });

  test("credit exhaustion on user-scoped billing names the account, not a team", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      selectedTeam: null,
      listTeams: async () => [],
    });
    rejectRunVmWorkflowWith(
      new VmCreateCreditsInsufficientError({
        itemId: "cmux-vm-create-credit",
        billingCustomerId: "user-1",
        amount: 1,
      }),
    );

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "idempotency-key": "idem-credits-user", origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(402);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_create_credits_insufficient",
      amount: 1,
      message: "Your account has no Cloud VM create credits left.",
    });
    expect(payload.message).not.toContain("team");
    expect(payload.action).not.toContain("team");
  });

  test("uses the native client's requested Stack team for billing", async () => {
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "1";
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
      maxActiveVms: 0,
    }));
    expect(listTeams).toHaveBeenCalledTimes(1);
  });

  test("validates a JSON body team id only when it differs from the selected team", async () => {
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "1";
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
      maxActiveVms: 0,
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
    process.env.CMUX_VM_ALLOW_FREE_PROVISIONING = "1";
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

  test("creates a VM with user-scoped billing when Stack Auth returns no teams", async () => {
    // Legacy accounts predate personal-team auto-create: Stack returns no
    // team at all. Billing supports user-scoped customers everywhere else
    // (list, entitlements, credits), so create must fall back to the user
    // instead of dead-ending on a 409 the caller cannot fix.
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      selectedTeam: null,
      listTeams: async () => [],
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-user-billing",
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
      userId: "user-1",
      billingCustomerType: "user",
      billingTeamId: "user-1",
      billingPlanId: "pro",
    }));
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("uses the paid Stack team when multiple teams have no selected/requested team", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "free" },
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } },
        { id: "team-2", clientReadOnlyMetadata: { cmuxPlan: "team", cmuxSeats: 4 } },
      ],
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-team-paid",
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
      userId: "user-1",
      billingCustomerType: "team",
      billingTeamId: "team-2",
      billingPlanId: "team",
      maxActiveVms: 200,
    }));
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("rejects VM create when multiple Stack teams have no paid metadata and no selected/requested team", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "free" },
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } },
        { id: "team-2", clientReadOnlyMetadata: { cmuxPlan: "" } },
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
    // The 409 must present as a team-selection problem, not the generic
    // "operation already running" that defaultVmDisplayTitle maps 409 to.
    const ui = payload.ui as { title?: string } | undefined;
    expect(ui?.title).toBe("Cloud VM team required");
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
      provider: "freestyle",
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
      vms: [{ id: "provider-vm-team-2", provider: "freestyle", status: "paused" }],
    });
  });

  test("attach-endpoint routes transport=cmux-remote to the cmux-tui workflow with the caller's device", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-team-1" }) };
    runVmWorkflow.mockResolvedValue({
      transport: "cmux-remote",
      route: "wss://machine.vm.cmux.sh/v1/link?bl_preview_token=t",
      token: "t",
      expiresAtUnix: 1_777_000_300,
      session: "cloud",
      invitation: { uri: "cmux://enroll/abc", invitationId: "inv-1", expiresAtUnix: 1_777_000_200 },
    });
    const response = await attachRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/attach-endpoint", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ transport: "cmux-remote", deviceFingerprint: "fp-device-1", clientCapabilities: ["direct-ws-user-agent", "Bad Token!", 42] }),
      }),
      context,
    );
    expect(response.status).toBe(200);
    expect(openVmCmuxRemote).toHaveBeenCalledWith({
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "provider-vm-team-1",
      deviceFingerprint: "fp-device-1",
      clientCapabilities: ["direct-ws-user-agent"],
      callerPlanId: "pro",
    });
    expect(openAttachEndpoint).not.toHaveBeenCalled();
    const payload = await response.json();
    expect(payload.transport).toBe("cmux-remote");
    expect(payload.invitation.invitationId).toBe("inv-1");
  });

  test("attach-endpoint answers 409 vm_attach_transport_unsupported when the machine only runs cmux-tui", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-team-1" }) };
    (runVmWorkflow as unknown as { mockImplementation(next: () => Promise<never>): void }).mockImplementation(
      async () => {
        throw new VmAttachTransportUnsupportedError({
          provider: "freestyle",
          vmId: "provider-vm-team-1",
          requested: "websocket",
          supported: ["cmux-remote"],
        });
      },
    );
    const response = await attachRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/attach-endpoint", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ requireDaemon: true }),
      }),
      context,
    );
    expect(response.status).toBe(409);
    const payload = await response.json();
    expect(payload.error).toBe("vm_attach_transport_unsupported");
    expect(payload.retryable).toBe(false);
    expect(payload.details).toMatchObject({
      provider: "freestyle",
      requestedTransport: "websocket",
      supportedTransports: ["cmux-remote"],
      phase: "attach",
    });
    expect(payload.action).toContain('transport "cmux-remote"');
    expect(openAttachEndpoint).toHaveBeenCalledTimes(1);
    expect(openVmCmuxRemote).not.toHaveBeenCalled();
  });

  test("attach-endpoint rejects an unknown transport before any workflow runs", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-team-1" }) };
    const response = await attachRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/attach-endpoint", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ transport: "carrier-pigeon" }),
      }),
      context,
    );
    expect(response.status).toBe(400);
    expect(openVmCmuxRemote).not.toHaveBeenCalled();
    expect(openAttachEndpoint).not.toHaveBeenCalled();
  });

  test("cmux-remote/approve validates the invitation id and passes the account scope through", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-team-1" }) };
    const bad = await cmuxRemoteApproveRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/cmux-remote/approve", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ invitationId: "not valid; rm -rf /" }),
      }),
      context,
    );
    expect(bad.status).toBe(400);
    expect(approveVmCmuxRemoteEnrollment).not.toHaveBeenCalled();

    runVmWorkflow.mockResolvedValue({ approved: true, state: "approved", deviceFingerprint: "fp-device-1" });
    const ok = await cmuxRemoteApproveRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-team-1/cmux-remote/approve", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ invitationId: "inv_abc-123" }),
      }),
      context,
    );
    expect(ok.status).toBe(200);
    expect(approveVmCmuxRemoteEnrollment).toHaveBeenCalledWith({
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "provider-vm-team-1",
      invitationId: "inv_abc-123",
      callerPlanId: "pro",
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
      modelPlane: expect.objectContaining({}),
    });
    // Token revocation runs inside the workflow: the route only supplies the revoker.
    const destroyCalls = (destroyVm as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    const destroyInput = destroyCalls.at(-1)?.[0] as { modelPlane?: { revoke?: unknown } } | undefined;
    expect(typeof destroyInput?.modelPlane?.revoke).toBe("function");

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
      callerPlanId: "pro",
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

  test("maps a provider image-not-found on create to a non-retryable vm_image_unavailable", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const originalError = console.error;
    console.error = mock(() => {}) as unknown as typeof console.error;
    try {
      const providerCause = new Error(
        "POST https://api.freestyle.sh/v5/vms -> 404: {\"code\":\"NOT_FOUND\",\"message\":\"Snapshot 'sh-fb3dcf7b47894114889b10186626af5b' not found.\"}",
      );
      const response = await withAuthedVmApiRoute(
        new Request("https://cmux.test/api/vm", {
          method: "POST",
          headers: { origin: "https://cmux.test", "content-type": "application/json" },
          body: JSON.stringify({ kind: "desktop" }),
        }),
        "/api/vm",
        { "cmux.vm.operation": "create" },
        "/api/vm failed",
        async () => {
          throw new VmProviderOperationError({
            provider: "freestyle",
            operation: "create",
            cause: providerCause,
          });
        },
      );

      expect(response.status).toBe(503);
      expect(response.headers.get("retry-after")).toBeNull();
      const payload = await response.json();
      expect(payload).toMatchObject({
        error: "vm_image_unavailable",
        phase: "create",
        retryable: false,
        details: { operation: "create", retryable: false, providerCode: "provider_image_not_found" },
        ui: { title: "Cloud VM image unavailable", retryable: false },
      });
      expectNoCloudVmImplementationLeaks(payload);
      const consoleErrorCalls = (console.error as unknown as { mock: { calls: unknown[][] } }).mock.calls;
      expect(consoleErrorCalls.some((call) => call[0] === "[vm-image-unavailable]")).toBe(true);
    } finally {
      console.error = originalError;
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

  test("invalid native credentials do not fall back to a browser cookie", async () => {
    (
      getUser as unknown as {
        mockImplementation(
          implementation: (input: unknown) => Promise<unknown>,
        ): void;
      }
    ).mockImplementation(async (input) => {
      const tokenStore = (
        input as { tokenStore?: { accessToken?: string } } | undefined
      )?.tokenStore;
      return tokenStore ? null : authedStackUser();
    });

    const user = await verifyRequest(
      new Request("https://cmux.test/api/subrouter/accounts", {
        headers: {
          authorization: "Bearer invalid-access",
          "x-stack-refresh-token": "invalid-refresh",
          cookie: "stack-auth-cookie=present",
        },
      }),
    );

    expect(user).toBeNull();
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

  test("maps workflow VM create kill switch without an internal error", async () => {
    getUser.mockResolvedValue(authedStackUser());
    rejectRunVmWorkflowWith(
      new VmCreateDisabledError({
        provider: "freestyle",
        reason: "Cloud VM creation is disabled.",
      }),
    );

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
      reason: "Cloud VM creation is disabled.",
      phase: "create",
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.action).toContain("enable Cloud VM creation");
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("maps workflow account deletion blocks without environment-disabled guidance", async () => {
    getUser.mockResolvedValue(authedStackUser());
    rejectRunVmWorkflowWith(
      new VmAccountDeletionInProgressError({
        provider: "freestyle",
        phase: "create",
      }),
    );

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
      error: "account_deletion_in_progress",
      phase: "create",
      retryable: true,
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.action).toContain("account deletion");
    expect(payload.action).not.toContain("enable Cloud VM creation");
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("blocks provider kill switch before workflow", async () => {
    process.env.CMUX_VM_FREESTYLE_ENABLED = "false";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "sh-fb3dcf7b47894114889b10186626af5b" }),
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

  test("blocks VM restore kill switch before workflow", async () => {
    process.env.CMUX_VM_CREATE_ENABLED = "0";
    getUser.mockResolvedValue(authedStackUser());

    const response = await restoreRoute.POST(
      new Request("https://cmux.test/api/vm/restore", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ snapshotId: "snap-1", provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(503);
    const payload = await response.json();
    expect(payload).toMatchObject({ error: "vm_create_disabled", phase: "create" });
    expectNoCloudVmImplementationLeaks(payload);
    expect(payload.action).toContain("enable Cloud VM creation");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("blocks provider kill switch on restore before workflow", async () => {
    process.env.CMUX_VM_FREESTYLE_ENABLED = "false";
    getUser.mockResolvedValue(authedStackUser());

    const response = await restoreRoute.POST(
      new Request("https://cmux.test/api/vm/restore", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ snapshotId: "snap-1", provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(503);
    const payload = await response.json();
    expect(payload).toMatchObject({ error: "vm_create_disabled" });
    expectNoCloudVmImplementationLeaks(payload);
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("maps the fork workflow kill switch without an internal error", async () => {
    getUser.mockResolvedValue(authedStackUser());
    rejectRunVmWorkflowWith(
      new VmCreateDisabledError({
        provider: "freestyle",
        reason: "Cloud VM creation is disabled.",
      }),
    );

    const response = await forkRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-1/fork", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({}),
      }),
      { params: Promise.resolve({ id: "provider-vm-1" }) },
    );

    expect(response.status).toBe(503);
    const payload = await response.json();
    expect(payload).toMatchObject({
      error: "vm_create_disabled",
      reason: "Cloud VM creation is disabled.",
      phase: "create",
    });
    expectNoCloudVmImplementationLeaks(payload);
    expect(runVmWorkflow).toHaveBeenCalled();
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
    // A plan machine above the manifest ladder is the shape where nothing
    // resolves; the error must not name an image.
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    process.env.CMUX_VM_PLAN_PRO_MAX_MEMORY_MB = "131072";
    process.env.CMUX_VM_PLAN_PRO_DEFAULT_MEMORY_MB = "131072";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", kind: "desktop" }),
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
    expect(payload.action).toContain("Cloud VM image");
    expect(payload).not.toHaveProperty("image");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("records manifest image version on create workflow input", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-manifest",
      provider: "freestyle",
      image: MANIFEST_BASE_DEFAULT.imageId,
      imageVersion: MANIFEST_BASE_DEFAULT.version,
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
      image: MANIFEST_BASE_DEFAULT.imageId,
      imageVersion: MANIFEST_BASE_DEFAULT.version,
    }));
  });

  test("the shell-only base image the CLI sends for `vm new --base` is manifest-listed", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    process.env.CMUX_VM_DEFAULT_PROVIDER = "freestyle";
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-freestyle-base",
      provider: "freestyle",
      image: MANIFEST_BASE_DEFAULT.imageId,
      imageVersion: MANIFEST_BASE_DEFAULT.version,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ image: "sh-fb3dcf7b47894114889b10186626af5b" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      provider: "freestyle",
      image: "sh-fb3dcf7b47894114889b10186626af5b",
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
  return stackUserForPlan("pro");
}

function freePlanStackUser() {
  return stackUserForPlan("free");
}

function stackUserForPlan(plan: string | undefined) {
  const clientReadOnlyMetadata = plan ? { cmuxVmPlan: plan } : {};
  return {
    id: "user-1",
    displayName: null,
    primaryEmail: "user@example.com",
    selectedTeam: {
      id: "team-1",
      clientReadOnlyMetadata,
    },
    listTeams: async () => [{
      id: "team-1",
      clientReadOnlyMetadata,
    }],
  };
}

function accountDeletionAuthTombstone(userId: string, status: string, updatedAt: Date | null) {
  return {
    userIdHash: accountDeletionUserHash(userId),
    status,
    updatedAt,
  };
}

function expectNoCloudVmImplementationLeaks(payload: unknown): void {
  expect(JSON.stringify(payload)).not.toMatch(
    /Stack Auth|Freestyle|E2B|freestyle|e2b|CMUX_VM_|FREESTYLE_|E2B_|billingTeamId|itemId|billingCustomerId|manifest|snapshot|database|migration|\bsh-[a-z0-9]{8,24}\b|\bteam-[a-z0-9-]+\b/,
  );
}
