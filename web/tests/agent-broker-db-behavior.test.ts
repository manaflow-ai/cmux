import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import type { Sql } from "postgres";
import type * as BrokerRepository from "../services/agent-broker/repository";
import { AGENT_BROKER_PROTOCOL_VERSION, requestDigest, type AgentBrokerEnvelope } from "../services/agent-broker/model";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
let sql: Sql | null = null;
let broker: typeof BrokerRepository | null = null;
let createLifecycleEffectBroker: typeof import("../services/vms/lifecycleEffectBroker").createAgentBrokerLifecycleEffectBroker | null = null;

beforeAll(async () => {
  if (!enabled) return;
  const [{ default: postgres }, loaded, lifecycle] = await Promise.all([
    import("postgres"),
    import("../services/agent-broker/repository"),
    import("../services/vms/lifecycleEffectBroker"),
  ]);
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 1 });
  broker = loaded;
  createLifecycleEffectBroker = lifecycle.createAgentBrokerLifecycleEffectBroker;
});

afterAll(async () => {
  if (enabled) await (await import("../db/client")).closeCloudDbForTests();
  await sql?.end();
});

function repo(): typeof BrokerRepository {
  if (!broker) throw new Error("broker repository was not loaded");
  return broker;
}

function envelope(tenantId: string, hostClass: string, effectKey = `effect-${randomUUID()}`): AgentBrokerEnvelope {
  const payload = { operation: "build", hostClass };
  return {
    protocolVersion: AGENT_BROKER_PROTOCOL_VERSION,
    tenantId,
    effectKey,
    requestDigest: requestDigest(payload),
    owner: "db-test-session",
    sourceSha: "source-abc",
    scopeRevision: "revision-1",
    hostClass,
    payload,
  };
}

describe("durable agent broker repository", () => {
  dbTest("deduplicates effects, fences expiry takeover, and replays receipts", async () => {
    const tenantId = `broker-test-${randomUUID()}`;
    const firstEnvelope = envelope(tenantId, "huge-blue");
    try {
      const first = await repo().enqueueJob(firstEnvelope, new Date("2026-10-17T10:00:00.000Z"));
      const retry = await repo().enqueueJob(firstEnvelope, new Date("2026-10-17T10:00:01.000Z"));
      expect(retry.id).toBe(first.id);
      const conflictingPayload = { operation: "different" };
      await expect(repo().enqueueJob({
        ...firstEnvelope,
        payload: conflictingPayload,
        requestDigest: requestDigest(conflictingPayload),
      })).rejects.toBeInstanceOf(repo().AgentBrokerIdempotencyConflictError);

      const leaseA = await repo().claimJob({ workerId: "huge-blue-a", hostClass: "huge-blue", ttlMs: 5_000, now: new Date("2026-10-17T10:00:02.000Z") });
      expect(leaseA?.job.id).toBe(first.id);
      if (!leaseA) throw new Error("first claim did not return a lease");
      const leaseB = await repo().claimJob({ workerId: "huge-blue-b", hostClass: "huge-blue", ttlMs: 5_000, now: new Date("2026-10-17T10:00:08.000Z") });
      expect(leaseB?.leaseGeneration).toBe(leaseA.leaseGeneration + 1);
      if (!leaseB) throw new Error("expired lease was not reclaimed");
      await expect(repo().completeJob({ jobId: first.id, leaseToken: leaseA.leaseToken, leaseGeneration: leaseA.leaseGeneration, result: { stale: true }, now: new Date("2026-10-17T10:00:09.000Z") })).rejects.toBeInstanceOf(repo().AgentBrokerLeaseConflictError);
      const completed = await repo().completeJob({ jobId: first.id, leaseToken: leaseB.leaseToken, leaseGeneration: leaseB.leaseGeneration, result: { ok: true }, now: new Date("2026-10-17T10:00:10.000Z") });
      expect(completed.status).toBe("completed");
      const receipts = await repo().listJobReceipts({ jobId: first.id, tenantId });
      expect(receipts.receipts.map((receipt) => receipt.state)).toEqual(["queued", "leased", "leased", "completed"]);
      expect(receipts.receipts.map((receipt) => receipt.leaseGeneration)).toEqual([0, 1, 2, 2]);
    } finally {
      await sql!`delete from agent_broker_jobs where tenant_id = ${tenantId}`;
    }
  });

  dbTest("allows one terminal failure and fences a late worker", async () => {
    const tenantId = `broker-fail-${randomUUID()}`;
    try {
      const job = await repo().enqueueJob(envelope(tenantId, "freestyle-vm"));
      const lease = await repo().claimJob({ workerId: "freestyle-worker", hostClass: "freestyle-vm" });
      if (!lease) throw new Error("claim did not return a lease");
      const failed = await repo().failJob({ jobId: job.id, leaseToken: lease.leaseToken, leaseGeneration: lease.leaseGeneration, error: "provider unavailable" });
      expect(failed.status).toBe("failed");
      await expect(repo().completeJob({ jobId: job.id, leaseToken: lease.leaseToken, leaseGeneration: lease.leaseGeneration, result: { late: true } })).rejects.toBeInstanceOf(repo().AgentBrokerLeaseConflictError);
    } finally {
      await sql!`delete from agent_broker_jobs where tenant_id = ${tenantId}`;
    }
  });

  dbTest("claims the exact lifecycle effect and replays its completed receipt", async () => {
    const tenantId = `broker-lifecycle-${randomUUID()}`;
    let executions = 0;
    try {
      const request = {
        tenantId,
        ownerId: "owner-1",
        hostClass: "freestyle-vm",
        effectKey: "runtime:one:resume:v1",
        payload: { operation: "resume", runtimeId: "runtime-one" },
        run: async () => {
          executions += 1;
          return { ok: true, execution: executions };
        },
      };
      if (!createLifecycleEffectBroker) throw new Error("lifecycle effect broker was not loaded");
      const lifecycle = createLifecycleEffectBroker({
        workerId: "lifecycle-worker",
        sourceSha: "runtime-lifecycle-test",
        scopeRevision: "scope-1",
        now: () => new Date("2026-10-17T10:01:00.000Z"),
      });
      const first = await lifecycle.execute(request);
      const replay = await lifecycle.execute(request);
      expect(first.result).toEqual({ ok: true, execution: 1 });
      expect(replay.result).toEqual(first.result);
      expect(replay.replayed).toBe(true);
      expect(executions).toBe(1);
      const receipts = await repo().listJobReceipts({ jobId: first.jobId, tenantId });
      expect(receipts.receipts.map((receipt) => receipt.state)).toEqual(["queued", "leased", "completed"]);
    } finally {
      await sql!`delete from agent_broker_jobs where tenant_id = ${tenantId}`;
    }
  });

  dbTest("claimJobById cannot execute a different queued effect", async () => {
    const tenantId = `broker-exact-${randomUUID()}`;
    try {
      const first = await repo().enqueueJob(envelope(tenantId, "freestyle-vm", "exact-first"));
      const second = await repo().enqueueJob(envelope(tenantId, "freestyle-vm", "exact-second"));
      const lease = await repo().claimJobById({ jobId: second.id, workerId: "exact-worker", hostClass: "freestyle-vm" });
      expect(lease?.job.id).toBe(second.id);
      expect((await repo().getJob(first.id, tenantId)).status).toBe("queued");
      if (!lease) throw new Error("exact claim did not return a lease");
      await repo().completeJob({ jobId: second.id, leaseToken: lease.leaseToken, leaseGeneration: lease.leaseGeneration, result: { ok: true } });
    } finally {
      await sql!`delete from agent_broker_jobs where tenant_id = ${tenantId}`;
    }
  });
});
