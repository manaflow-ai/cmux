import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

const getUser = mock(async () => null);
const runDevboxWorkflow = mock(async () => {
  throw new Error("unauthenticated devbox routes must not reach the devbox workflow");
});
const ensureDevbox = mock(() => ({ workflow: "devbox.ensure" }));
const getDevbox = mock(() => ({ workflow: "devbox.get" }));
const pauseDevbox = mock(() => ({ workflow: "devbox.pause" }));
const resumeDevbox = mock(() => ({ workflow: "devbox.resume" }));
const releaseDevbox = mock(() => ({ workflow: "devbox.release" }));
const openDevboxAttach = mock(() => ({ workflow: "devbox.attach" }));

const DEVBOX_ENV_KEYS = [
  "CMUX_DEVBOX_ENABLED",
  "CMUX_VM_CREATE_ENABLED",
  "CMUX_VM_DAYTONA_ENABLED",
  "CMUX_VM_ALLOW_UNMANIFESTED_IMAGES",
  "DAYTONA_SANDBOX_SNAPSHOT",
  "CMUX_VM_REQUIRE_PRO",
  "VERCEL",
  "VERCEL_ENV",
] as const;
const originalEnv = Object.fromEntries(
  DEVBOX_ENV_KEYS.map((key) => [key, process.env[key]]),
) as Record<(typeof DEVBOX_ENV_KEYS)[number], string | undefined>;

// Capture the real implementations BY VALUE before mocking (see
// vm-route-auth.test.ts for why namespace captures or delegating wrappers
// would self-recurse under bun's in-place mock.module semantics).
const devboxModule = await import("../services/vms/devbox");
const realEnsureDevbox = devboxModule.ensureDevbox;
const realGetDevbox = devboxModule.getDevbox;
const realPauseDevbox = devboxModule.pauseDevbox;
const realResumeDevbox = devboxModule.resumeDevbox;
const realReleaseDevbox = devboxModule.releaseDevbox;
const realOpenDevboxAttach = devboxModule.openDevboxAttach;
const realRunDevboxWorkflow = devboxModule.runDevboxWorkflow;
const realIsDevboxNotFoundError = devboxModule.isDevboxNotFoundError;
const realDevboxVolumeName = devboxModule.devboxVolumeName;
const realDevboxRepository = devboxModule.DevboxRepository;
const realDevboxRepositoryLive = devboxModule.DevboxRepositoryLive;
const realDevboxWorkflowLive = devboxModule.DevboxWorkflowLive;
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let useWorkflowStubs = false;
let useStubDb = false;

function callMock(fn: unknown, args: unknown[]) {
  return (fn as (...args: unknown[]) => unknown)(...args);
}

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../services/vms/devbox", () => ({
  DEVBOX_PERSIST_MOUNT_PATH: devboxModule.DEVBOX_PERSIST_MOUNT_PATH,
  DEVBOX_PROVIDER: devboxModule.DEVBOX_PROVIDER,
  DevboxRepository: realDevboxRepository,
  DevboxRepositoryLive: realDevboxRepositoryLive,
  DevboxWorkflowLive: realDevboxWorkflowLive,
  devboxVolumeName: realDevboxVolumeName,
  isDevboxNotFoundError: realIsDevboxNotFoundError,
  ensureDevbox: ((...args: Parameters<typeof realEnsureDevbox>) =>
    useWorkflowStubs ? callMock(ensureDevbox, args) : realEnsureDevbox(...args)) as typeof realEnsureDevbox,
  getDevbox: ((...args: Parameters<typeof realGetDevbox>) =>
    useWorkflowStubs ? callMock(getDevbox, args) : realGetDevbox(...args)) as typeof realGetDevbox,
  pauseDevbox: ((...args: Parameters<typeof realPauseDevbox>) =>
    useWorkflowStubs ? callMock(pauseDevbox, args) : realPauseDevbox(...args)) as typeof realPauseDevbox,
  resumeDevbox: ((...args: Parameters<typeof realResumeDevbox>) =>
    useWorkflowStubs ? callMock(resumeDevbox, args) : realResumeDevbox(...args)) as typeof realResumeDevbox,
  releaseDevbox: ((...args: Parameters<typeof realReleaseDevbox>) =>
    useWorkflowStubs ? callMock(releaseDevbox, args) : realReleaseDevbox(...args)) as typeof realReleaseDevbox,
  openDevboxAttach: ((...args: Parameters<typeof realOpenDevboxAttach>) =>
    useWorkflowStubs ? callMock(openDevboxAttach, args) : realOpenDevboxAttach(...args)) as typeof realOpenDevboxAttach,
  runDevboxWorkflow: ((...args: Parameters<typeof realRunDevboxWorkflow>) =>
    useWorkflowStubs ? callMock(runDevboxWorkflow, args) : realRunDevboxWorkflow(...args)) as typeof realRunDevboxWorkflow,
}));

// Same self-shield as vm-route-auth.test.ts: keep the auth path's tombstone
// lookup and the Pro reconcile away from a real Postgres pool.
mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => {
    if (!useStubDb) return realCloudDb();
    throw new Error("DATABASE_URL is required for Cloud VM database access");
  },
}));

const devboxRoute = await import("../app/api/devbox/route");
const pauseRoute = await import("../app/api/devbox/pause/route");
const resumeRoute = await import("../app/api/devbox/resume/route");
const attachRoute = await import("../app/api/devbox/attach-endpoint/route");

beforeAll(() => {
  useWorkflowStubs = true;
  useStubDb = true;
});

afterAll(() => {
  useWorkflowStubs = false;
  useStubDb = false;
});

beforeEach(() => {
  restoreDevboxEnv();
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  runDevboxWorkflow.mockClear();
  ensureDevbox.mockClear();
  getDevbox.mockClear();
  pauseDevbox.mockClear();
  resumeDevbox.mockClear();
  releaseDevbox.mockClear();
  openDevboxAttach.mockClear();
});

afterEach(() => {
  restoreDevboxEnv();
});

describe("devbox REST auth", () => {
  const unauthenticatedCalls: Array<[string, () => Promise<Response>]> = [
    ["GET /api/devbox", () => devboxRoute.GET(new Request("https://cmux.test/api/devbox"))],
    ["POST /api/devbox", () => devboxRoute.POST(new Request("https://cmux.test/api/devbox", { method: "POST" }))],
    ["DELETE /api/devbox", () => devboxRoute.DELETE(new Request("https://cmux.test/api/devbox", { method: "DELETE" }))],
    ["POST /api/devbox/pause", () => pauseRoute.POST(new Request("https://cmux.test/api/devbox/pause", { method: "POST" }))],
    ["POST /api/devbox/resume", () => resumeRoute.POST(new Request("https://cmux.test/api/devbox/resume", { method: "POST" }))],
    ["POST /api/devbox/attach-endpoint", () => attachRoute.POST(new Request("https://cmux.test/api/devbox/attach-endpoint", { method: "POST" }))],
  ];

  for (const [name, call] of unauthenticatedCalls) {
    test(`rejects unauthenticated ${name} before reaching the workflow`, async () => {
      const response = await call();
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
      expect(runDevboxWorkflow).not.toHaveBeenCalled();
    });
  }

  test("rejects cross-site cookie mutations before reaching the workflow", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const response = await devboxRoute.POST(
      new Request("https://cmux.test/api/devbox", {
        method: "POST",
        headers: {
          cookie: "stack-session=abc",
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
        },
      }),
    );
    expect(response.status).toBe(403);
    expect(runDevboxWorkflow).not.toHaveBeenCalled();
  });

  test("forwards entitlements and image selection into ensureDevbox", async () => {
    process.env.DAYTONA_SANDBOX_SNAPSHOT = "cmuxd-ws-test";
    process.env.CMUX_VM_ALLOW_UNMANIFESTED_IMAGES = "1";
    getUser.mockResolvedValue(authedStackUser());
    runDevboxWorkflow.mockResolvedValue({
      devbox: {
        id: "devbox-1",
        status: "running",
        provider: "daytona",
        providerVmId: "sandbox-1",
        image: "cmuxd-ws-test",
        imageVersion: null,
        volume: { id: "vol-1", name: "cmux-devbox-abc", mountPath: "/home/cmux/persist" },
        createdAt: 1_777_000_000_000,
      },
      created: true,
    });

    const response = await devboxRoute.POST(
      new Request("https://cmux.test/api/devbox", {
        method: "POST",
        headers: { origin: "https://cmux.test", "idempotency-key": "devbox-idem-1" },
      }),
    );

    expect(response.status).toBe(201);
    const payload = await response.json() as { created: boolean; devbox: { id: string } };
    expect(payload.created).toBe(true);
    expect(payload.devbox.id).toBe("devbox-1");
    expect(ensureDevbox).toHaveBeenCalledWith(expect.objectContaining({
      userId: "user-1",
      billingCustomerType: "team",
      billingTeamId: "team-1",
      billingPlanId: "pro",
      maxActiveVms: 10,
      image: "cmuxd-ws-test",
      idempotencyKey: "devbox-idem-1",
    }));
  });

  test("returns 503 when the devbox kill switch is off, before any workflow", async () => {
    process.env.CMUX_DEVBOX_ENABLED = "0";
    process.env.DAYTONA_SANDBOX_SNAPSHOT = "cmuxd-ws-test";
    process.env.CMUX_VM_ALLOW_UNMANIFESTED_IMAGES = "1";
    getUser.mockResolvedValue(authedStackUser());

    const response = await devboxRoute.POST(
      new Request("https://cmux.test/api/devbox", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
      }),
    );

    expect(response.status).toBe(503);
    expect((await response.json() as { error: string }).error).toBe("devbox_create_disabled");
    expect(runDevboxWorkflow).not.toHaveBeenCalled();
  });

  test("maps a missing devbox to devbox_not_found on pause", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const { VmNotFoundError } = await import("../services/vms/errors");
    (runDevboxWorkflow as unknown as { mockImplementation(next: () => Promise<never>): void })
      .mockImplementation(async () => {
        throw new VmNotFoundError({ vmId: "devbox" });
      });

    const response = await pauseRoute.POST(
      new Request("https://cmux.test/api/devbox/pause", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
      }),
    );

    expect(response.status).toBe(404);
    expect((await response.json() as { error: string }).error).toBe("devbox_not_found");
  });
});

function restoreDevboxEnv(): void {
  for (const key of DEVBOX_ENV_KEYS) {
    const value = originalEnv[key];
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
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
