import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

// Keep this suite at the route boundary: validation must happen before the
// workflow/provider, while a valid request must carry every requested
// dimension and expose the provider-confirmed stats in the response.
let active = false;
let authedUser: AuthedUser | null = null;
const programs: Array<Record<string, unknown>> = [];
let routeResult: { ok: true; value: Record<string, unknown> } | { ok: false; response: Response } = {
  ok: true,
  value: { state: "awake", diskTotalMb: 65536, cpus: 4, memoryTotalMb: 16384 },
};

const realAuth = await import("../services/vms/auth");
const realVerifyRequest = realAuth.verifyRequest;
const realWorkflows = await import("../services/vms/workflows");
const realResizeVm = realWorkflows.resizeVm;
const realRouteWorkflow = await import("../services/vms/routeWorkflow");
const realRunVmRoute = realRouteWorkflow.runVmRoute;

mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(authedUser) : realVerifyRequest(request, options as never)) as typeof realVerifyRequest,
}));

mock.module("../services/vms/workflows", () => ({
  ...realWorkflows,
  resizeVm: ((input: Parameters<typeof realResizeVm>[0]) => {
    if (!active) return realResizeVm(input);
    programs.push(input as Record<string, unknown>);
    return { sentinel: "resize" } as unknown as ReturnType<typeof realResizeVm>;
  }) as typeof realResizeVm,
}));

mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRunVmRoute(program as never, options as never);
    expect((program as { sentinel?: string }).sentinel).toBe("resize");
    return routeResult;
  }) as typeof realRunVmRoute,
}));

const resizeRoute = await import("../app/api/vm/[id]/resize/route");

const user: AuthedUser = {
  id: "user-resize-route",
  isAnonymous: false,
  displayName: "Resize User",
  primaryEmail: "resize@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-resize-route",
  selectedTeamId: "team-resize-route",
  teams: [{ id: "team-resize-route", displayName: "cmux", billingPlanId: "pro", billingSeats: 3 }],
  teamIds: ["team-resize-route"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 3,
};

function post(body: unknown): Request {
  return new Request("https://cmux.test/api/vm/fs-route/resize", {
    method: "POST",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

const params = { params: Promise.resolve({ id: "fs-route" }) };

describe("POST /api/vm/[id]/resize", () => {
  beforeAll(() => {
    active = true;
  });

  beforeEach(() => {
    authedUser = user;
    programs.length = 0;
    routeResult = {
      ok: true,
      value: { state: "awake", diskTotalMb: 65536, cpus: 4, memoryTotalMb: 16384 },
    };
  });

  afterAll(() => {
    active = false;
  });

  test("rejects an invalid disk step before reaching the workflow", async () => {
    const response = await resizeRoute.POST(post({ storageMb: 66 * 1024 }), params);
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "invalid resize size" });
    expect(programs).toEqual([]);
  });

  test("rejects an empty resource update before reaching the workflow", async () => {
    const response = await resizeRoute.POST(post({}), params);
    expect(response.status).toBe(400);
    expect(programs).toEqual([]);
  });

  test("passes disk, CPU, and memory together and returns confirmed stats", async () => {
    const response = await resizeRoute.POST(post({ storageMb: 64 * 1024, cpu: 4, memoryMb: 16 * 1024 }), params);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      id: "fs-route",
      diskTotalMb: 65536,
      cpus: 4,
      memoryTotalMb: 16384,
      maxDiskMb: 131072,
      maxMemoryMb: 24576,
      maxVcpus: 6,
    });
    expect(programs).toHaveLength(1);
    expect(programs[0]).toMatchObject({
      userId: user.id,
      billingTeamId: user.billingTeamId,
      providerVmId: "fs-route",
      storageMb: 65536,
      cpu: 4,
      memoryMb: 16384,
    });
  });

  test("passes through a workflow/provider failure response", async () => {
    routeResult = {
      ok: false,
      response: new Response(JSON.stringify({ error: "vm_provider_operation_failed" }), {
        status: 502,
        headers: { "content-type": "application/json" },
      }),
    };
    const response = await resizeRoute.POST(post({ storageMb: 64 * 1024 }), params);
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "vm_provider_operation_failed" });
    expect(programs).toHaveLength(1);
  });

  test("returns unauthorized without invoking the workflow", async () => {
    authedUser = null;
    const response = await resizeRoute.POST(post({ storageMb: 64 * 1024 }), params);
    expect(response.status).toBe(401);
    expect(programs).toEqual([]);
  });
});
