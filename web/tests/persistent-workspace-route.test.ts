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
  resolveVmProvisioningAccountScope: async () => ({ ok: true, entitlements: { billingTeamId: "team-route", planId: "pro", billingCustomerType: "team", maxActiveVms: 3, resourcePool: null } }),
  resolveVmRouteAccountScope: () => ({ ok: true, entitlements: { billingTeamId: "team-route", planId: "pro", billingCustomerType: "team", maxActiveVms: 3, resourcePool: null } }),
  jsonResponse,
}));

const { configurePersistentWorkspaceService } = await import("../services/vms/persistentWorkspace");
const { configureRequestScopedWorkspaceInfrastructure } = await import("../services/runtimeComposition");
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

  afterAll(() => {
    configurePersistentWorkspaceService(null);
    configureRequestScopedWorkspaceInfrastructure(null);
  });

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

  test("create route uses an explicit request-scoped provider when no global service is installed", async () => {
    configurePersistentWorkspaceService(null);
    const rows = new Map<string, any>();
    configureRequestScopedWorkspaceInfrastructure({
      workspaceStore: {
        async createRuntime({ record }) {
          rows.set(record.runtimeId, record);
          return { record, created: true };
        },
        async getRuntime({ runtimeId }) { return rows.get(runtimeId) ?? null; },
        async updateRuntime({ runtimeId, patch }) {
          const next = { ...rows.get(runtimeId), ...patch, version: (rows.get(runtimeId)?.version ?? 1) + 1 };
          rows.set(runtimeId, next);
          return next;
        },
      },
      providerFactory: () => ({
        async create() { return { providerVmId: "vm-scoped", providerWorkspaceId: "workspace-scoped" }; },
        async resume() {},
        async suspend() {},
      }),
    });
    const response = await collectionRoute.POST(responseRequest("/api/workspaces", { name: "scoped" }, { "idempotency-key": "scoped-key" }));
    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({ lifecycle: "running", provider: "freestyle" });
  });

  test("create route passes an explicit Huge Blue provider through authenticated composition", async () => {
    configurePersistentWorkspaceService(null);
    const rows = new Map<string, any>();
    let selectedProvider: unknown;
    configureRequestScopedWorkspaceInfrastructure({
      workspaceStore: {
        async createRuntime({ record }) {
          rows.set(record.runtimeId, record);
          return { record, created: true };
        },
        async getRuntime({ runtimeId }) { return rows.get(runtimeId) ?? null; },
        async updateRuntime({ runtimeId, patch }) {
          const next = { ...rows.get(runtimeId), ...patch, version: (rows.get(runtimeId)?.version ?? 1) + 1 };
          rows.set(runtimeId, next);
          return next;
        },
      },
      providerFactory: (_context, provider) => {
        selectedProvider = provider;
        return {
          providerId: "huge-blue",
          async create() { return { providerVmId: "huge-blue-staging", providerWorkspaceId: "workspace-scoped" }; },
          async resume() {},
          async suspend() {},
        };
      },
    });
    const response = await collectionRoute.POST(responseRequest("/api/workspaces", { name: "huge-blue", provider: "huge-blue" }, { "idempotency-key": "huge-blue-key" }));
    expect(response.status).toBe(201);
    expect(selectedProvider).toBe("huge-blue");
    expect(await response.json()).toMatchObject({ lifecycle: "running", provider: "huge-blue" });
  });

  test("create route rejects an unknown provider before composition", async () => {
    configurePersistentWorkspaceService(null);
    const response = await collectionRoute.POST(responseRequest("/api/workspaces", { provider: "unknown" }, { "idempotency-key": "unknown-provider-key" }));
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "workspace_provider_invalid" });
  });
});
