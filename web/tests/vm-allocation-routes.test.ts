import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

let active = false;
let workflowRuns = 0;

const realStack = await import("../app/lib/stack");
mock.module("../app/lib/stack", () => ({
  ...realStack,
  isStackConfigured: () => active ? false : realStack.isStackConfigured(),
}));

const realAuth = await import("../services/vms/auth");
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
mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(user) : realAuth.verifyRequest(request, options as never)) as typeof realAuth.verifyRequest,
  verifyRequestFromSnapshot: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(user) : realAuth.verifyRequestFromSnapshot(request, options as never)) as typeof realAuth.verifyRequestFromSnapshot,
}));

const realRouteWorkflow = await import("../services/vms/routeWorkflow");
mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRouteWorkflow.runVmRoute(program as never, options as never);
    workflowRuns += 1;
    throw new Error("allocation refusal must precede the VM workflow");
  }) as typeof realRouteWorkflow.runVmRoute,
}));

const createRoute = await import("../app/api/vm/route");
const forkRoute = await import("../app/api/vm/[id]/fork/route");
const restoreRoute = await import("../app/api/vm/restore/route");
const baseOpenRoute = await import("../app/api/vm/base/open/route");
const baseResetRoute = await import("../app/api/vm/base/reset/route");
const snapshotRoute = await import("../app/api/vm/[id]/snapshot/route");

const previousVercel = process.env.VERCEL;
const previousRule = process.env.CMUX_VM_ALLOCATION_RATE_LIMIT_ID;

beforeAll(() => { active = true; });
afterAll(() => {
  active = false;
  if (previousVercel === undefined) delete process.env.VERCEL;
  else process.env.VERCEL = previousVercel;
  if (previousRule === undefined) delete process.env.CMUX_VM_ALLOCATION_RATE_LIMIT_ID;
  else process.env.CMUX_VM_ALLOCATION_RATE_LIMIT_ID = previousRule;
});
beforeEach(() => {
  workflowRuns = 0;
  delete process.env.VERCEL;
  delete process.env.CMUX_VM_ALLOCATION_RATE_LIMIT_ID;
});

const headers = { origin: "https://cmux.test", "idempotency-key": "allocation-key" };
const context = { params: Promise.resolve({ id: "provider-vm-1" }) };

describe("provider allocation route admission", () => {
  test("requires an idempotency key before creating a snapshot", async () => {
    const response = await snapshotRoute.POST(
      new Request("https://cmux.test/api/vm/provider-vm-1/snapshot", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: "{}",
      }),
      context,
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "vm_idempotency_key_required" });
    expect(workflowRuns).toBe(0);
  });

  test("missing deployed limiter stops every provider allocation workflow", async () => {
    process.env.VERCEL = "1";
    const routes = [
      () => createRoute.POST(new Request("https://cmux.test/api/vm", {
        method: "POST", headers, body: JSON.stringify({ provider: "freestyle" }),
      })),
      () => forkRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/fork", {
        method: "POST", headers, body: "{}",
      }), context),
      () => restoreRoute.POST(new Request("https://cmux.test/api/vm/restore", {
        method: "POST", headers, body: JSON.stringify({ snapshotId: "snapshot-1" }),
      })),
      () => baseOpenRoute.POST(new Request("https://cmux.test/api/vm/base/open", {
        method: "POST", headers, body: JSON.stringify({ kind: "base" }),
      })),
      () => baseResetRoute.POST(new Request("https://cmux.test/api/vm/base/reset", {
        method: "POST", headers, body: JSON.stringify({ kind: "base" }),
      })),
      () => snapshotRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/snapshot", {
        method: "POST", headers, body: "{}",
      }), context),
    ];

    for (const invoke of routes) {
      const response = await invoke();
      expect(response.status).toBe(503);
      expect(response.headers.get("retry-after")).toBe("60");
      expect(await response.json()).toMatchObject({ error: "rate_limit_unavailable" });
      expect(workflowRuns).toBe(0);
    }
  });
});
