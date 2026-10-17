import { randomUUID } from "node:crypto";
import { and, asc, eq, gt, lte, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { agentBrokerJobs, agentBrokerReceipts } from "../../db/schema";
import {
  AGENT_BROKER_JOB_STATES,
  assertAgentBrokerEnvelope,
  assertLeaseTtl,
  type AgentBrokerEnvelope,
  type AgentBrokerJobState,
  type AgentBrokerReceipt,
} from "./model";

export const DEFAULT_AGENT_BROKER_LEASE_TTL_MS = 30_000;

export class AgentBrokerJobNotFoundError extends Error {
  override name = "AgentBrokerJobNotFoundError";
}
export class AgentBrokerIdempotencyConflictError extends Error {
  override name = "AgentBrokerIdempotencyConflictError";
}
export class AgentBrokerLeaseConflictError extends Error {
  override name = "AgentBrokerLeaseConflictError";
}
export class AgentBrokerReceiptConflictError extends Error {
  override name = "AgentBrokerReceiptConflictError";
}

type BrokerJob = typeof agentBrokerJobs.$inferSelect;
type BrokerReceiptRow = typeof agentBrokerReceipts.$inferSelect;
type BrokerDb = ReturnType<typeof cloudDb>;

type LeaseInput = {
  readonly jobId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
};

export type AgentBrokerJob = BrokerJob;

export type AgentBrokerLease = {
  readonly job: BrokerJob;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly leaseExpiresAt: Date;
};

export type AgentBrokerReceiptPage = {
  readonly receipts: readonly AgentBrokerReceipt[];
  readonly nextSequence: number | null;
};

function now(): Date {
  return new Date();
}

function requireRecord(value: Record<string, unknown> | null | undefined, name: string): Record<string, unknown> | null {
  if (value == null) return null;
  if (typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} must be a JSON object`);
  return value;
}

function receiptFromRow(row: BrokerReceiptRow): AgentBrokerReceipt {
  return {
    jobId: row.jobId,
    sequence: row.sequence,
    state: row.state,
    attempt: row.attempt,
    leaseGeneration: row.leaseGeneration,
    owner: row.owner,
    hostClass: row.hostClass,
    effectKey: row.effectKey,
    result: row.result,
    error: row.error,
    createdAt: row.createdAt,
  };
}

function sameRequest(job: BrokerJob, envelope: AgentBrokerEnvelope): boolean {
  return job.requestDigest === envelope.requestDigest
    && job.owner === envelope.owner
    && job.sourceSha === envelope.sourceSha
    && job.scopeRevision === envelope.scopeRevision
    && job.hostClass === envelope.hostClass;
}

async function getJobForUpdate(
  db: Pick<BrokerDb, "select">,
  jobId: string,
  tenantId?: string,
): Promise<BrokerJob | undefined> {
  const predicates = [eq(agentBrokerJobs.id, jobId)];
  if (tenantId) predicates.push(eq(agentBrokerJobs.tenantId, tenantId));
  return (await db.select().from(agentBrokerJobs).where(and(...predicates)).for("update").limit(1))[0];
}

async function appendReceipt(
  tx: Pick<BrokerDb, "insert">,
  job: BrokerJob,
  state: AgentBrokerJobState,
  nowAt: Date,
): Promise<void> {
  await tx.insert(agentBrokerReceipts).values({
    jobId: job.id,
    sequence: job.receiptSequence,
    state,
    attempt: job.attempt,
    leaseGeneration: job.leaseGeneration,
    owner: job.owner,
    hostClass: job.hostClass,
    effectKey: job.effectKey,
    result: job.result,
    error: job.error,
    createdAt: nowAt,
  });
}

/**
 * Insert one logical effect. Repeating the same envelope returns the original
 * row, while reusing an effect key for a different request fails closed.
 */
export async function enqueueJob(
  envelope: AgentBrokerEnvelope,
  nowAt = now(),
): Promise<BrokerJob> {
  assertAgentBrokerEnvelope(envelope);
  const db = cloudDb();
  return db.transaction(async (tx) => {
    const inserted = (await tx.insert(agentBrokerJobs).values({
      tenantId: envelope.tenantId,
      effectKey: envelope.effectKey,
      requestDigest: envelope.requestDigest,
      owner: envelope.owner,
      sourceSha: envelope.sourceSha,
      scopeRevision: envelope.scopeRevision,
      hostClass: envelope.hostClass,
      payload: envelope.payload,
      status: "queued",
      receiptSequence: 1,
      createdAt: nowAt,
      updatedAt: nowAt,
    }).onConflictDoNothing().returning())[0];
    if (inserted) {
      await tx.insert(agentBrokerReceipts).values({
        jobId: inserted.id,
        sequence: 1,
        state: "queued",
        attempt: 0,
        leaseGeneration: 0,
        owner: inserted.owner,
        hostClass: inserted.hostClass,
        effectKey: inserted.effectKey,
        result: null,
        error: null,
        createdAt: nowAt,
      });
      return inserted;
    }
    const existing = (await tx.select().from(agentBrokerJobs).where(and(
      eq(agentBrokerJobs.tenantId, envelope.tenantId),
      eq(agentBrokerJobs.effectKey, envelope.effectKey),
    )).limit(1))[0];
    if (!existing) throw new Error("broker job insert returned no row");
    if (!sameRequest(existing, envelope)) {
      throw new AgentBrokerIdempotencyConflictError("effect key was already used with a different request");
    }
    return existing;
  });
}

/**
 * Claim the oldest ready job for a worker. Expired leases are reclaimed by
 * incrementing leaseGeneration, which fences all receipts from the old host.
 */
export async function claimJob(input: {
  readonly workerId: string;
  readonly hostClass?: string;
  readonly ttlMs?: number;
  readonly now?: Date;
}): Promise<AgentBrokerLease | null> {
  if (!input.workerId.trim()) throw new Error("workerId is required");
  const ttlMs = assertLeaseTtl(input.ttlMs, DEFAULT_AGENT_BROKER_LEASE_TTL_MS);
  const nowAt = input.now ?? now();
  const expiresAt = new Date(nowAt.getTime() + ttlMs);
  const token = randomUUID();
  const db = cloudDb();
  return db.transaction(async (tx) => {
    const ready = or(
      eq(agentBrokerJobs.status, "queued"),
      and(eq(agentBrokerJobs.status, "leased"), lte(agentBrokerJobs.leaseExpiresAt, nowAt)),
    );
    const predicates = input.hostClass
      ? and(ready, eq(agentBrokerJobs.hostClass, input.hostClass))
      : ready;
    // A row lock serializes claimers. The provider adapter is outside this
    // transaction; it only receives the fenced token returned below.
    const candidate = (await tx.select().from(agentBrokerJobs)
      .where(predicates)
      .orderBy(asc(agentBrokerJobs.createdAt), asc(agentBrokerJobs.id))
      .limit(1)
      .for("update"))[0];
    if (!candidate) return null;
    const updated = (await tx.update(agentBrokerJobs).set({
      status: "leased",
      attempt: sql`${agentBrokerJobs.attempt} + 1`,
      leaseToken: token,
      leaseGeneration: sql`${agentBrokerJobs.leaseGeneration} + 1`,
      leaseOwner: input.workerId,
      leaseExpiresAt: expiresAt,
      receiptSequence: sql`${agentBrokerJobs.receiptSequence} + 1`,
      updatedAt: nowAt,
      error: null,
    }).where(eq(agentBrokerJobs.id, candidate.id)).returning())[0];
    if (!updated) throw new AgentBrokerJobNotFoundError("broker job disappeared during claim");
    await appendReceipt(tx, updated, "leased", nowAt);
    return {
      job: updated,
      leaseToken: token,
      leaseGeneration: updated.leaseGeneration,
      leaseExpiresAt: expiresAt,
    };
  });
}

/**
 * Claim one exact job id for a lifecycle worker.
 *
 * The general claim path intentionally takes the oldest ready job, but a
 * request/response lifecycle executor already has an idempotently enqueued
 * job and must never accidentally execute a different tenant's effect.
 */
export async function claimJobById(input: {
  readonly jobId: string;
  readonly workerId: string;
  readonly hostClass: string;
  readonly ttlMs?: number;
  readonly now?: Date;
}): Promise<AgentBrokerLease | null> {
  if (!input.workerId.trim()) throw new Error("workerId is required");
  if (!input.hostClass.trim()) throw new Error("hostClass is required");
  const ttlMs = assertLeaseTtl(input.ttlMs, DEFAULT_AGENT_BROKER_LEASE_TTL_MS);
  const nowAt = input.now ?? now();
  const expiresAt = new Date(nowAt.getTime() + ttlMs);
  const token = randomUUID();
  const db = cloudDb();
  return db.transaction(async (tx) => {
    const ready = or(
      eq(agentBrokerJobs.status, "queued"),
      and(eq(agentBrokerJobs.status, "leased"), lte(agentBrokerJobs.leaseExpiresAt, nowAt)),
    );
    const candidate = (await tx.select().from(agentBrokerJobs)
      .where(and(eq(agentBrokerJobs.id, input.jobId), eq(agentBrokerJobs.hostClass, input.hostClass), ready))
      .limit(1)
      .for("update"))[0];
    if (!candidate) return null;
    const updated = (await tx.update(agentBrokerJobs).set({
      status: "leased",
      attempt: sql`${agentBrokerJobs.attempt} + 1`,
      leaseToken: token,
      leaseGeneration: sql`${agentBrokerJobs.leaseGeneration} + 1`,
      leaseOwner: input.workerId,
      leaseExpiresAt: expiresAt,
      receiptSequence: sql`${agentBrokerJobs.receiptSequence} + 1`,
      updatedAt: nowAt,
      error: null,
    }).where(eq(agentBrokerJobs.id, candidate.id)).returning())[0];
    if (!updated) throw new AgentBrokerJobNotFoundError("broker job disappeared during claim");
    await appendReceipt(tx, updated, "leased", nowAt);
    return {
      job: updated,
      leaseToken: token,
      leaseGeneration: updated.leaseGeneration,
      leaseExpiresAt: expiresAt,
    };
  });
}

/** Renew a live lease without changing the receipt cursor. */
export async function renewJobLease(input: LeaseInput & { readonly ttlMs?: number; readonly now?: Date }): Promise<AgentBrokerLease> {
  const ttlMs = assertLeaseTtl(input.ttlMs, DEFAULT_AGENT_BROKER_LEASE_TTL_MS);
  const nowAt = input.now ?? now();
  const expiresAt = new Date(nowAt.getTime() + ttlMs);
  const updated = (await cloudDb().update(agentBrokerJobs).set({
    leaseExpiresAt: expiresAt,
    updatedAt: nowAt,
  }).where(and(
    eq(agentBrokerJobs.id, input.jobId),
    eq(agentBrokerJobs.leaseToken, input.leaseToken),
    eq(agentBrokerJobs.leaseGeneration, input.leaseGeneration),
    eq(agentBrokerJobs.status, "leased"),
    gt(agentBrokerJobs.leaseExpiresAt, nowAt),
  )).returning())[0];
  if (!updated) throw new AgentBrokerLeaseConflictError("stale or expired broker lease");
  return {
    job: updated,
    leaseToken: input.leaseToken,
    leaseGeneration: input.leaseGeneration,
    leaseExpiresAt: expiresAt,
  };
}

async function finishJob(
  input: LeaseInput & { readonly result?: Record<string, unknown> | null; readonly error?: string | null; readonly now?: Date },
  state: Extract<AgentBrokerJobState, "completed" | "failed">,
): Promise<BrokerJob> {
  const result = requireRecord(input.result, "result");
  if (state === "failed" && input.error != null && input.error.length > 8_192) throw new Error("error is too large");
  const nowAt = input.now ?? now();
  const db = cloudDb();
  return db.transaction(async (tx) => {
    const current = await getJobForUpdate(tx, input.jobId);
    if (!current) throw new AgentBrokerJobNotFoundError("broker job not found");
    if (current.status === state) return current;
    if (current.status !== "leased"
      || current.leaseToken !== input.leaseToken
      || current.leaseGeneration !== input.leaseGeneration
      || !current.leaseExpiresAt
      || current.leaseExpiresAt.getTime() <= nowAt.getTime()) {
      throw new AgentBrokerLeaseConflictError("stale or expired broker lease");
    }
    const updated = (await tx.update(agentBrokerJobs).set({
      status: state,
      leaseToken: null,
      leaseOwner: null,
      leaseExpiresAt: null,
      receiptSequence: sql`${agentBrokerJobs.receiptSequence} + 1`,
      result,
      error: state === "failed" ? (input.error ?? "broker job failed") : null,
      completedAt: nowAt,
      updatedAt: nowAt,
    }).where(and(eq(agentBrokerJobs.id, current.id), eq(agentBrokerJobs.leaseToken, input.leaseToken), eq(agentBrokerJobs.leaseGeneration, input.leaseGeneration))).returning())[0];
    if (!updated) throw new AgentBrokerLeaseConflictError("stale or expired broker lease");
    await appendReceipt(tx, updated, state, nowAt);
    return updated;
  });
}

export async function completeJob(input: LeaseInput & { readonly result?: Record<string, unknown> | null; readonly now?: Date }): Promise<BrokerJob> {
  return finishJob(input, "completed");
}

export async function failJob(input: LeaseInput & { readonly error: string; readonly result?: Record<string, unknown> | null; readonly now?: Date }): Promise<BrokerJob> {
  return finishJob(input, "failed");
}

export async function getJob(jobId: string, tenantId?: string): Promise<BrokerJob> {
  const predicates = [eq(agentBrokerJobs.id, jobId)];
  if (tenantId) predicates.push(eq(agentBrokerJobs.tenantId, tenantId));
  const job = (await cloudDb().select().from(agentBrokerJobs).where(and(...predicates)).limit(1))[0];
  if (!job) throw new AgentBrokerJobNotFoundError("broker job not found");
  return job;
}

/** Replay durable lifecycle receipts after a cursor. */
export async function listJobReceipts(input: {
  readonly jobId: string;
  readonly tenantId?: string;
  readonly afterSequence?: number;
  readonly limit?: number;
}): Promise<AgentBrokerReceiptPage> {
  await getJob(input.jobId, input.tenantId);
  const limit = Math.max(1, Math.min(input.limit ?? 100, 500));
  const rows = await cloudDb().select().from(agentBrokerReceipts).where(and(
    eq(agentBrokerReceipts.jobId, input.jobId),
    gt(agentBrokerReceipts.sequence, input.afterSequence ?? 0),
  )).orderBy(asc(agentBrokerReceipts.sequence)).limit(limit + 1);
  const receipts = rows.slice(0, limit).map(receiptFromRow);
  return {
    receipts,
    nextSequence: rows.length > limit ? receipts.at(-1)?.sequence ?? null : null,
  };
}

/** Keep route code independent of the table's concrete status representation. */
export function isTerminalJobState(state: AgentBrokerJobState): state is "completed" | "failed" {
  return state === "completed" || state === "failed";
}

export { AGENT_BROKER_JOB_STATES };
