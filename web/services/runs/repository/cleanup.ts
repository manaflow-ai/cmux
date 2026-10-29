import { randomUUID } from "node:crypto";
import { and, asc, eq, inArray, isNotNull, isNull, lt, lte, or, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { cloudRuntimes, runArtifacts, runAttempts, runEvents, runs } from "../../../db/schema";
import { TERMINAL_CLEANUP_LEASE_MS } from "../model";
import { redactReceiptText, redactReceiptValue, SANDBOX_HANDLE_KEYS, SANDBOX_SCRUBBED_FROM_KEY, sandboxPayloadDigest } from "../sandbox";
import { lockAttempt, lockRun, now } from "./shared";
import { sandboxAttemptHandles } from "./sandboxVms";

export type ExpiredAttemptCleanup = {
  readonly attempt: typeof runAttempts.$inferSelect;
  readonly userId: string;
  readonly billingTeamId: string | null;
  readonly environment: string;
  readonly cleanupLeaseToken: string;
};

/** Claim expired VM rows for a bounded provider reaper. Claims are recoverable. */
export async function claimExpiredAttemptCleanups(input: { readonly limit?: number; readonly now?: Date; readonly runId?: string } = {}): Promise<ExpiredAttemptCleanup[]> {
  const nowAt = input.now ?? now();
  const limit = Math.max(1, Math.min(input.limit ?? 20, 100));
  return cloudDb().transaction(async (tx) => {
    const candidates = await tx.select({
      attempt: runAttempts,
      userId: runs.userId,
      billingTeamId: runs.billingTeamId,
      environment: runs.environment,
    }).from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId))
      .leftJoin(cloudRuntimes, eq(cloudRuntimes.id, runAttempts.runtimeId)).where(and(
      inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
      isNotNull(runAttempts.providerVmId),
      ...(input.runId ? [eq(runAttempts.runId, input.runId)] : []),
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
        // Once the reaper owns a sandbox's VM its receipt is final, whatever the destroy does.
        ...(candidate.environment === "sandboxed" ? { leaseToken: null } : {}),
        updatedAt: nowAt,
      }).where(and(
        eq(runAttempts.id, candidate.attempt.id),
        or(isNull(runAttempts.cleanupLeaseExpiresAt), lt(runAttempts.cleanupLeaseExpiresAt, nowAt)),
      )).returning())[0];
      if (attempt) claimed.push({ attempt, userId: candidate.userId, billingTeamId: candidate.billingTeamId, environment: candidate.environment, cleanupLeaseToken: token });
    }
    return claimed;
  });
}

/**
 * Before cleanup clears a sandbox attempt's provider handles, take them out of every stored text
 * that could name them (the receipt's reply, the attempt's error, artifact names), so nothing
 * stored needs the handles again and the handles themselves are kept nowhere.
 */

/** An event payload with every handle-named value and every handle in its text replaced. */
function scrubEventPayload(value: unknown, handles: readonly string[]): Record<string, unknown> {
  const scrub = (item: unknown, key?: string): unknown => {
    if (key && SANDBOX_HANDLE_KEYS.has(key) && item != null) return "[redacted]";
    if (typeof item === "string") return handles.reduce((text, handle) => text.split(handle).join("[redacted]"), item);
    if (Array.isArray(item)) return item.map((child) => scrub(child));
    if (item && typeof item === "object") return Object.fromEntries(Object.entries(item).map(([childKey, child]) => [childKey, scrub(child, childKey)]));
    return item;
  };
  return (scrub(value ?? {}) ?? {}) as Record<string, unknown>;
}

async function scrubSandboxHandles(attemptId: string, cleanupLeaseToken: string): Promise<void> {
  const runId = (await cloudDb().select({ runId: runAttempts.runId }).from(runAttempts).where(eq(runAttempts.id, attemptId)).limit(1))[0]?.runId;
  if (!runId) return;
  await cloudDb().transaction(async (tx) => {
    // The same lock order as event ingestion and the outcome write: advisory, run, attempt.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${runId}, 0))`);
    await lockRun(tx, runId);
    await lockAttempt(tx, runId, attemptId);
    const row = (await tx.select({ attempt: runAttempts, run: runs }).from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId)).where(and(
      eq(runAttempts.id, attemptId),
      eq(runAttempts.cleanupLeaseToken, cleanupLeaseToken),
      eq(runs.environment, "sandboxed"),
    )).limit(1))[0];
    if (!row) return;
    const handles = await sandboxAttemptHandles(tx, row.run, row.attempt);
    if (handles.length === 0) return;
    const receipt = row.run.receipt;
    if (receipt) {
      const scrub = (value: unknown) => (typeof value === "string" ? redactReceiptText(value, handles) : value ?? null);
      await tx.update(runs).set({ receipt: { ...receipt, reply: scrub(receipt.reply), error: scrub(receipt.error) } }).where(eq(runs.id, row.run.id));
    }
    if (row.attempt.error) {
      await tx.update(runAttempts).set({ error: redactReceiptText(row.attempt.error, handles) }).where(eq(runAttempts.id, attemptId));
    }
    // The Run journal names handles too (a started event's providerVmId, an adoption's). Their
    // values become `[redacted]`: the keys stay, so "this attempt had a VM" still reads the same.
    for (const event of await tx.select({ id: runEvents.id, payload: runEvents.payload }).from(runEvents).where(eq(runEvents.attemptId, attemptId))) {
      const payload = scrubEventPayload(event.payload, handles);
      if (JSON.stringify(payload) !== JSON.stringify(event.payload)) {
        // The first scrub records the payload as sent, so the worker's retry of it still matches.
        const scrubbedFrom = event.payload?.[SANDBOX_SCRUBBED_FROM_KEY] ?? sandboxPayloadDigest(event.payload);
        await tx.update(runEvents).set({ payload: { ...payload, [SANDBOX_SCRUBBED_FROM_KEY]: scrubbedFrom } }).where(eq(runEvents.id, event.id));
      }
    }
    if (row.run.error) {
      await tx.update(runs).set({ error: redactReceiptText(row.run.error, handles) }).where(eq(runs.id, row.run.id));
    }
    for (const artifact of await tx.select({ id: runArtifacts.id, name: runArtifacts.name, mediaType: runArtifacts.mediaType, uri: runArtifacts.uri, metadata: runArtifacts.metadata }).from(runArtifacts).where(eq(runArtifacts.attemptId, attemptId))) {
      const scrubbed = redactReceiptText(artifact.name, handles);
      // Names are unique per attempt: a scrubbed name that collides keeps a suffix from the id.
      const name = scrubbed === artifact.name ? scrubbed : `${scrubbed}~${artifact.id.slice(0, 8)}`;
      const mediaType = redactReceiptText(artifact.mediaType, handles) === artifact.mediaType ? artifact.mediaType : "application/octet-stream";
      const uri = redactReceiptText(artifact.uri, handles);
      const metadata = redactReceiptValue(artifact.metadata, handles) as Record<string, unknown>;
      const metadataChanged = JSON.stringify(metadata) !== JSON.stringify(artifact.metadata);
      if (name !== artifact.name || mediaType !== artifact.mediaType || uri !== artifact.uri || metadataChanged) {
        await tx.update(runArtifacts).set({ name, mediaType, uri, metadata }).where(eq(runArtifacts.id, artifact.id));
      }
      // The artifact's event carries a copy of its name: it ends up the same as the row's.
      await tx.update(runEvents).set({ payload: sql`jsonb_set(${runEvents.payload}, '{name}', ${JSON.stringify(name)}::jsonb)` }).where(and(
        eq(runEvents.attemptId, attemptId),
        eq(runEvents.externalId, `artifact-${artifact.id}`),
        sql`${runEvents.payload}->>'name' is distinct from ${name}`,
      ));
    }
  });
}

export async function finishAttemptCleanup(input: {
  readonly attemptId: string;
  readonly cleanupLeaseToken: string;
  readonly succeeded: boolean;
}): Promise<void> {
  if (input.succeeded) await scrubSandboxHandles(input.attemptId, input.cleanupLeaseToken);
  await cloudDb().update(runAttempts).set(input.succeeded ? {
    providerVmId: null,
    providerWorkspaceId: null,
    providerTerminalId: null,
    // Nothing writes for this attempt after its VM is gone (a late sandbox outcome is fenced on it).
    leaseToken: null,
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

/** Keep a cleanup obligation but retry it later, so one row that can't be destroyed now doesn't head every batch. */
export async function deferAttemptCleanup(input: { readonly attemptId: string; readonly cleanupLeaseToken: string; readonly delayMs: number }): Promise<void> {
  await cloudDb().update(runAttempts).set({
    // The reaper owned the VM: the launcher's lease writes nothing more, deferred or not.
    leaseToken: null,
    terminalRetainUntil: new Date(Date.now() + input.delayMs),
    cleanupLeaseToken: null,
    cleanupLeaseExpiresAt: null,
    updatedAt: now(),
  }).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.cleanupLeaseToken, input.cleanupLeaseToken)));
}
