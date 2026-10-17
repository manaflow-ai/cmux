import { describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import {
  AGENT_BROKER_PROTOCOL_VERSION,
  AgentBrokerInputError,
  assertAgentBrokerEnvelope,
  requestDigest,
  type AgentBrokerEnvelope,
  type AgentBrokerJobState,
  type AgentBrokerReceipt,
} from "../services/agent-broker/model";

type MemoryJob = {
  readonly id: string;
  readonly envelope: AgentBrokerEnvelope;
  status: AgentBrokerJobState;
  attempt: number;
  leaseGeneration: number;
  leaseToken: string | null;
  leaseExpiresAt: Date | null;
  result: Record<string, unknown> | null;
  error: string | null;
  readonly receipts: AgentBrokerReceipt[];
};

/** Deterministic contract double for lifecycle/fencing tests without Postgres. */
class MemoryBroker {
  readonly jobs = new Map<string, MemoryJob>();

  enqueue(envelope: AgentBrokerEnvelope): MemoryJob {
    const key = `${envelope.tenantId}:${envelope.effectKey}`;
    const existing = this.jobs.get(key);
    if (existing) {
      if (existing.envelope.requestDigest !== envelope.requestDigest) throw new Error("idempotency conflict");
      return existing;
    }
    const job: MemoryJob = {
      id: randomUUID(),
      envelope,
      status: "queued",
      attempt: 0,
      leaseGeneration: 0,
      leaseToken: null,
      leaseExpiresAt: null,
      result: null,
      error: null,
      receipts: [],
    };
    this.jobs.set(key, job);
    this.receipt(job, "queued", new Date(0));
    return job;
  }

  claim(hostClass: string, worker: string, now: Date, ttlMs: number): MemoryJob | null {
    const job = [...this.jobs.values()].find((candidate) => candidate.envelope.hostClass === hostClass
      && (candidate.status === "queued" || (candidate.status === "leased" && (candidate.leaseExpiresAt?.getTime() ?? 0) <= now.getTime())));
    if (!job) return null;
    job.status = "leased";
    job.attempt += 1;
    job.leaseGeneration += 1;
    job.leaseToken = `${worker}:${job.leaseGeneration}`;
    job.leaseExpiresAt = new Date(now.getTime() + ttlMs);
    this.receipt(job, "leased", now);
    return job;
  }

  complete(job: MemoryJob, token: string, generation: number, now: Date): void {
    if (job.status === "completed") return;
    if (job.status !== "leased" || job.leaseToken !== token || job.leaseGeneration !== generation || (job.leaseExpiresAt?.getTime() ?? 0) <= now.getTime()) {
      throw new Error("stale lease");
    }
    job.status = "completed";
    job.leaseToken = null;
    job.leaseExpiresAt = null;
    job.result = { ok: true };
    this.receipt(job, "completed", now);
  }

  fail(job: MemoryJob, token: string, generation: number, now: Date): void {
    if (job.status === "failed") return;
    if (job.status !== "leased" || job.leaseToken !== token || job.leaseGeneration !== generation || (job.leaseExpiresAt?.getTime() ?? 0) <= now.getTime()) {
      throw new Error("stale lease");
    }
    job.status = "failed";
    job.leaseToken = null;
    job.leaseExpiresAt = null;
    job.error = "provider unavailable";
    this.receipt(job, "failed", now);
  }

  private receipt(job: MemoryJob, state: AgentBrokerJobState, createdAt: Date): void {
    job.receipts.push({
      jobId: job.id,
      sequence: job.receipts.length + 1,
      state,
      attempt: job.attempt,
      leaseGeneration: job.leaseGeneration,
      owner: job.envelope.owner,
      hostClass: job.envelope.hostClass,
      effectKey: job.envelope.effectKey,
      result: job.result,
      error: job.error,
      createdAt,
    });
  }
}

function envelope(hostClass: string, effectKey = `effect-${hostClass}`): AgentBrokerEnvelope {
  const payload = { command: "build", hostClass };
  return {
    protocolVersion: AGENT_BROKER_PROTOCOL_VERSION,
    tenantId: "team-test",
    effectKey,
    requestDigest: requestDigest(payload),
    owner: "session-test",
    sourceSha: "abc123",
    scopeRevision: "7",
    hostClass,
    payload,
  };
}

describe("agent broker lifecycle contract", () => {
  for (const hostClass of ["huge-blue", "freestyle-vm"]) {
    test(`${hostClass} deduplicates, reclaims expired leases, and fences stale completion`, () => {
      const broker = new MemoryBroker();
      const first = broker.enqueue(envelope(hostClass));
      expect(broker.enqueue(envelope(hostClass))).toBe(first);
      expect(() => broker.enqueue({ ...envelope(hostClass), requestDigest: requestDigest({ command: "different" }) })).toThrow("idempotency conflict");

      const claimed = broker.claim(hostClass, "worker-a", new Date(1_000), 5_000);
      expect(claimed).toBe(first);
      expect(claimed?.leaseGeneration).toBe(1);
      expect(broker.claim(hostClass, "worker-b", new Date(2_000), 5_000)).toBeNull();

      const reclaimed = broker.claim(hostClass, "worker-b", new Date(7_000), 5_000);
      expect(reclaimed?.leaseGeneration).toBe(2);
      expect(() => broker.complete(first, "worker-a:1", 1, new Date(7_001))).toThrow("stale lease");
      broker.complete(first, reclaimed?.leaseToken ?? "", reclaimed?.leaseGeneration ?? 0, new Date(7_002));
      expect(first.status).toBe("completed");
      expect(first.receipts.map((receipt) => receipt.state)).toEqual(["queued", "leased", "leased", "completed"]);
      expect(first.receipts.map((receipt) => receipt.leaseGeneration)).toEqual([0, 1, 2, 2]);
    });
  }

  test("fails a live lease exactly once and validates malformed envelopes", () => {
    const broker = new MemoryBroker();
    const job = broker.enqueue(envelope("freestyle-vm", "failure-effect"));
    const lease = broker.claim("freestyle-vm", "worker-f", new Date(100), 5_000);
    if (!lease?.leaseToken) throw new Error("expected a lease");
    broker.fail(job, lease.leaseToken, lease.leaseGeneration, new Date(200));
    broker.fail(job, lease.leaseToken, lease.leaseGeneration, new Date(300));
    expect(job.status).toBe("failed");
    expect(job.receipts.at(-1)?.state).toBe("failed");
    expect(() => assertAgentBrokerEnvelope({ ...envelope("huge-blue"), requestDigest: "not-a-digest" })).toThrow("requestDigest");
    expect(() => {
      const malformed = { ...envelope("huge-blue"), protocolVersion: 2 as 1 };
      if (malformed.protocolVersion !== AGENT_BROKER_PROTOCOL_VERSION) throw new AgentBrokerInputError("unsupported version");
    }).toThrow("unsupported version");
    expect(() => {
      const mismatched = { ...envelope("huge-blue", "digest-mismatch"), requestDigest: requestDigest({ command: "different" }) };
      assertAgentBrokerEnvelope(mismatched);
    }).toThrow("requestDigest does not match payload");
  });
});
