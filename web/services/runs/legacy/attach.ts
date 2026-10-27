import { createHash, randomBytes } from "node:crypto";
import { and, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { runAttempts, runAttachTickets } from "../../../db/schema";
import { RunHttpError, runNotFound } from "./http";
import { readRunSnapshot, type RunScope } from "./repository";

const hash = (text: string) => createHash("sha256").update(text).digest("hex");
export async function runAttachTicket(input: RunScope & { runId: string; attemptId: string; ticket?: string; ttlMs?: number }) {
  const snapshot = await readRunSnapshot(input.runId, input);
  if (!snapshot) runNotFound();
  const attempt = snapshot.attempts.find(({ id }) => id === input.attemptId);
  if (!attempt || !attempt.providerVmId) runNotFound();
  if (attempt.cleanupState !== "retained" || (!attempt.promotedAt && (!attempt.retainedUntil || attempt.retainedUntil.getTime() <= Date.now()))) throw new RunHttpError(409, "run_not_attachable", "Attempt retention has expired");
  const providerVmId = attempt.providerVmId;
  const mint = !input.ticket;
  const ticket = input.ticket ?? randomBytes(32).toString("base64url");
  const ttlMs = Math.min(input.ttlMs ?? 30_000, 30_000);
  if (!Number.isSafeInteger(ttlMs) || ttlMs < 1000) throw new RunHttpError(400, "invalid_ticket_ttl", "Attach TTL must be between 1 and 30 seconds");
  const expiresAt = new Date(Math.min(Date.now() + ttlMs, attempt.promotedAt ? Infinity : attempt.retainedUntil!.getTime()));
  const result = await cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${input.runId}`},0))`);
    const [current] = await tx.select().from(runAttempts).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).for("update");
    if (!current || current.providerVmId !== providerVmId || current.cleanupState !== "retained" || (!current.promotedAt && (!current.retainedUntil || current.retainedUntil.getTime() <= Date.now()))) throw new RunHttpError(409, "run_not_attachable", "Attempt retention has expired");
    if (mint) {
      await tx.insert(runAttachTickets).values({ digest: hash(ticket), ...input, providerVmId, expiresAt });
      return { expiresAt };
    }
    const [redeemed] = await tx.update(runAttachTickets).set({ redeemedAt: new Date() }).where(and(eq(runAttachTickets.digest, hash(ticket)), eq(runAttachTickets.runId, input.runId), eq(runAttachTickets.attemptId, input.attemptId), eq(runAttachTickets.providerVmId, providerVmId), eq(runAttachTickets.ownerTeamId, input.ownerTeamId), eq(runAttachTickets.userId, input.userId), sql`${runAttachTickets.redeemedAt} is null`, sql`${runAttachTickets.expiresAt} > now()`)).returning({ expiresAt: runAttachTickets.expiresAt });
    if (!redeemed) throw new RunHttpError(410, "run_attach_ticket_expired", "Attach ticket is expired or already redeemed");
    return redeemed;
  });
  // The attach endpoint is the authority for the daemon/carrier session. A
  // Run attempt is not a workspace or terminal identity, so never synthesize
  // provider handles from the attempt UUID. Redemption returns only the VM
  // identity; the route then asks Cloud for a fresh, short-lived endpoint.
  return { ticket, runId: input.runId, attemptId: input.attemptId, provider: "cloud-vm", providerVmId, expiresAt: result.expiresAt.toISOString(), redeemed: !mint };
}
