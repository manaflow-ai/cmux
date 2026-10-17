import { describe, expect, test } from "bun:test";

import {
  createFreestyleHostLeaseAdapter,
  MemoryVmHostLeaseStore,
  VmHostLeaseTransport,
  type VmHostLeaseProviderOperation,
} from "../services/vms/hostLeaseTransport";
import {
  createPersistentWorkspacePromotionRuntimePort,
  createPersistentWorkspaceService,
  persistentWorkspaceProviderFromCloudVm,
  type PersistentWorkspaceRecord,
  type PersistentWorkspaceStore,
} from "../services/vms/persistentWorkspace";
import type {
  LifecycleEffectRequest,
  LifecycleEffectReceipt,
  PersistentWorkspaceEffectBroker,
} from "../services/vms/lifecycleEffectBroker";

class MemoryEffectBroker implements PersistentWorkspaceEffectBroker {
  readonly requests: LifecycleEffectRequest[] = [];
  readonly results = new Map<string, Record<string, unknown>>();

  async execute(input: LifecycleEffectRequest): Promise<LifecycleEffectReceipt> {
    this.requests.push(input);
    const existing = this.results.get(input.effectKey);
    if (existing) return { result: existing, replayed: true, jobId: `job-${input.effectKey}`, sequence: 3 };
    const result = await input.run();
    this.results.set(input.effectKey, result);
    return { result, replayed: false, jobId: `job-${input.effectKey}`, sequence: 3 };
  }
}

function providerFixture(options: { readonly failResume?: boolean } = {}) {
  const providerCalls: string[] = [];
  const leaseCalls: VmHostLeaseProviderOperation[] = [];
  const broker = new MemoryEffectBroker();
  const leaseClient = {
    acquire: async (input: VmHostLeaseProviderOperation) => {
      leaseCalls.push(input);
      return { providerLeaseId: `provider-lease-${leaseCalls.length}`, generation: input.generation, expiresAtMs: (input.nowMs ?? Date.now()) + 60_000 };
    },
    renew: async (input: VmHostLeaseProviderOperation) => {
      leaseCalls.push(input);
      return { providerLeaseId: `provider-lease-${leaseCalls.length}`, generation: input.generation, expiresAtMs: (input.nowMs ?? Date.now()) + 60_000 };
    },
    release: async (input: VmHostLeaseProviderOperation) => {
      leaseCalls.push(input);
      return { providerLeaseId: `provider-lease-${leaseCalls.length}`, generation: input.generation };
    },
  };
  const hostLeaseTransport = new VmHostLeaseTransport(
    new MemoryVmHostLeaseStore(),
    new Map([["freestyle", createFreestyleHostLeaseAdapter(leaseClient)]]),
  );
  const provider = persistentWorkspaceProviderFromCloudVm({
    provisionVm: async () => ({ providerVmId: "vm-freestyle-1" }),
    vm: {
      async resume(vmId) {
        providerCalls.push(`resume:${vmId}`);
        if (options.failResume) throw new Error("resume unavailable");
      },
      async pause(vmId) {
        providerCalls.push(`pause:${vmId}`);
      },
    },
    runAdapter: {
      async createWorkspace() {
        providerCalls.push("workspace:create");
        return {
          provider: "cloud-vm" as const,
          runtimeId: "runtime_1",
          vmId: "vm-freestyle-1",
          workspaceId: "workspace-provider-1",
          workspaceKey: "workspace-key",
          replayed: false,
        };
      },
      async createTerminal() {
        providerCalls.push("terminal:create");
        return {
          provider: "cloud-vm" as const,
          runtimeId: "runtime_1",
          vmId: "vm-freestyle-1",
          workspaceId: "workspace-provider-1",
          terminalId: "terminal-provider-1",
          terminalKey: "terminal-key",
          replayed: false,
        };
      },
    },
    hostLeaseTransport,
    effectBroker: broker,
    hostLeaseProvider: "freestyle",
  });
  return { provider, broker, leaseCalls, providerCalls };
}

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

const createRequest = {
  runtimeId: "runtime_1",
  workspaceId: "workspace_1",
  tenantId: "team_1",
  ownerId: "owner_1",
  generation: 1,
  effectKey: "cmux-runtime:runtime_1:create:v1",
  workspaceName: "review",
  workspaceKey: "cmux-runtime:runtime_1:workspace",
  providerInput: { terminal: { agent: "codex" as const, prompt: "hello" } },
};

describe("persistent workspace broker and host lease wiring", () => {
  test("replays create receipts and releases the host lease without persisting credentials", async () => {
    const fixture = providerFixture();
    const first = await fixture.provider.create(createRequest);
    const second = await fixture.provider.create(createRequest);
    expect(first).toEqual({ providerVmId: "vm-freestyle-1", providerWorkspaceId: "workspace-provider-1", providerTerminalId: "terminal-provider-1" });
    expect(second).toEqual(first);
    expect(fixture.providerCalls).toEqual(["workspace:create", "terminal:create"]);
    expect(fixture.leaseCalls.map((call) => call.operation)).toEqual(["acquire", "release"]);
    const lifecycle = fixture.broker.requests[0];
    expect(lifecycle.payload).not.toHaveProperty("providerVmId");
    expect(lifecycle.payload).not.toHaveProperty("providerWorkspaceId");
    expect(JSON.stringify(lifecycle.payload)).not.toContain("hello");
    expect(fixture.broker.results.get(createRequest.effectKey)).toEqual({
      providerVmId: "vm-freestyle-1",
      providerWorkspaceId: "workspace-provider-1",
      providerTerminalId: "terminal-provider-1",
    });
  });

  test("releases the host lease when a provider lifecycle operation fails", async () => {
    const fixture = providerFixture({ failResume: true });
    await expect(fixture.provider.resume({
      runtimeId: "runtime_1",
      workspaceId: "workspace_1",
      tenantId: "team_1",
      ownerId: "owner_1",
      providerVmId: "vm-freestyle-1",
      generation: 2,
      effectKey: "cmux-runtime:runtime_1:resume:v2",
    })).rejects.toThrow("resume unavailable");
    expect(fixture.leaseCalls.map((call) => call.operation)).toEqual(["acquire", "release"]);
  });

  test("fails closed before any provider call when the configured host adapter is absent", async () => {
    const fixture = providerFixture();
    const missingAdapterProvider = persistentWorkspaceProviderFromCloudVm({
      provisionVm: async () => {
        throw new Error("provision must not run");
      },
      vm: fixture.provider as never,
      runAdapter: fixture.provider as never,
      hostLeaseTransport: new VmHostLeaseTransport(new MemoryVmHostLeaseStore(), new Map()),
      effectBroker: fixture.broker,
      hostLeaseProvider: "huge-blue",
    });
    await expect(missingAdapterProvider.create(createRequest)).rejects.toMatchObject({ code: "provider_mismatch" });
    expect(fixture.broker.requests).toHaveLength(0);
  });

  test("promotion adopts retained handles through the same broker and lease path", async () => {
    const fixture = providerFixture();
    const service = createPersistentWorkspaceService({ store: storeFixture(), provider: fixture.provider });
    const runtime = createPersistentWorkspacePromotionRuntimePort({ service });
    const request = {
      userId: "owner_1",
      billingTeamId: "team_1",
      runId: "run_1",
      attemptId: "attempt_1",
      provider: "cloud-vm",
      providerVmId: "vm-freestyle-1",
      providerWorkspaceId: "workspace-provider-1",
      providerTerminalId: "terminal-provider-1",
      sessionId: "session_stable",
      requestKey: "promote_1",
    };
    const first = await runtime.promote(request);
    const replay = await runtime.promote(request);
    expect(first).toEqual({ runtimeId: first.runtimeId, workspaceId: first.workspaceId, state: "ready", sessionId: "session_stable", transport: "cmux-remote", attachExpiresAt: null });
    expect(replay).toEqual(first);
    expect(fixture.leaseCalls.map((call) => call.operation)).toEqual(["acquire", "release"]);
    expect(fixture.broker.requests).toHaveLength(1);
  });
});

