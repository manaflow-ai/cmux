import { describe, expect, test } from "bun:test";
import type { AgentBrokerJob, AgentBrokerReceiptPage } from "../services/agent-broker/repository";
import type { AgentBrokerReceipt } from "../services/agent-broker/model";
import { BrokerReceiptProjectionError, projectBrokerReceipts } from "../services/runs/brokerReceiptProjection";

const job = {
  id: "job-1",
  tenantId: "team-1",
  owner: "run-owner",
  hostClass: "huge-blue",
  effectKey: "effect-1",
  sourceSha: "source-1",
  scopeRevision: "scope-1",
} as AgentBrokerJob;

function receipt(sequence: number, state: AgentBrokerReceipt["state"] = "leased", result: Record<string, unknown> | null = { ok: true }): AgentBrokerReceipt {
  return { jobId: job.id, sequence, state, attempt: 1, leaseGeneration: 1, owner: job.owner, hostClass: job.hostClass, effectKey: job.effectKey, result, error: null, createdAt: new Date(0) };
}

function dependencies(receipts: readonly AgentBrokerReceipt[], seen: Array<Record<string, unknown>>) {
  const page: AgentBrokerReceiptPage = { receipts, nextSequence: null };
  return {
    getJob: async () => job,
    listJobReceipts: async () => page,
    ingestRunEvent: async (input: Record<string, unknown>) => { seen.push(input); return input as never; },
  };
}

const input = { runId: "run-1", attemptId: "attempt-1", leaseToken: "lease-1", leaseGeneration: 1, tenantId: job.tenantId, owner: job.owner, hostClass: job.hostClass, effectKey: job.effectKey, sourceSha: job.sourceSha, scopeRevision: job.scopeRevision, jobId: job.id };

describe("broker receipt projection", () => {
  test("projects receipts with replay-safe external ids and never terminal success", async () => {
    const seen: Array<Record<string, unknown>> = [];
    await projectBrokerReceipts(input, dependencies([receipt(1, "queued"), receipt(2, "completed")], seen));
    expect(seen.map((event) => event.externalId)).toEqual(["broker:job-1:1", "broker:job-1:2"]);
    expect(seen.map((event) => event.kind)).toEqual(["attempt.queued", "attempt.heartbeat"]);
    expect(seen[1].payload).toEqual({ brokerReceipt: expect.objectContaining({ state: "completed", result: { ok: true } }) });
  });

  test("rejects out-of-order, stale source, and tenant mismatch receipts", async () => {
    const seen: Array<Record<string, unknown>> = [];
    await expect(projectBrokerReceipts(input, dependencies([receipt(2), receipt(2)], seen))).rejects.toMatchObject({ code: "sequence_conflict" });
    await expect(projectBrokerReceipts({ ...input, sourceSha: "stale" }, dependencies([receipt(1)], seen))).rejects.toMatchObject({ code: "correlation_mismatch" });
    await expect(projectBrokerReceipts({ ...input, tenantId: "other-team" }, dependencies([receipt(1)], seen))).rejects.toMatchObject({ code: "correlation_mismatch" });
  });

  test("rejects credential-like receipt fields before ingestion", async () => {
    const seen: Array<Record<string, unknown>> = [];
    await expect(projectBrokerReceipts(input, dependencies([receipt(1, "leased", { providerLeaseId: "secret-handle" })], seen))).rejects.toBeInstanceOf(BrokerReceiptProjectionError);
    expect(seen).toHaveLength(0);
  });
});
