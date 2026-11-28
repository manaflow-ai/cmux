import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

import type { AuthedUser } from "../services/vms/auth";
import type { PersistentWorkspaceService } from "../services/vms/persistentWorkspace";

const user: AuthedUser = {
  id: "user-route",
  displayName: "Route User",
  primaryEmail: "route@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-route",
  selectedTeamId: "team-route",
  teams: [],
  teamIds: ["team-route"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 1,
};

let fakeService: PersistentWorkspaceService;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

mock.module("../services/vms/routeHelpers", () => ({
  withAuthedVmApiRoute: async (
    _request: Request,
    _route: string,
    _attributes: Record<string, unknown>,
    _failureLog: string,
    handler: (context: { user: AuthedUser; span: never; authDurationMs: number; routeStartedAtMs: number; setResponseFinalizer: () => void }) => Promise<Response>,
  ) => handler({ user, span: {} as never, authDurationMs: 0, routeStartedAtMs: 0, setResponseFinalizer: () => {} }),
  resolveVmProvisioningAccountScope: async () => ({ ok: true, entitlements: { billingTeamId: "team-route" } }),
  resolveVmRouteAccountScope: () => ({ ok: true, entitlements: { billingTeamId: "team-route" } }),
  jsonResponse,
}));

const { configurePersistentWorkspaceService } = await import("../services/vms/persistentWorkspace");
const collectionRoute = await import("../app/api/workspaces/route");
const itemRoute = await import("../app/api/workspaces/[id]/route");

function responseRequest(path: string, body?: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`https://cmux.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

describe("persistent workspace routes", () => {
  beforeEach(() => {
    fakeService = {
      create: mock(async () => ({ runtimeId: "runtime-route", workspaceId: "workspace-route", provider: "freestyle", lifecycle: "running", workspaceName: "route", attachable: true, createdAt: "now", updatedAt: "now", attachTarget: null })),
      get: mock(async () => ({ runtimeId: "runtime-route", workspaceId: "workspace-route", provider: "freestyle", lifecycle: "running", workspaceName: "route", attachable: true, createdAt: "now", updatedAt: "now" })),
      resume: mock(async () => ({ runtimeId: "runtime-route", workspaceId: "workspace-route", provider: "freestyle", lifecycle: "running", workspaceName: "route", attachable: true, createdAt: "now", updatedAt: "now" })),
      suspend: mock(async () => ({ runtimeId: "runtime-route", workspaceId: "workspace-route", provider: "freestyle", lifecycle: "suspended", workspaceName: "route", attachable: true, createdAt: "now", updatedAt: "now" })),
      stop: mock(async () => ({ runtimeId: "runtime-route", workspaceId: "workspace-route", provider: "freestyle", lifecycle: "stopped", workspaceName: "route", attachable: false, createdAt: "now", updatedAt: "now" })),
      attach: mock(async () => ({ redacted: true, provider: "freestyle", runtimeId: "runtime-route", workspaceId: "workspace-route", target: { token: "[redacted]" } })),
    } as unknown as PersistentWorkspaceService;
    configurePersistentWorkspaceService(fakeService);
  });

  afterAll(() => configurePersistentWorkspaceService(null));

  test("create route requires idempotency before invoking the service", async () => {
    const response = await collectionRoute.POST(responseRequest("/api/workspaces", { name: "route" }));
    expect(response.status).toBe(400);
    expect((fakeService.create as unknown as { mock: { calls: unknown[] } }).mock.calls).toHaveLength(0);
  });

  test("create route uses the entitlement tenant and returns the redacted runtime view", async () => {
    const response = await collectionRoute.POST(responseRequest("/api/workspaces", { name: "route" }, { "idempotency-key": "route-key" }));
    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({ runtimeId: "runtime-route", lifecycle: "running" });
    expect((fakeService.create as unknown as { mock: { calls: unknown[][] } }).mock.calls[0]?.[0]).toMatchObject({ tenantId: "team-route", ownerId: "user-route", idempotencyKey: "route-key" });
  });

  test("lifecycle route rejects unknown actions and returns attach output", async () => {
    const params = { params: Promise.resolve({ id: "runtime-route" }) };
    const invalid = await itemRoute.POST(responseRequest("/api/workspaces/runtime-route", { action: "delete" }), params);
    expect(invalid.status).toBe(400);
    const attached = await itemRoute.POST(responseRequest("/api/workspaces/runtime-route", { action: "attach" }), params);
    expect(attached.status).toBe(200);
    expect(await attached.json()).toEqual({ redacted: true, provider: "freestyle", runtimeId: "runtime-route", workspaceId: "workspace-route", target: { token: "[redacted]" } });
  });
});

