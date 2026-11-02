import { randomBytes, createHash } from "node:crypto";
import { and, eq, gt, isNull } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { runAttempts, runs } from "../../../db/schema";
import { DEFAULT_ATTACH_TICKET_TTL_MS } from "../model";
import { lockAttempt, lockRun, now, RunAttachTargetUnavailableError, RunAttachTicketExpiredError, RunAttachTicketNotFoundError, RunAttachTicketReplayError, RunNotFoundError } from "./shared";

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
    const run = (await tx.select({ id: runs.id, provider: runs.provider, environment: runs.environment }).from(runs).where(and(eq(runs.id, input.runId), eq(runs.userId, input.userId))).limit(1))[0];
    const attempt = (await tx.select().from(runAttempts).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).limit(1))[0];
    if (!run || !attempt) throw new RunNotFoundError("run not found");
    // A sandboxed Run is never attachable: its retained handle only waits for the reaper's destroy.
    if (run.environment === "sandboxed") throw new RunAttachTargetUnavailableError("a sandboxed run has no attachable terminal");
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
    const run = (await tx.select({ id: runs.id, provider: runs.provider, environment: runs.environment }).from(runs).where(and(eq(runs.id, input.runId), eq(runs.userId, input.userId))).limit(1))[0];
    const attempt = (await tx.select().from(runAttempts).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).limit(1))[0];
    if (run?.environment === "sandboxed") throw new RunAttachTargetUnavailableError("a sandboxed run has no attachable terminal");
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
