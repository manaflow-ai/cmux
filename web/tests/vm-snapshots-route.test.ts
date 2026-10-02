import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

// GET /api/vm/[id]/snapshots and DELETE /api/vm/[id]/snapshots/[snapshotId]:
// the route contract around the workflows (auth gate, the program's inputs,
// the 200 bodies, and error pass-through). The workflows themselves are
// covered by vm-snapshots-workflow.test.ts. bun's mock.module is
// process-global, so every override delegates to the real implementation
// unless this suite is running (`active`).

let active = false;
let authedUser: AuthedUser | null = null;
const programs: Array<{ kind: "list" | "delete"; input: Record<string, unknown> }> = [];
let routeResult: { ok: true; value: unknown } | { ok: false; response: Response } = { ok: true, value: [] };

const realAuth = await import("../services/vms/auth");
const realVerifyRequest = realAuth.verifyRequest;
const realWorkflows = await import("../services/vms/workflows");
const realList = realWorkflows.listVmSnapshots;
const realDelete = realWorkflows.deleteVmSnapshot;
const realRouteWorkflow = await import("../services/vms/routeWorkflow");
const realRunVmRoute = realRouteWorkflow.runVmRoute;

mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(authedUser) : realVerifyRequest(request, options as never)) as typeof realVerifyRequest,
}));

mock.module("../services/vms/workflows", () => ({
  ...realWorkflows,
  listVmSnapshots: ((input: Parameters<typeof realList>[0]) => {
    if (!active) return realList(input);
    programs.push({ kind: "list", input: input as Record<string, unknown> });
    return { sentinel: "list" } as unknown as ReturnType<typeof realList>;
  }) as typeof realList,
  deleteVmSnapshot: ((input: Parameters<typeof realDelete>[0]) => {
    if (!active) return realDelete(input);
    programs.push({ kind: "delete", input: input as Record<string, unknown> });
    return { sentinel: "delete" } as unknown as ReturnType<typeof realDelete>;
  }) as typeof realDelete,
}));

mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRunVmRoute(program as never, options as never);
    expect((program as { sentinel?: string }).sentinel).toMatch(/^(list|delete)$/);
    return routeResult;
  }) as typeof realRunVmRoute,
}));

const listRoute = await import("../app/api/vm/[id]/snapshots/route");
const deleteRoute = await import("../app/api/vm/[id]/snapshots/[snapshotId]/route");

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

function request(path: string, method: "GET" | "DELETE"): Request {
  return new Request(`https://cmux.test${path}`, {
    method,
    headers: { authorization: "Bearer access-token", "x-stack-refresh-token": "refresh-token" },
  });
}

const listParams = { params: Promise.resolve({ id: "fs-1" }) };
const deleteParams = { params: Promise.resolve({ id: "fs-1", snapshotId: "snap-1" }) };

describe("GET /api/vm/[id]/snapshots and DELETE /api/vm/[id]/snapshots/[snapshotId]", () => {
  beforeAll(() => {
    active = true;
  });
  afterAll(() => {
    active = false;
  });
  beforeEach(() => {
    authedUser = user;
    programs.length = 0;
    routeResult = { ok: true, value: [] };
  });

  test("an unauthenticated request never reaches either workflow", async () => {
    authedUser = null;
    expect((await listRoute.GET(request("/api/vm/fs-1/snapshots", "GET"), listParams)).status).toBe(401);
    expect((await deleteRoute.DELETE(request("/api/vm/fs-1/snapshots/snap-1", "DELETE"), deleteParams)).status).toBe(401);
    expect(programs).toEqual([]);
  });

  test("list hands the owner's scope and the machine id to the workflow and answers ISO timestamps", async () => {
    routeResult = {
      ok: true,
      value: [
        { id: "snap-2", createdAt: Date.parse("2026-09-03T12:00:00Z") },
        { id: "snap-1", createdAt: Date.parse("2026-09-01T00:00:00Z"), name: "before-upgrade" },
      ],
    };
    const response = await listRoute.GET(request("/api/vm/fs-1/snapshots", "GET"), listParams);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      id: "fs-1",
      snapshots: [
        { id: "snap-2", name: null, createdAt: "2026-09-03T12:00:00.000Z" },
        { id: "snap-1", name: "before-upgrade", createdAt: "2026-09-01T00:00:00.000Z" },
      ],
    });
    expect(programs).toEqual([{ kind: "list", input: { userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: "fs-1" } }]);
  });

  test("delete names the machine and the snapshot, and answers the deletion", async () => {
    routeResult = { ok: true, value: { id: "snap-1", deleted: true } };
    const response = await deleteRoute.DELETE(request("/api/vm/fs-1/snapshots/snap-1", "DELETE"), deleteParams);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: "snap-1", deleted: true });
    expect(programs).toEqual([{
      kind: "delete",
      input: { userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: "fs-1", snapshotId: "snap-1" },
    }]);
  });

  test("a workflow refusal is returned as the workflow's own response (404 snapshot, 501 unsupported)", async () => {
    routeResult = {
      ok: false,
      response: new Response(JSON.stringify({ error: "vm_snapshot_not_found" }), { status: 404, headers: { "content-type": "application/json" } }),
    };
    const missing = await deleteRoute.DELETE(request("/api/vm/fs-1/snapshots/snap-1", "DELETE"), deleteParams);
    expect(missing.status).toBe(404);
    expect((await missing.json()).error).toBe("vm_snapshot_not_found");

    routeResult = {
      ok: false,
      response: new Response(JSON.stringify({ error: "vm_operation_unsupported" }), { status: 501, headers: { "content-type": "application/json" } }),
    };
    const unsupported = await listRoute.GET(request("/api/vm/fs-1/snapshots", "GET"), listParams);
    expect(unsupported.status).toBe(501);
    expect((await unsupported.json()).error).toBe("vm_operation_unsupported");
  });
});
