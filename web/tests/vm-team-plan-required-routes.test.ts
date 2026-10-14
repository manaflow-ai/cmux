import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

// Resume and resize admit a machine against the team's allowance without the
// create gate, so they refuse a created team without the Team plan before
// any workflow or provider call, with the same Team plan answer as create.

let active = false;
let authedUser: AuthedUser | null = null;
const workflowCalls: string[] = [];

const realAuth = await import("../services/vms/auth");
const realVerifyRequest = realAuth.verifyRequest;
const realWorkflows = await import("../services/vms/workflows");
const realResumeVm = realWorkflows.resumeVm;
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
  resumeVm: ((input: Parameters<typeof realResumeVm>[0]) => {
    if (!active) return realResumeVm(input);
    workflowCalls.push("resume");
    return { sentinel: "resume" } as unknown as ReturnType<typeof realResumeVm>;
  }) as typeof realResumeVm,
  resizeVm: ((input: Parameters<typeof realResizeVm>[0]) => {
    if (!active) return realResizeVm(input);
    workflowCalls.push("resize");
    return { sentinel: "resize" } as unknown as ReturnType<typeof realResizeVm>;
  }) as typeof realResizeVm,
}));

mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRunVmRoute(program as never, options as never);
    const sentinel = (program as { sentinel?: string }).sentinel;
    return sentinel === "resume"
      ? { ok: true, value: { id: "vm-1", status: "running" } }
      : { ok: true, value: { state: "awake", diskTotalMb: 65536, cpus: 4, memoryTotalMb: 8192 } };
  }) as typeof realRunVmRoute,
}));

const resumeRoute = await import("../app/api/vm/[id]/resume/route");
const resizeRoute = await import("../app/api/vm/[id]/resize/route");

function proUserIn(team: { id: string; teamPlanRequired?: boolean; billingPlanId?: string | null; billingSeats?: number | null }): AuthedUser {
  return {
    id: "user-team-plan",
    isAnonymous: false,
    displayName: "Pro User",
    primaryEmail: "pro@example.com",
    billingCustomerType: "team",
    billingTeamId: team.id,
    selectedTeamId: team.id,
    teams: [{
      id: team.id,
      displayName: team.id,
      billingPlanId: team.billingPlanId ?? null,
      billingSeats: team.billingSeats ?? null,
      teamPlanRequired: team.teamPlanRequired,
    }],
    teamIds: [team.id],
    userBillingPlanId: "pro",
    billingPlanId: team.billingPlanId ?? (team.teamPlanRequired ? null : "pro"),
    billingSeats: team.billingSeats ?? null,
  };
}

function post(path: string, body?: unknown): Request {
  return new Request(`https://cmux.test/api/vm/vm-1/${path}`, {
    method: "POST",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const params = { params: Promise.resolve({ id: "vm-1" }) };

describe("resume and resize in a created team", () => {
  beforeAll(() => {
    active = true;
  });

  beforeEach(() => {
    workflowCalls.length = 0;
  });

  afterAll(() => {
    active = false;
  });

  test("a new unpaid team refuses resume and resize with the Team plan answer", async () => {
    authedUser = proUserIn({ id: "new-team", teamPlanRequired: true });
    for (const response of [
      await resumeRoute.POST(post("resume"), params),
      await resizeRoute.POST(post("resize", { memoryMb: 16384 }), params),
    ]) {
      expect(response.status).toBe(402);
      const body = await response.json() as Record<string, unknown>;
      expect(body.error).toBe("vm_requires_team_plan");
      expect(body.upgradeUrl).toBe("https://cmux.com/dashboard/billing?team=new-team");
    }
    expect(workflowCalls).toEqual([]);
  });

  test("the sign-up team and a Team-plan team still resume and resize", async () => {
    for (const team of [
      { id: "signup-team" },
      { id: "paid-team", teamPlanRequired: true, billingPlanId: "team", billingSeats: 2 },
    ]) {
      authedUser = proUserIn(team);
      expect((await resumeRoute.POST(post("resume"), params)).status).toBe(200);
      expect((await resizeRoute.POST(post("resize", { memoryMb: 16384 }), params)).status).toBe(200);
    }
    expect(workflowCalls).toEqual(["resume", "resize", "resume", "resize"]);
  });
});
