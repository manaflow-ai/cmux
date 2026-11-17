import { describe, expect, test } from "bun:test";

import {
  createPersistentWorkspaceService,
  PersistentWorkspaceIdempotencyConflictError,
  PersistentWorkspaceOwnershipError,
  type PersistentWorkspaceProvider,
  type PersistentWorkspaceRecord,
  type PersistentWorkspaceStore,
} from "../services/vms/persistentWorkspace";
import { CloudVmRunAdapter } from "../services/vms/cloudVmRunAdapter";

function storeFixture(): PersistentWorkspaceStore {
  const rows = new Map<string, PersistentWorkspaceRecord>();
  return {
    async createRuntime({ record }) {
      const existing = [...rows.values()].find((row) => row.tenantId === record.tenantId && row.idempotencyKey === record.idempotencyKey);
      if (existing) return { record: existing, created: false };
      rows.set(record.runtimeId, record);
      return { record, created: true };
    },
    async getRuntime({ runtimeId }) {
      return rows.get(runtimeId) ?? null;
    },
    async updateRuntime({ runtimeId, patch }) {
      const current = rows.get(runtimeId);
      if (!current) throw new Error("missing runtime");
      const next = { ...current, ...patch, version: (current.version ?? 0) + 1, updatedAt: new Date().toISOString() };
      rows.set(runtimeId, next);
      return next;
    },
  };
}

function providerFixture(options: { readonly failCreates?: number } = {}) {
  const calls = { create: 0, resume: 0, suspend: 0, stop: 0 };
  let failures = options.failCreates ?? 0;
  const provider: PersistentWorkspaceProvider = {
    async create(input) {
      calls.create += 1;
      if (failures > 0) {
        failures -= 1;
        throw new Error("provider temporarily unavailable");
      }
      return {
        providerVmId: "vm_freestyle_1",
        providerWorkspaceId: `provider_ws_${calls.create}`,
      };
    },
    async resume() { calls.resume += 1; },
    async suspend() { calls.suspend += 1; },
    async stop() { calls.stop += 1; },
    async attach() {
      return {
        route: "wss://vm.example/v1/link?token=secret-token&keep=1",
        token: "another-secret",
        nested: { authorization: "Bearer secret", label: "safe" },
      };
    },
  };
  return { provider, calls };
}

const request = {
  tenantId: "team_1",
  ownerId: "user_1",
  idempotencyKey: "workspace-key-1",
  workspaceName: "review workspace",
};

describe("persistent workspace lifecycle", () => {
  test("creates a durable runtime and redacts attach credentials", async () => {
    const fake = providerFixture();
    const service = createPersistentWorkspaceService({ store: storeFixture(), provider: fake.provider });
    const created = await service.create(request);
    expect(created.lifecycle).toBe("running");
    expect(created.runtimeId).toMatch(/^runtime_/);
    expect(created.workspaceId).toMatch(/^workspace_/);
    expect(created.attachTarget?.redacted).toBe(true);
    expect(created.attachTarget?.target).toMatchObject({ token: "[redacted]", nested: { authorization: "[redacted]", label: "safe" } });
    expect(created.attachTarget?.target.route).toBe("wss://vm.example/v1/link?token=%5Bredacted%5D&keep=1");
    expect(fake.calls.create).toBe(1);
  });

  test("same idempotency key replays the existing runtime without a second provider create", async () => {
    const fake = providerFixture();
    const service = createPersistentWorkspaceService({ store: storeFixture(), provider: fake.provider });
    const first = await service.create(request);
    const second = await service.create(request);
    expect(second.runtimeId).toBe(first.runtimeId);
    expect(second.workspaceId).toBe(first.workspaceId);
    expect(fake.calls.create).toBe(1);
  });

  test("rejects reusing an idempotency key for different request data", async () => {
    const fake = providerFixture();
    const service = createPersistentWorkspaceService({ store: storeFixture(), provider: fake.provider });
    await service.create(request);
    await expect(service.create({ ...request, workspaceName: "different workspace" }))
      .rejects.toBeInstanceOf(PersistentWorkspaceIdempotencyConflictError);
    expect(fake.calls.create).toBe(1);
  });

  test("retries a failed provider create with the same durable identity", async () => {
    const fake = providerFixture({ failCreates: 1 });
    const store = storeFixture();
    const service = createPersistentWorkspaceService({ store, provider: fake.provider });
    await expect(service.create(request)).rejects.toMatchObject({ code: "workspace_provider_error" });
    const retried = await service.create(request);
    expect(retried.lifecycle).toBe("running");
    expect(fake.calls.create).toBe(2);
  });

  test("denies a different owner before calling a provider", async () => {
    const fake = providerFixture();
    const service = createPersistentWorkspaceService({ store: storeFixture(), provider: fake.provider });
    const created = await service.create(request);
    await expect(service.get({ runtimeId: created.runtimeId, tenantId: "team_1", ownerId: "user_other" }))
      .rejects.toBeInstanceOf(PersistentWorkspaceOwnershipError);
    expect(fake.calls.create).toBe(1);
  });

  test("suspends, resumes, and stops idempotently while preserving identity", async () => {
    const fake = providerFixture();
    const service = createPersistentWorkspaceService({ store: storeFixture(), provider: fake.provider });
    const created = await service.create(request);
    const lookup = { runtimeId: created.runtimeId, tenantId: request.tenantId, ownerId: request.ownerId };
    expect((await service.suspend(lookup)).lifecycle).toBe("suspended");
    expect((await service.suspend(lookup)).lifecycle).toBe("suspended");
    expect((await service.resume(lookup)).lifecycle).toBe("running");
    expect((await service.stop(lookup)).lifecycle).toBe("stopped");
    expect((await service.stop(lookup)).lifecycle).toBe("stopped");
    expect(fake.calls.suspend).toBe(1);
    expect(fake.calls.resume).toBe(1);
    expect(fake.calls.stop).toBe(1);
  });

  test("workspace-only CloudVmRunAdapter create uses a stable correlation key", async () => {
    const commands: string[] = [];
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => {
        commands.push(command);
        return { exitCode: 0, stdout: JSON.stringify({ value: { workspace_id: "ws_provider_1", replayed: commands.length > 1 } }), stderr: "" };
      },
    });
    const first = await adapter.createWorkspace({ runtimeId: "runtime_1", vmId: "vm_1", workspaceName: "review" });
    const second = await adapter.createWorkspace({ runtimeId: "runtime_1", vmId: "vm_1", workspaceName: "review" });
    expect(first.workspaceId).toBe(second.workspaceId);
    expect(second.replayed).toBe(true);
    expect(commands[0]).toContain("workspace create --empty");
    expect(commands[0]).toContain("--correlation-key 'cmux-runtime:runtime_1:workspace'");
    expect(commands[0]).not.toContain("token");
  });
});

