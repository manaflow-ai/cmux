import { eq, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { runEvents } from "../../../db/schema";
import { DEFAULT_TERMINAL_RETENTION_MS } from "../model";

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

export type RunQueryDb = Pick<ReturnType<typeof cloudDb>, "select" | "execute">;

export function now(): Date {
  return new Date();
}

/** Run event ids that start with this are the server's own; ingestion refuses them from workers. */
export const SERVER_EVENT_ID_PREFIX = "cmux:";

/** A sandboxed attempt keeps nothing to attach: its VM is due for destroy the moment it ends. */
export function terminalRetentionMs(environment: string | null | undefined): number {
  return environment === "sandboxed" ? 0 : DEFAULT_TERMINAL_RETENTION_MS;
}

export async function lockAttempt(db: RunQueryDb, runId: string, attemptId: string): Promise<void> {
  await db.execute(sql`select id from run_attempts where id = ${attemptId} and run_id = ${runId} for update`);
}

export async function lockRun(db: RunQueryDb, runId: string): Promise<void> {
  await db.execute(sql`select id from runs where id = ${runId} for update`);
}

export async function nextSequence(db: RunQueryDb, runId: string): Promise<number> {
  const result = (await db.select({ max: sql<number>`coalesce(max(${runEvents.sequence}), 0)` }).from(runEvents).where(eq(runEvents.runId, runId)))[0];
  return Number(result?.max ?? 0) + 1;
}
