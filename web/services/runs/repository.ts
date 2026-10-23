import { randomUUID, randomBytes, createHash } from "node:crypto";
import { and, asc, desc, eq, gt, inArray, isNotNull, isNull, lt, lte, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudRuntimes, runArtifacts, runAttempts, runEvents, runs } from "../../db/schema";
import {
  DEFAULT_LEASE_TTL_MS,
  DEFAULT_ATTACH_TICKET_TTL_MS,
  DEFAULT_TERMINAL_RETENTION_MS,
  MAX_ARTIFACT_BYTES,
  MAX_EVENT_PAYLOAD_BYTES,
  TERMINAL_CLEANUP_LEASE_MS,
  assertArtifactDigest,
  jsonByteLength,
  type AttemptStatus,
  type RunEventKind,
  type RunStatus,
} from "./model";

export class RunIdempotencyConflictError extends Error {}
export class RunNotFoundError extends Error {}
export class RunAttemptNotFoundError extends Error {}
export class RunLeaseConflictError extends Error {}
export class RunPayloadTooLargeError extends Error {}
export class RunArtifactConflictError extends Error {}
export class RunEventConflictError extends Error {}
export class RunAttachTicketNotFoundError extends Error {}
export class RunAttachTicketExpiredError extends Error {}
export class RunAttachTicketReplayError extends Error {}
export class RunAttachTargetUnavailableError extends Error {}

export type RunSource = { readonly repository?: string; readonly ref?: string; readonly commit?: string; readonly archiveDigest?: string };
export type RunSnapshot = {
  readonly run: typeof runs.$inferSelect;
  readonly attempts: (typeof runAttempts.$inferSelect)[];
  readonly artifacts: (typeof runArtifacts.$inferSelect)[];
};

export type CreateRunInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly idempotencyKey?: string | null;
  readonly requestDigest: string;
  readonly source: RunSource;
  readonly recipe: string;
  readonly provider?: string;
  readonly desiredAttempts: number;
};

export type RunAttachTarget = {
  readonly runId: string;
  readonly attemptId: string;
  readonly provider: string;
  readonly providerVmId: string;
  readonly providerWorkspaceId: string;
  readonly providerTerminalId: string;
  readonly expiresAt: Date;
};

export type MintedRunAttachTicket = RunAttachTarget & {
  readonly ticket: string;
};

type RunQueryDb = Pick<ReturnType<typeof cloudDb>, "select" | "execute">;

function now(): Date {
  return new Date();
}

export function requestDigest(value: unknown): string {
  return `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`;
}

export async function createRun(input: CreateRunInput): Promise<RunSnapshot> {
  if (!Number.isSafeInteger(input.desiredAttempts) || input.desiredAttempts < 1 || input.desiredAttempts > 32) {
    throw new Error("desiredAttempts must be between 1 and 32");
  }
  const db = cloudDb();
  return db.transaction(async (tx) => {
    const values = {
      userId: input.userId,
      billingTeamId: input.billingTeamId ?? null,
      idempotencyKey: input.idempotencyKey ?? null,
      requestDigest: input.requestDigest,
      source: input.source,
      recipe: input.recipe,
      provider: input.provider ?? "cloud-vm",
      desiredAttempts: input.desiredAttempts,
    };
    let run: typeof runs.$inferSelect | undefined;
    let inserted = false;
    if (input.idempotencyKey) {
      run = (await tx.insert(runs).values(values).onConflictDoNothing().returning())[0];
      inserted = !!run;
      if (!run) {
        run = (await tx.select().from(runs).where(and(eq(runs.userId, input.userId), eq(runs.idempotencyKey, input.idempotencyKey))).limit(1))[0];
        if (run && run.requestDigest !== input.requestDigest) throw new RunIdempotencyConflictError("idempotency key was already used with a different request");
      }
    } else {
      run = (await tx.insert(runs).values(values).returning())[0];
      inserted = true;
    }
    if (!run) throw new Error("run insert returned no row");
    if (inserted) {
      await tx.insert(runAttempts).values(Array.from({ length: input.desiredAttempts }, (_, ordinal) => ({
        runId: run.id,
        ordinal,
      })));
      await tx.insert(runEvents).values({
        runId: run.id,
        sequence: 1,
        externalId: "run-created",
        kind: "run.created",
        payload: { recipe: run.recipe, desiredAttempts: run.desiredAttempts },
      });
    }
    return readSnapshot(tx, run.id, input.userId);
  });
}

async function readSnapshot(db: RunQueryDb, runId: string, userId: string): Promise<RunSnapshot> {
  const run = (await db.select().from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).limit(1))[0];
  if (!run) throw new RunNotFoundError("run not found");
  const attempts = await db.select().from(runAttempts).where(eq(runAttempts.runId, runId)).orderBy(asc(runAttempts.ordinal));
  const artifacts = await db.select().from(runArtifacts).where(eq(runArtifacts.runId, runId)).orderBy(desc(runArtifacts.createdAt));
  return { run, attempts, artifacts };
}

export async function getRun(runId: string, userId: string): Promise<RunSnapshot> {
  return readSnapshot(cloudDb(), runId, userId);
}

function attachTicketHash(ticket: string): string {
  return `sha256:${createHash("sha256").update(ticket, "utf8").digest("hex")}`;
}

/**
 * Mint a short-lived, one-use ticket for a retained attempt. The database only
 * stores a digest of the random ticket and the provider handles it is scoped
 * to, so a leaked database row cannot be used as an attach credential.
 */
export async function mintRunAttachTicket(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly userId: string;
  readonly ttlMs?: number;
}): Promise<MintedRunAttachTicket> {
  const nowAt = now();
  const ticket = randomBytes(32).toString("base64url");
  const hash = attachTicketHash(ticket);
  const ttlMs = Math.max(5_000, Math.min(input.ttlMs ?? DEFAULT_ATTACH_TICKET_TTL_MS, DEFAULT_ATTACH_TICKET_TTL_MS));
  return cloudDb().transaction(async (tx) => {
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const run = (await tx.select({ id: runs.id, provider: runs.provider }).from(runs).where(and(eq(runs.id, input.runId), eq(runs.userId, input.userId))).limit(1))[0];
    const attempt = (await tx.select().from(runAttempts).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).limit(1))[0];
    if (!run || !attempt) throw new RunNotFoundError("run not found");
    if (!attempt.terminalRetainUntil || attempt.terminalRetainUntil.getTime() <= nowAt.getTime()) {
      throw new RunAttachTicketExpiredError("the terminal attach window has expired");
    }
    if (!attempt.providerVmId || !attempt.providerWorkspaceId || !attempt.providerTerminalId) {
      throw new RunAttachTargetUnavailableError("the attempt has no retained provider terminal");
    }
    const expiresAt = new Date(Math.min(attempt.terminalRetainUntil.getTime(), nowAt.getTime() + ttlMs));
    const updated = (await tx.update(runAttempts).set({
      attachTicketHash: hash,
      attachTicketExpiresAt: expiresAt,
      attachTicketConsumedAt: null,
      updatedAt: nowAt,
    }).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).returning())[0];
    if (!updated) throw new RunAttachTargetUnavailableError("the attempt is no longer attachable");
    return {
      ticket,
      runId: input.runId,
      attemptId: input.attemptId,
      provider: run.provider,
      providerVmId: attempt.providerVmId,
      providerWorkspaceId: attempt.providerWorkspaceId,
      providerTerminalId: attempt.providerTerminalId,
      expiresAt,
    };
  });
}

/** Atomically consume an attach ticket and return only its server-side target. */
export async function consumeRunAttachTicket(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly userId: string;
  readonly ticket: string;
}): Promise<RunAttachTarget> {
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(input.ticket)) throw new RunAttachTicketNotFoundError("attach ticket not found");
  const nowAt = now();
  const hash = attachTicketHash(input.ticket);
  return cloudDb().transaction(async (tx) => {
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const run = (await tx.select({ id: runs.id, provider: runs.provider }).from(runs).where(and(eq(runs.id, input.runId), eq(runs.userId, input.userId))).limit(1))[0];
    const attempt = (await tx.select().from(runAttempts).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).limit(1))[0];
    // Deliberately collapse ownership and token mismatches into not-found so a
    // caller cannot probe another tenant's retained VM handles.
    if (!run || !attempt || attempt.attachTicketHash !== hash) throw new RunAttachTicketNotFoundError("attach ticket not found");
    if (attempt.attachTicketConsumedAt) throw new RunAttachTicketReplayError("attach ticket was already consumed");
    if (!attempt.attachTicketExpiresAt || attempt.attachTicketExpiresAt.getTime() <= nowAt.getTime() || !attempt.terminalRetainUntil || attempt.terminalRetainUntil.getTime() <= nowAt.getTime()) {
      throw new RunAttachTicketExpiredError("the terminal attach window has expired");
    }
    if (!attempt.providerVmId || !attempt.providerWorkspaceId || !attempt.providerTerminalId) {
      throw new RunAttachTargetUnavailableError("the attempt has no retained provider terminal");
    }
    const consumed = (await tx.update(runAttempts).set({ attachTicketConsumedAt: nowAt, updatedAt: nowAt }).where(and(
      eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId), eq(runAttempts.attachTicketHash, hash), isNull(runAttempts.attachTicketConsumedAt), gt(runAttempts.attachTicketExpiresAt, nowAt),
    )).returning())[0];
    if (!consumed) throw new RunAttachTicketReplayError("attach ticket was already consumed");
    return {
      runId: input.runId,
      attemptId: input.attemptId,
      provider: run.provider,
      providerVmId: attempt.providerVmId,
      providerWorkspaceId: attempt.providerWorkspaceId,
      providerTerminalId: attempt.providerTerminalId,
      expiresAt: attempt.attachTicketExpiresAt,
    };
  });
}

export async function listRunEvents(input: {
  readonly runId: string;
  readonly userId: string;
  readonly afterSequence?: number;
  readonly limit?: number;
}): Promise<{ readonly events: (typeof runEvents.$inferSelect)[]; readonly nextSequence: number | null }> {
  const db = cloudDb();
  const run = (await db.select({ id: runs.id }).from(runs).where(and(eq(runs.id, input.runId), eq(runs.userId, input.userId))).limit(1))[0];
  if (!run) throw new RunNotFoundError("run not found");
  const limit = Math.max(1, Math.min(input.limit ?? 100, 500));
  const rows = await db.select().from(runEvents).where(and(
    eq(runEvents.runId, input.runId),
    gt(runEvents.sequence, input.afterSequence ?? 0),
  )).orderBy(asc(runEvents.sequence)).limit(limit + 1);
  const events = rows.slice(0, limit);
  return { events, nextSequence: rows.length > limit ? events.at(-1)?.sequence ?? null : null };
}

export type AttemptLease = {
  readonly attempt: typeof runAttempts.$inferSelect;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly leaseExpiresAt: Date;
};

export async function claimAttemptLease(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly workerId: string;
  readonly ttlMs?: number;
}): Promise<AttemptLease> {
  const ttlMs = Math.max(5_000, Math.min(input.ttlMs ?? DEFAULT_LEASE_TTL_MS, 15 * 60_000));
  const nowAt = now();
  const expiresAt = new Date(nowAt.getTime() + ttlMs);
  const token = randomUUID();
  return cloudDb().transaction(async (tx) => {
    const run = (await tx.select({ status: runs.status }).from(runs).where(eq(runs.id, input.runId)).for("update").limit(1))[0];
    if (!run || run.status === "cancelling" || run.status === "cancelled" || run.status === "succeeded" || run.status === "failed") {
      throw new RunLeaseConflictError("run is not accepting new attempt leases");
    }
    const rows = await tx.update(runAttempts).set({
    status: "leased",
    leaseToken: token,
    leaseGeneration: sql`${runAttempts.leaseGeneration} + 1`,
    leaseExpiresAt: expiresAt,
    updatedAt: nowAt,
    }).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    or(
      eq(runAttempts.status, "queued"),
      and(
        inArray(runAttempts.status, ["leased", "running"]),
        or(isNull(runAttempts.leaseExpiresAt), lt(runAttempts.leaseExpiresAt, nowAt)),
      ),
    ),
    )).returning();
    const attempt = rows[0];
    if (!attempt) throw new RunLeaseConflictError("attempt is already leased or does not exist");
    await tx.update(runs).set({ status: "running", updatedAt: nowAt }).where(and(eq(runs.id, input.runId), eq(runs.status, "queued")));
    return { attempt, leaseToken: token, leaseGeneration: attempt.leaseGeneration, leaseExpiresAt: expiresAt };
  });
}

export async function renewAttemptLease(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly ttlMs?: number;
}): Promise<AttemptLease> {
  const nowAt = now();
  const expiresAt = new Date(nowAt.getTime() + Math.max(5_000, Math.min(input.ttlMs ?? DEFAULT_LEASE_TTL_MS, 15 * 60_000)));
  const attempt = (await cloudDb().update(runAttempts).set({
    leaseExpiresAt: expiresAt,
    updatedAt: nowAt,
  }).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    eq(runAttempts.leaseToken, input.leaseToken),
    eq(runAttempts.leaseGeneration, input.leaseGeneration),
    inArray(runAttempts.status, ["leased", "running"]),
    gt(runAttempts.leaseExpiresAt, nowAt),
  )).returning())[0];
  if (!attempt) throw new RunLeaseConflictError("stale or expired attempt lease");
  return { attempt, leaseToken: input.leaseToken, leaseGeneration: input.leaseGeneration, leaseExpiresAt: expiresAt };
}

/** Persist the provider handles before a worker starts streaming terminal events. */
export async function recordAttemptProviderHandle(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly providerVmId: string;
  readonly providerWorkspaceId: string;
  readonly providerTerminalId: string;
}): Promise<typeof runAttempts.$inferSelect> {
  const db = cloudDb();
  return db.transaction(async (tx) => {
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    await checkLease(tx, input);
    const attempt = (await tx.update(runAttempts).set({
      providerVmId: input.providerVmId,
      providerWorkspaceId: input.providerWorkspaceId,
      providerTerminalId: input.providerTerminalId,
      updatedAt: now(),
    }).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
      eq(runAttempts.leaseToken, input.leaseToken),
      eq(runAttempts.leaseGeneration, input.leaseGeneration),
    )).returning())[0];
    if (!attempt) throw new RunLeaseConflictError("stale or expired attempt lease");
    return attempt;
  });
}

/** Keep a provider VM around after a terminal event so the terminal can be attached. */
export async function scheduleAttemptRetention(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly providerVmId?: string;
  readonly retentionMs?: number;
}): Promise<typeof runAttempts.$inferSelect> {
  const retentionMs = Math.max(1_000, Math.min(input.retentionMs ?? DEFAULT_TERMINAL_RETENTION_MS, 60 * 60_000));
  const attempt = (await cloudDb().update(runAttempts).set({
    ...(input.providerVmId ? { providerVmId: input.providerVmId } : {}),
    terminalRetainUntil: new Date(Date.now() + retentionMs),
    cleanupLeaseToken: null,
    cleanupLeaseExpiresAt: null,
    leaseToken: null,
    leaseExpiresAt: null,
    updatedAt: now(),
  }).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    eq(runAttempts.leaseToken, input.leaseToken),
    eq(runAttempts.leaseGeneration, input.leaseGeneration),
    inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
  )).returning())[0];
  if (attempt) return attempt;
  if (input.providerVmId) {
    const orphan = await adoptFencedAttemptVm({ ...input, providerVmId: input.providerVmId });
    if (orphan) return orphan;
  }
  throw new RunLeaseConflictError("stale or expired attempt lease");
}

/**
 * A cancel (or a replacement lease) can fence a worker while its createVm is
 * still in flight. That worker then learns the VM id only after it can no
 * longer write, so no row would point at the VM and the reaper would never
 * destroy it. Record the id for immediate cleanup, but only when no lease ever
 * stored a VM for this attempt: then nothing else owns the VM (the create is
 * idempotent per attempt), and a VM the reaper already destroyed and cleared
 * is never handed back to it. The fenced worker's other state is not written.
 *
 * A retention deadline alone does not mean a VM exists: a replacement lease
 * that fails the attempt before creating one also sets it. Adoption therefore
 * ignores the deadline and keys "nothing to reap" on the VM id and on the
 * journal, and it journals the adopted id itself so that a VM it handed to the
 * reaper, once destroyed and cleared, cannot be adopted a second time. A
 * terminal status means no live lease owns the attempt, and a promoted VM is
 * always recorded on the row or in the journal, so neither can be adopted.
 */
async function adoptFencedAttemptVm(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseGeneration: number;
  readonly providerVmId: string;
}): Promise<typeof runAttempts.$inferSelect | undefined> {
  return cloudDb().transaction(async (tx) => {
    // Same lock order as ingestRunEvent, which allocates journal sequences.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.runId}, 0))`);
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const nowAt = now();
    const adopted = (await tx.update(runAttempts).set({
      providerVmId: input.providerVmId,
      terminalRetainUntil: nowAt,
      cleanupLeaseToken: null,
      cleanupLeaseExpiresAt: null,
      updatedAt: nowAt,
    }).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
      gt(runAttempts.leaseGeneration, input.leaseGeneration),
      inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
      isNull(runAttempts.providerVmId),
      isNull(runAttempts.cleanupLeaseToken),
      sql`not exists (select 1 from run_events where run_events.attempt_id = ${input.attemptId} and run_events.payload->>'providerVmId' is not null)`,
    )).returning())[0];
    if (!adopted) return undefined;
    await tx.insert(runEvents).values({
      runId: input.runId,
      attemptId: input.attemptId,
      sequence: await nextSequence(tx, input.runId),
      externalId: `provider-vm-adopted:${input.leaseGeneration}`,
      kind: "attempt.heartbeat",
      payload: { providerVmId: input.providerVmId, adoptedFromLeaseGeneration: input.leaseGeneration },
    });
    return adopted;
  });
}

type LeaseInput = { readonly runId: string; readonly attemptId: string; readonly leaseToken: string; readonly leaseGeneration: number };

async function findLiveLease(db: RunQueryDb, input: LeaseInput): Promise<typeof runAttempts.$inferSelect | undefined> {
  return (await db.select().from(runAttempts).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    eq(runAttempts.leaseToken, input.leaseToken),
    eq(runAttempts.leaseGeneration, input.leaseGeneration),
    inArray(runAttempts.status, ["leased", "running"]),
    gt(runAttempts.leaseExpiresAt, now()),
  )).limit(1))[0];
}

async function checkLease(db: RunQueryDb, input: LeaseInput): Promise<typeof runAttempts.$inferSelect> {
  const attempt = await findLiveLease(db, input);
  if (!attempt) throw new RunLeaseConflictError("stale or expired attempt lease");
  return attempt;
}

type LeaseWriter = { readonly writerLeaseGeneration: number | null; readonly writerLeaseTokenHash: string | null };
/** Worker-facing rows; the writer's lease identity is not returned. */
export type RunEventRow = Omit<typeof runEvents.$inferSelect, keyof LeaseWriter>;
export type RunArtifactRow = Omit<typeof runArtifacts.$inferSelect, keyof LeaseWriter>;

function leaseWriter(input: LeaseInput): { writerLeaseGeneration: number; writerLeaseTokenHash: string } {
  return { writerLeaseGeneration: input.leaseGeneration, writerLeaseTokenHash: createHash("sha256").update(input.leaseToken).digest("hex") };
}

/** Worker routes return these rows as JSON, so the writer's lease identity is dropped first. */
function withoutWriter<T extends LeaseWriter>(row: T): Omit<T, keyof LeaseWriter> {
  const copy: Record<string, unknown> = { ...row };
  delete copy.writerLeaseGeneration;
  delete copy.writerLeaseTokenHash;
  return copy as unknown as Omit<T, keyof LeaseWriter>;
}

/**
 * A request reuses an id (event externalId, artifact name) already stored for
 * the attempt. The stored row is the answer only when the caller is the lease
 * that wrote it (token hash and generation both match) and the request is
 * identical. That holds after the writer's lease expired, was cleared by its
 * own terminal event, or was replaced, so a retried terminal event stays
 * idempotent; nothing is written on this path. Any other caller gets a 409:
 * a content conflict if it holds the live lease, else a lease conflict, so a
 * stale caller learns nothing about the stored row. Rows with no recorded
 * writer match no caller.
 */
async function assertStoredRetry(db: RunQueryDb, stored: LeaseWriter, input: LeaseInput, identical: boolean, conflict: () => Error): Promise<void> {
  const writer = leaseWriter(input);
  const isWriter = stored.writerLeaseGeneration === writer.writerLeaseGeneration && stored.writerLeaseTokenHash === writer.writerLeaseTokenHash;
  if (isWriter && identical) return;
  if (isWriter || await findLiveLease(db, input)) throw conflict();
  throw new RunLeaseConflictError("stale or expired attempt lease");
}

async function lockAttempt(db: RunQueryDb, runId: string, attemptId: string): Promise<void> {
  await db.execute(sql`select id from run_attempts where id = ${attemptId} and run_id = ${runId} for update`);
}

async function lockRun(db: RunQueryDb, runId: string): Promise<void> {
  await db.execute(sql`select id from runs where id = ${runId} for update`);
}

async function nextSequence(db: RunQueryDb, runId: string): Promise<number> {
  const result = (await db.select({ max: sql<number>`coalesce(max(${runEvents.sequence}), 0)` }).from(runEvents).where(eq(runEvents.runId, runId)))[0];
  return Number(result?.max ?? 0) + 1;
}

export async function ingestRunEvent(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly externalId: string;
  readonly attemptSequence?: number;
  readonly kind: RunEventKind;
  readonly payload?: Record<string, unknown>;
}): Promise<RunEventRow> {
  const payload = input.payload ?? {};
  if (!input.externalId || input.externalId.length > 160) throw new RunPayloadTooLargeError("eventId is required and must be 160 characters or fewer");
  if (input.attemptSequence !== undefined && (!Number.isSafeInteger(input.attemptSequence) || input.attemptSequence < 0)) throw new RunPayloadTooLargeError("attempt sequence must be a non-negative integer");
  if (jsonByteLength(payload) > MAX_EVENT_PAYLOAD_BYTES) throw new RunPayloadTooLargeError("event payload exceeds 256 KiB");
  const db = cloudDb();
  // oxlint-disable-next-line complexity -- Run event ingestion keeps lease fencing, replay dedupe, journal sequencing, and terminal aggregation atomic.
  return db.transaction(async (tx) => {
    // Serialize journal allocation per Run so concurrent workers cannot both
    // observe the same max(sequence) and collide on the unique cursor index.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.runId}, 0))`);
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    {
      const stored = (await tx.select({
        event: runEvents,
        samePayload: sql<boolean>`${runEvents.payload} = ${JSON.stringify(payload)}::jsonb`,
      }).from(runEvents).where(and(
        eq(runEvents.runId, input.runId),
        eq(runEvents.attemptId, input.attemptId),
        eq(runEvents.externalId, input.externalId),
      )).limit(1))[0];
      if (stored) {
        const identical = stored.samePayload === true
          && stored.event.kind === input.kind
          && stored.event.attemptSequence === (input.attemptSequence ?? null);
        await assertStoredRetry(tx, stored.event, input, identical, () => new RunEventConflictError("event id already exists with a different event"));
        return withoutWriter(stored.event);
      }
    }
    await checkLease(tx, input);
    if (input.attemptSequence !== undefined) {
      const last = (await tx.select({ max: sql<number>`coalesce(max(${runEvents.attemptSequence}), -1)` }).from(runEvents).where(and(
        eq(runEvents.attemptId, input.attemptId),
      )))[0];
      if (input.attemptSequence <= Number(last?.max ?? -1)) throw new RunEventConflictError("event sequence is stale or reordered");
    }
    const sequence = await nextSequence(tx, input.runId);
    const event = (await tx.insert(runEvents).values({
      runId: input.runId,
      attemptId: input.attemptId,
      sequence,
      externalId: input.externalId,
      attemptSequence: input.attemptSequence ?? null,
      kind: input.kind,
      payload,
      ...leaseWriter(input),
    }).returning())[0];
    if (!event) throw new Error("event insert returned no row");
    const currentRun = (await tx.select({ status: runs.status }).from(runs).where(eq(runs.id, input.runId)).limit(1))[0];
    const requestedStatus: AttemptStatus | undefined = input.kind === "attempt.started" ? "running"
      : input.kind === "attempt.succeeded" ? "succeeded"
        : input.kind === "attempt.failed" ? "failed" : undefined;
    // A provider receipt can race the cancel request. Once the Run is
    // cancelling, the receipt is still journaled for replay but cannot
    // resurrect a successful/failed attempt or leave the Run stuck.
    const status: AttemptStatus | undefined = currentRun?.status === "cancelling"
      && (requestedStatus === "succeeded" || requestedStatus === "failed")
      ? "cancelled"
      : requestedStatus;
    const terminal = status === "succeeded" || status === "failed" || status === "cancelled";
    if (status) await tx.update(runAttempts).set({
      status,
      ...(typeof payload.providerVmId === "string" ? { providerVmId: payload.providerVmId } : {}),
      ...(terminal ? { finishedAt: now() } : { startedAt: status === "running" ? now() : undefined }),
      // Keep the lease token until the retention handoff consumes it. The
      // terminal row is no longer active because its expiry is cleared, while
      // retaining the token lets the worker fence its finally-block update
      // against a replacement lease.
      ...(terminal ? { leaseExpiresAt: null } : {}),
      ...(terminal ? { terminalRetainUntil: new Date(Date.now() + DEFAULT_TERMINAL_RETENTION_MS) } : {}),
      updatedAt: now(),
    }).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.leaseToken, input.leaseToken), eq(runAttempts.leaseGeneration, input.leaseGeneration)));
    if (terminal) {
      const active = await tx.select({ id: runAttempts.id }).from(runAttempts).where(and(
        eq(runAttempts.runId, input.runId),
        inArray(runAttempts.status, ["queued", "leased", "running"]),
      )).limit(1);
      if (active.length === 0) {
        const failed = await tx.select({ id: runAttempts.id }).from(runAttempts).where(and(eq(runAttempts.runId, input.runId), eq(runAttempts.status, "failed"))).limit(1);
        const finalStatus: RunStatus = currentRun?.status === "cancelling" ? "cancelled" : failed.length > 0 ? "failed" : "succeeded";
        await tx.update(runs).set({ status: finalStatus, completedAt: now(), updatedAt: now() }).where(eq(runs.id, input.runId));
        await tx.insert(runEvents).values({
          runId: input.runId,
          sequence: await nextSequence(tx, input.runId),
          externalId: "run-completed",
          kind: "run.completed",
          payload: { status: finalStatus },
        });
      }
    }
    return withoutWriter(event);
  });
}

export async function recordRunArtifact(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly name: string;
  readonly mediaType?: string;
  readonly sizeBytes: number;
  readonly digest: string;
  readonly uri: string;
  readonly metadata?: Record<string, unknown>;
  readonly bytes?: Uint8Array;
}): Promise<RunArtifactRow> {
  if (!/^[A-Za-z0-9._/-]{1,128}$/.test(input.name)) throw new RunArtifactConflictError("artifact name is invalid");
  if (!/^(artifact|run|s3|gs):\/\/[^\s]{1,512}$/.test(input.uri)) throw new RunArtifactConflictError("artifact uri is invalid");
  if (input.mediaType && !/^[\x20-\x7e]{1,128}$/.test(input.mediaType)) throw new RunArtifactConflictError("artifact media type is invalid");
  if (!Number.isSafeInteger(input.sizeBytes) || input.sizeBytes < 0 || input.sizeBytes > MAX_ARTIFACT_BYTES) throw new RunPayloadTooLargeError("artifact exceeds 512 MiB");
  if (input.bytes) {
    if (input.bytes.byteLength !== input.sizeBytes) throw new RunArtifactConflictError("artifact size does not match bytes");
    assertArtifactDigest(input.bytes, input.digest);
  }
  const db = cloudDb();
  return db.transaction(async (tx) => {
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const duplicate = (await tx.select().from(runArtifacts).where(and(eq(runArtifacts.attemptId, input.attemptId), eq(runArtifacts.name, input.name))).limit(1))[0];
    if (duplicate) {
      // The manifest is digest, size and URI; media type and metadata are not compared.
      const identical = duplicate.digest === input.digest && duplicate.sizeBytes === input.sizeBytes && duplicate.uri === input.uri;
      await assertStoredRetry(tx, duplicate, input, identical, () => new RunArtifactConflictError("artifact name already exists with different manifest"));
      return withoutWriter(duplicate);
    }
    await checkLease(tx, input);
    const artifact = (await tx.insert(runArtifacts).values({
      runId: input.runId,
      attemptId: input.attemptId,
      name: input.name,
      mediaType: input.mediaType ?? "application/octet-stream",
      sizeBytes: input.sizeBytes,
      digest: input.digest,
      uri: input.uri,
      metadata: input.metadata ?? {},
      ...leaseWriter(input),
    }).returning())[0];
    if (!artifact) throw new Error("artifact insert returned no row");
    await tx.insert(runEvents).values({
      runId: input.runId,
      attemptId: input.attemptId,
      sequence: await nextSequence(tx, input.runId),
      externalId: `artifact-${artifact.id}`,
      attemptSequence: null,
      kind: "attempt.artifact",
      payload: { artifactId: artifact.id, name: artifact.name, digest: artifact.digest, sizeBytes: artifact.sizeBytes },
      ...leaseWriter(input),
    });
    return withoutWriter(artifact);
  });
}

export async function cancelRun(runId: string, userId: string): Promise<RunSnapshot> {
  const db = cloudDb();
  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${runId}, 0))`);
    const run = (await tx.update(runs).set({ status: "cancelling", cancelRequestedAt: now(), updatedAt: now() }).where(and(
      eq(runs.id, runId), eq(runs.userId, userId), inArray(runs.status, ["queued", "running"]),
    )).returning())[0];
    if (!run) {
      const existing = (await tx.select().from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).limit(1))[0];
      if (!existing) throw new RunNotFoundError("run not found");
      return readSnapshot(tx, runId, userId);
    }
    await tx.update(runAttempts).set({ status: "cancelled", leaseToken: null, leaseExpiresAt: null, updatedAt: now() }).where(and(eq(runAttempts.runId, runId), eq(runAttempts.status, "queued")));
    const sequence = await nextSequence(tx, runId);
    await tx.insert(runEvents).values({ runId, sequence, externalId: `cancel-${runId}`, kind: "run.cancel_requested", payload: {} });
    const active = await tx.select({ id: runAttempts.id }).from(runAttempts).where(and(eq(runAttempts.runId, runId), inArray(runAttempts.status, ["leased", "running"]))).limit(1);
    if (active.length === 0) {
      await tx.update(runs).set({ status: "cancelled", completedAt: now(), updatedAt: now() }).where(eq(runs.id, runId));
      await tx.insert(runEvents).values({ runId, sequence: await nextSequence(tx, runId), externalId: `run-completed-${runId}`, kind: "run.completed", payload: { status: "cancelled" } });
    }
    return readSnapshot(tx, runId, userId);
  });
}

/** Active provider handles that a cancellation worker should close. */
export async function listActiveCloudVmAttempts(runId: string, userId: string) {
  const rows = await cloudDb().select({
    attempt: runAttempts,
    userId: runs.userId,
    billingTeamId: runs.billingTeamId,
  }).from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId)).where(and(
    eq(runAttempts.runId, runId),
    eq(runs.userId, userId),
    inArray(runAttempts.status, ["leased", "running"]),
  ));
  if (rows.length === 0) {
    const visible = await cloudDb().select({ id: runs.id }).from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).limit(1);
    if (visible.length === 0) throw new RunNotFoundError("run not found");
  }
  return rows;
}

/** Fence a cancelled worker and complete the Run when no active attempt remains. */
export async function finalizeAttemptCancellation(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken?: string | null;
  readonly leaseGeneration?: number | null;
}): Promise<typeof runAttempts.$inferSelect> {
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.runId}, 0))`);
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const current = (await tx.select().from(runAttempts).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).limit(1))[0];
    if (!current) throw new RunAttemptNotFoundError("attempt not found");
    const isActive = ["queued", "leased", "running"].includes(current.status);
    let attempt = current;
    if (isActive) {
      const conditions = [eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId)];
      if (input.leaseToken) conditions.push(eq(runAttempts.leaseToken, input.leaseToken));
      if (input.leaseGeneration !== undefined && input.leaseGeneration !== null) conditions.push(eq(runAttempts.leaseGeneration, input.leaseGeneration));
      attempt = (await tx.update(runAttempts).set({
        status: "cancelled",
        leaseToken: null,
        leaseExpiresAt: null,
        leaseGeneration: sql`${runAttempts.leaseGeneration} + 1`,
        finishedAt: now(),
        terminalRetainUntil: current.providerVmId ? new Date(Date.now() + DEFAULT_TERMINAL_RETENTION_MS) : null,
        updatedAt: now(),
      }).where(and(...conditions)).returning())[0] ?? current;
    }
    const active = await tx.select({ id: runAttempts.id }).from(runAttempts).where(and(
      eq(runAttempts.runId, input.runId),
      inArray(runAttempts.status, ["queued", "leased", "running"]),
    )).limit(1);
    if (active.length === 0) {
      const completed = (await tx.update(runs).set({ status: "cancelled", completedAt: now(), updatedAt: now() }).where(and(eq(runs.id, input.runId), eq(runs.status, "cancelling"))).returning())[0];
      if (completed) {
        await tx.insert(runEvents).values({
          runId: input.runId,
          sequence: await nextSequence(tx, input.runId),
          externalId: "run-completed",
          kind: "run.completed",
          payload: { status: "cancelled" },
        });
      }
    }
    return attempt;
  });
}

/** Final safety net for a cancellation request whose provider worker vanished. */
export async function forceFinalizeRunCancellation(runId: string, userId: string): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${runId}, 0))`);
    const run = (await tx.select({ status: runs.status }).from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).for("update").limit(1))[0];
    if (!run) throw new RunNotFoundError("run not found");
    if (run.status !== "cancelling") return;
    await tx.update(runAttempts).set({
      status: "cancelled",
      leaseToken: null,
      leaseExpiresAt: null,
      leaseGeneration: sql`${runAttempts.leaseGeneration} + 1`,
      finishedAt: now(),
      terminalRetainUntil: sql`case when ${runAttempts.providerVmId} is null then null else coalesce(${runAttempts.terminalRetainUntil}, now() + interval '10 minutes') end`,
      updatedAt: now(),
    }).where(and(eq(runAttempts.runId, runId), inArray(runAttempts.status, ["queued", "leased", "running"])));
    const completed = (await tx.update(runs).set({ status: "cancelled", completedAt: now(), updatedAt: now() }).where(and(eq(runs.id, runId), eq(runs.status, "cancelling"))).returning())[0];
    if (completed) {
      await tx.insert(runEvents).values({
        runId,
        sequence: await nextSequence(tx, runId),
        externalId: "run-completed",
        kind: "run.completed",
        payload: { status: "cancelled" },
      });
    }
  });
}

export type ExpiredAttemptCleanup = {
  readonly attempt: typeof runAttempts.$inferSelect;
  readonly userId: string;
  readonly billingTeamId: string | null;
  readonly cleanupLeaseToken: string;
};

/** Claim expired VM rows for a bounded provider reaper. Claims are recoverable. */
export async function claimExpiredAttemptCleanups(input: { readonly limit?: number; readonly now?: Date } = {}): Promise<ExpiredAttemptCleanup[]> {
  const nowAt = input.now ?? now();
  const limit = Math.max(1, Math.min(input.limit ?? 20, 100));
  return cloudDb().transaction(async (tx) => {
    const candidates = await tx.select({
      attempt: runAttempts,
      userId: runs.userId,
      billingTeamId: runs.billingTeamId,
    }).from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId))
      .leftJoin(cloudRuntimes, eq(cloudRuntimes.id, runAttempts.runtimeId)).where(and(
      inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
      isNotNull(runAttempts.providerVmId),
      // Every launched attempt has its own ephemeral runtime (dogfood.ts); a promoted attempt's VM
      // belongs to a persistent runtime now, so only that one is never reaped.
      or(isNull(runAttempts.runtimeId), eq(cloudRuntimes.runtimeKind, "ephemeral")),
      isNotNull(runAttempts.terminalRetainUntil),
      lte(runAttempts.terminalRetainUntil, nowAt),
      or(isNull(runAttempts.cleanupLeaseExpiresAt), lt(runAttempts.cleanupLeaseExpiresAt, nowAt)),
    )).orderBy(asc(runAttempts.terminalRetainUntil)).limit(limit).for("update", { of: runAttempts });
    const claimed: ExpiredAttemptCleanup[] = [];
    for (const candidate of candidates) {
      const token = randomUUID();
      const attempt = (await tx.update(runAttempts).set({
        cleanupLeaseToken: token,
        cleanupLeaseExpiresAt: new Date(nowAt.getTime() + TERMINAL_CLEANUP_LEASE_MS),
        updatedAt: nowAt,
      }).where(and(
        eq(runAttempts.id, candidate.attempt.id),
        or(isNull(runAttempts.cleanupLeaseExpiresAt), lt(runAttempts.cleanupLeaseExpiresAt, nowAt)),
      )).returning())[0];
      if (attempt) claimed.push({ attempt, userId: candidate.userId, billingTeamId: candidate.billingTeamId, cleanupLeaseToken: token });
    }
    return claimed;
  });
}

export async function finishAttemptCleanup(input: {
  readonly attemptId: string;
  readonly cleanupLeaseToken: string;
  readonly succeeded: boolean;
}): Promise<void> {
  await cloudDb().update(runAttempts).set(input.succeeded ? {
    providerVmId: null,
    providerWorkspaceId: null,
    providerTerminalId: null,
    terminalRetainUntil: null,
    cleanupLeaseToken: null,
    cleanupLeaseExpiresAt: null,
    updatedAt: now(),
  } : {
    cleanupLeaseToken: null,
    cleanupLeaseExpiresAt: null,
    updatedAt: now(),
  }).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.cleanupLeaseToken, input.cleanupLeaseToken)));
}

export async function waitForRun(runId: string, userId: string, waitMs = 0): Promise<RunSnapshot> {
  const deadline = Date.now() + Math.max(0, Math.min(waitMs, 10_000));
  for (;;) {
    const snapshot = await getRun(runId, userId);
    if (["succeeded", "failed", "cancelled"].includes(snapshot.run.status) || Date.now() >= deadline) return snapshot;
    await new Promise((resolve) => setTimeout(resolve, Math.min(250, Math.max(1, deadline - Date.now()))));
  }
}

// Promotion idempotency is persisted against the existing terminal attempt
// row; this re-export keeps the Run repository as the composition entrypoint
// without coupling its worker methods to the promotion route.
export { createRunAttemptPromotionStore } from "./promotionRepository";

