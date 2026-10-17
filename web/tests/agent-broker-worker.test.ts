import { describe, expect, test } from "bun:test";
import type { AgentBrokerJob, AgentBrokerLease } from "../services/agent-broker/repository";
import {
  AGENT_BROKER_ADAPTER_PROTOCOL_VERSION,
  createAdapterRegistry,
  type AgentBrokerEffectAdapter,
} from "../services/agent-broker/adapterBoundary";
import {
  createAgentBrokerWorker,
  type AgentBrokerWorkerRepository,
} from "../services/agent-broker/worker";

function job(hostClass = "huge-blue"): AgentBrokerJob {
  return {
    id: "job_1",
    tenantId: "tenant_1",
    effectKey: "effect_1",
    requestDigest: "sha256:fixture",
    owner: "worker",
    sourceSha: "source",
    scopeRevision: "scope",
    hostClass,
    payload: { operation: "probe", value: 1 },
    status: "queued",
    attempt: 1,
    leaseToken: "token_1",
    leaseOwner: "worker-1",
    leaseGeneration: 1,
    leaseExpiresAt: new Date(10_000),
    receiptSequence: 2,
    result: null,
    error: null,
    completedAt: null,
    createdAt: new Date(0),
    updatedAt: new Date(0),
  } as AgentBrokerJob;
}

function fakeRepository(current: AgentBrokerJob): AgentBrokerWorkerRepository & { readonly calls: string[] } {
  const calls: string[] = [];
  const lease: AgentBrokerLease = { job: current, leaseToken: "token_1", leaseGeneration: 1, leaseExpiresAt: new Date(10_000) };
  return {
    calls,
    claim: async () => { calls.push("claim"); return lease; },
    renew: async () => { calls.push("renew"); return lease; },
    complete: async ({ result }) => { calls.push(`complete:${JSON.stringify(result)}`); return { ...current, status: "completed", result } as AgentBrokerJob; },
    fail: async ({ error }) => { calls.push(`fail:${error}`); return { ...current, status: "failed", error } as AgentBrokerJob; },
  };
}

describe("independently deployable agent broker worker", () => {
  test("dispatches a serialized effect and commits a receipt", async () => {
    const repository = fakeRepository(job());
    const adapter: AgentBrokerEffectAdapter = {
      hostClass: "huge-blue",
      execute: async (input) => {
        expect(input.protocolVersion).toBe(AGENT_BROKER_ADAPTER_PROTOCOL_VERSION);
        expect(input.payload.operation).toBe("probe");
        return { ok: true, hostClass: input.hostClass };
      },
    };
    const result = await createAgentBrokerWorker({ workerId: "worker-1", adapters: [adapter], repository }).runOnce();
    expect(result).toEqual({ status: "completed", jobId: "job_1", replayed: false });
    expect(repository.calls).toContain('complete:{"ok":true,"hostClass":"huge-blue"}');
  });

  test("fails closed for an unconfigured host class", async () => {
    const repository = fakeRepository(job("freestyle"));
    const result = await createAgentBrokerWorker({ workerId: "worker-1", adapters: [], repository }).runOnce();
    expect(result.status).toBe("failed");
    expect(repository.calls[1]).toMatch(/^fail:no broker adapter configured/);
  });

  test("rejects duplicate adapter registrations before claiming work", () => {
    const adapter: AgentBrokerEffectAdapter = { hostClass: "mac-mini", execute: async () => ({ ok: true }) };
    expect(() => createAdapterRegistry([adapter, adapter])).toThrow("duplicate broker adapter host class");
  });

  test("does not replace a lost completion with a failure receipt", async () => {
    const repository = fakeRepository(job());
    repository.complete = async () => { throw new Error("receipt write lost after commit"); };
    const result = await createAgentBrokerWorker({
      workerId: "worker-1",
      adapters: [{ hostClass: "huge-blue", execute: async () => ({ ok: true }) }],
      repository,
    }).runOnce();
    expect(result.status).toBe("failed");
    expect(repository.calls.some((call) => call.startsWith("fail:"))).toBe(false);
  });
});
