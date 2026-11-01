import { createHash } from "node:crypto";
import { and, asc, eq, gt, inArray, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { runArtifacts, runAttempts, runEvents, runs } from "../../../db/schema";
import {
  MAX_ARTIFACT_BYTES,
  MAX_EVENT_PAYLOAD_BYTES,
  assertArtifactDigest,
  isArtifactDigest,
  jsonByteLength,
  SANDBOX_HANDOFF_GRACE_MS,
  type AttemptStatus,
  type RunEnvironment,
  type RunEventKind,
  type RunStatus,
} from "../model";
import { redactReceiptText, SANDBOX_SCRUBBED_FROM_KEY, sandboxPayloadDigest } from "../sandbox";
import { lockAttempt, lockRun, nextSequence, now, RunArtifactConflictError, RunEventConflictError, RunLeaseConflictError, RunNotFoundError, RunPayloadTooLargeError, type RunQueryDb, SERVER_EVENT_ID_PREFIX, terminalRetentionMs } from "./shared";
import { sandboxAttemptHandles } from "./sandboxVms";
import { checkLease, findLiveLease, type LeaseInput } from "./lease";

export async function listRunEvents(input: {
  readonly runId: string;
  readonly userId: string;
  readonly afterSequence?: number;
  readonly limit?: number;
}): Promise<{
  readonly events: (typeof runEvents.$inferSelect)[];
  readonly nextSequence: number | null;
  readonly environment: RunEnvironment;
  /** A sandboxed Run's provider handles, for redacting them out of event text as served. */
  readonly handles: readonly string[];
}> {
  // One snapshot: a handle is recorded before any event can name it, and cleanup clears handles in
  // the transaction that scrubs them out of events, so every handle a served event names is listed.
  return cloudDb().transaction(async (db) => {
    const run = (await db.select({ id: runs.id, userId: runs.userId, billingTeamId: runs.billingTeamId, environment: runs.environment })
      .from(runs).where(and(eq(runs.id, input.runId), eq(runs.userId, input.userId))).limit(1))[0];
    if (!run) throw new RunNotFoundError("run not found");
    const limit = Math.max(1, Math.min(input.limit ?? 100, 500));
    const rows = await db.select().from(runEvents).where(and(
      eq(runEvents.runId, input.runId),
      gt(runEvents.sequence, input.afterSequence ?? 0),
    )).orderBy(asc(runEvents.sequence)).limit(limit + 1);
    const events = rows.slice(0, limit);
    const handles: string[] = [];
    if (run.environment === "sandboxed") {
      const attempts = await db.select({ id: runAttempts.id, providerVmId: runAttempts.providerVmId, providerWorkspaceId: runAttempts.providerWorkspaceId, providerTerminalId: runAttempts.providerTerminalId })
        .from(runAttempts).where(eq(runAttempts.runId, run.id));
      for (const attempt of attempts) handles.push(...await sandboxAttemptHandles(db, run, attempt));
    }
    return { events, nextSequence: rows.length > limit ? events.at(-1)?.sequence ?? null : null, environment: (run.environment ?? "persistent") as RunEnvironment, handles };
  }, { isolationLevel: "repeatable read", accessMode: "read only" });
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
  // The server's own bookkeeping events (the sandbox sweep and adoption) use ids no worker may take.
  if (input.externalId.startsWith(SERVER_EVENT_ID_PREFIX)) throw new RunEventConflictError("eventId may not start with the server's reserved prefix");
  if (Object.hasOwn(payload, SANDBOX_SCRUBBED_FROM_KEY)) throw new RunEventConflictError(`payload key ${SANDBOX_SCRUBBED_FROM_KEY} is reserved for the server`);
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
        // Cleanup scrubs a sandbox's handles out of its stored events and records what the worker
        // sent, so the worker's retry of an event it sent before cleanup still matches.
        const samePayload = stored.samePayload === true || stored.event.payload[SANDBOX_SCRUBBED_FROM_KEY] === sandboxPayloadDigest(payload);
        const identical = samePayload
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
    const currentRun = (await tx.select({ status: runs.status, environment: runs.environment }).from(runs).where(eq(runs.id, input.runId)).limit(1))[0];
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
      // A sandbox's own terminal event leaves its launcher a short window to record the outcome
      // and hand the VM over (which makes it due at once); past it the reaper takes it anyway.
      ...(terminal ? { terminalRetainUntil: new Date(Date.now() + (currentRun?.environment === "sandboxed" ? SANDBOX_HANDOFF_GRACE_MS : terminalRetentionMs(currentRun?.environment))) } : {}),
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
    const eventName = await artifactEventName(tx, input);
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
      payload: { artifactId: artifact.id, name: eventName, digest: artifact.digest, sizeBytes: artifact.sizeBytes },
      ...leaseWriter(input),
    });
    return withoutWriter(artifact);
  });
}

/**
 * The name an artifact's event shows: as given for a persistent Run; for a sandboxed Run, redacted
 * like its receipt (token shapes and the attempt's own handles), since events are served as stored.
 */
async function artifactEventName(tx: RunQueryDb, input: { readonly runId: string; readonly attemptId: string; readonly name: string; readonly digest: string }): Promise<string> {
  const row = (await tx.select({ attempt: runAttempts, run: runs })
    .from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId)).where(eq(runAttempts.id, input.attemptId)).limit(1))[0];
  if (row?.run.environment !== "sandboxed") return input.name;
  // A sandbox's receipt serves the digest as is, so it must be one.
  if (!isArtifactDigest(input.digest)) throw new RunArtifactConflictError("artifact digest is invalid");
  return redactReceiptText(input.name, await sandboxAttemptHandles(tx, row.run, row.attempt));
}
