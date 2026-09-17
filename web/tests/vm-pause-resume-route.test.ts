import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

// POST /api/vm/[id]/pause and /resume: the route's contract around the
// workflows (auth gate, the program's inputs, the 200 body, and error
// pass-through). The workflows themselves are covered by
// vm-pause-resume-workflow.test.ts. bun's mock.module is process-global, so
// every override delegates to the real implementation unless this suite is
// running (`active`), the pattern vm-route-auth.test.ts uses.

let active = false;
let authedUser: AuthedUser | null = null;
const programs: Array<{ kind: "pause" | "resume"; input: Record<string, unknown> }> = [];
let routeResult:
  | { ok: true; value: { id: string; status: "paused" | "running" } }
  | { ok: false; response: Response } = { ok: true, value: { id: "fs-1", status: "paused" } };

const realAuth = await import("../services/vms/auth");
const realVerifyRequest = realAuth.verifyRequest;
const realWorkflows = await import("../services/vms/workflows");
const realPauseVm = realWorkflows.pauseVm;
const realResumeVm = realWorkflows.resumeVm;
const realRouteWorkflow = await import("../services/vms/routeWorkflow");
const realRunVmRoute = realRouteWorkflow.runVmRoute;

mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(authedUser) : realVerifyRequest(request, options as never)) as typeof realVerifyRequest,
}));

mock.module("../services/vms/workflows", () => ({
  ...realWorkflows,
  pauseVm: ((input: Parameters<typeof realPauseVm>[0]) => {
    if (!active) return realPauseVm(input);
    programs.push({ kind: "pause", input: input as Record<string, unknown> });
    return { sentinel: "pause" } as unknown as ReturnType<typeof realPauseVm>;
  }) as typeof realPauseVm,
  resumeVm: ((input: Parameters<typeof realResumeVm>[0]) => {
    if (!active) return realResumeVm(input);
    programs.push({ kind: "resume", input: input as Record<string, unknown> });
    return { sentinel: "resume" } as unknown as ReturnType<typeof realResumeVm>;
  }) as typeof realResumeVm,
}));

mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRunVmRoute(program as never, options as never);
    expect((program as { sentinel?: string }).sentinel).toMatch(/^(pause|resume)$/);
    return routeResult;
  }) as typeof realRunVmRoute,
}));

const pauseRoute = await import("../app/api/vm/[id]/pause/route");
const resumeRoute = await import("../app/api/vm/[id]/resume/route");

const user: AuthedUser = {
  id: "user-1",
  isAnonymous: false,
  displayName: "Austin",
  primaryEmail: "austin@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-1",
  selectedTeamId: "team-1",
  teams: [{ id: "team-1", displayName: "cmux", billingPlanId: "pro", billingSeats: 3 }],
  teamIds: ["team-1"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 3,
};

function post(path: string): Request {
  return new Request(`https://cmux.test${path}`, {
    method: "POST",
    headers: { authorization: "Bearer access-token", "x-stack-refresh-token": "refresh-token" },
  });
}

const params = { params: Promise.resolve({ id: "fs-1" }) };

describe("POST /api/vm/[id]/pause and /resume", () => {
  beforeAll(() => {
    active = true;
  });
  afterAll(() => {
    active = false;
  });
  beforeEach(() => {
    authedUser = user;
    programs.length = 0;
    routeResult = { ok: true, value: { id: "fs-1", status: "paused" } };
  });

  test("an unauthenticated request never reaches the workflow", async () => {
    authedUser = null;
    const response = await pauseRoute.POST(post("/api/vm/fs-1/pause"), params);
    expect(response.status).toBe(401);
    expect(programs).toEqual([]);
  });

  test("pause hands the owner's scope and the machine id to pauseVm and answers the parked status", async () => {
    const response = await pauseRoute.POST(post("/api/vm/fs-1/pause"), params);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: "fs-1", status: "paused" });
    expect(programs).toHaveLength(1);
    expect(programs[0]?.kind).toBe("pause");
    expect(programs[0]?.input).toMatchObject({ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: "fs-1" });
  });

  test("resume passes the plan's machine allowance and plan so limits apply, and answers running", async () => {
    routeResult = { ok: true, value: { id: "fs-1", status: "running" } };
    const response = await resumeRoute.POST(post("/api/vm/fs-1/resume"), params);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: "fs-1", status: "running" });
    expect(programs).toHaveLength(1);
    expect(programs[0]?.kind).toBe("resume");
    const input = programs[0]?.input ?? {};
    expect(input).toMatchObject({ userId: "user-1", providerVmId: "fs-1", callerPlanId: "pro" });
    expect("maxActiveVms" in input).toBe(true);
  });

  test("a workflow refusal is returned as the workflow's own response (501 for a provider without pause)", async () => {
    routeResult = {
      ok: false,
      response: new Response(JSON.stringify({ error: "vm_operation_unsupported" }), {
        status: 501,
        headers: { "content-type": "application/json" },
      }),
    };
    const response = await pauseRoute.POST(post("/api/vm/fs-1/pause"), params);
    expect(response.status).toBe(501);
    expect((await response.json()).error).toBe("vm_operation_unsupported");
  });
});
