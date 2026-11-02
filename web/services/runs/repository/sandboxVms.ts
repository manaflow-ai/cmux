import { and, eq, isNotNull, ne, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { cloudVms, runAttempts, runs } from "../../../db/schema";
import { SANDBOX_VM_DESTROY_CONFIRMED_KEY, SANDBOX_VM_MARKER_KEY, sandboxVmIdempotencyKey } from "../model";
import type { RunQueryDb } from "./shared";

/**
 * Every handle a sandbox attempt's text could name: the ones journaled on the attempt and the
 * provider id of any VM row under its key (a launcher that died before journaling it still
 * made one).
 */
export async function sandboxAttemptHandles(
  db: RunQueryDb,
  run: Pick<typeof runs.$inferSelect, "id" | "userId" | "billingTeamId">,
  attempt: Pick<typeof runAttempts.$inferSelect, "id" | "providerVmId" | "providerWorkspaceId" | "providerTerminalId">,
): Promise<string[]> {
  const journaled = [attempt.providerVmId, attempt.providerWorkspaceId, attempt.providerTerminalId].filter((handle): handle is string => !!handle);
  if (!run.billingTeamId) return journaled;
  const key = sandboxVmIdempotencyKey(run.id, attempt.id);
  const vms = await db.select({ providerVmId: cloudVms.providerVmId }).from(cloudVms).where(and(
    eq(cloudVms.billingTeamId, run.billingTeamId),
    eq(cloudVms.userId, run.userId),
    eq(cloudVms.idempotencyKey, key),
    sql`${cloudVms.providerMetadata}->>${SANDBOX_VM_MARKER_KEY} = ${key}`,
    isNotNull(cloudVms.providerVmId),
  )).limit(4);
  return [...journaled, ...vms.flatMap((vm) => (vm.providerVmId ? [vm.providerVmId] : []))];
}

/** Whether any Cloud VM row still holds this provider VM (unscoped: the reaper's own scope may not reach it). */
export async function cloudVmRowLive(providerVmId: string): Promise<boolean> {
  const rows = await cloudDb().select({ id: cloudVms.id }).from(cloudVms).where(and(
    eq(cloudVms.providerVmId, providerVmId),
    ne(cloudVms.status, "destroyed"),
  )).limit(1);
  return rows.length > 0;
}

/**
 * Whether this provider VM is the sandbox VM the launcher created for this attempt: a row with
 * the attempt's own create key, its server-set marker and the Run's user. A provider VM id that
 * only came from a worker's event matches no such row, so the reaper never destroys it unscoped.
 */
export async function sandboxVmOwnedByAttempt(input: { readonly providerVmId: string; readonly runId: string; readonly attemptId: string; readonly userId: string }): Promise<boolean> {
  const key = sandboxVmIdempotencyKey(input.runId, input.attemptId);
  const rows = await cloudDb().select({ id: cloudVms.id }).from(cloudVms).where(and(
    eq(cloudVms.providerVmId, input.providerVmId),
    eq(cloudVms.userId, input.userId),
    eq(cloudVms.idempotencyKey, key),
    sql`${cloudVms.providerMetadata}->>${SANDBOX_VM_MARKER_KEY} = ${key}`,
  )).limit(1);
  return rows.length > 0;
}

export function sandboxVmUnconfirmed() {
  return sql`${cloudVms.providerMetadata}->>${SANDBOX_VM_DESTROY_CONFIRMED_KEY} is null`;
}

/** Record that a strict destroy confirmed the sandbox VM is gone, so the orphan sweep stops looking for it. */
export async function confirmSandboxVmDestroyed(providerVmId: string, nowAt = new Date()): Promise<void> {
  await cloudDb().update(cloudVms).set({
    // The first confirmation stands: a retried cleanup never moves the end of the VM's time.
    providerMetadata: sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) || jsonb_build_object(${SANDBOX_VM_DESTROY_CONFIRMED_KEY}::text, coalesce(${cloudVms.providerMetadata}->>${SANDBOX_VM_DESTROY_CONFIRMED_KEY}, ${nowAt.toISOString()}::text))`,
  }).where(and(
    eq(cloudVms.providerVmId, providerVmId),
    sql`${cloudVms.providerMetadata}->>${SANDBOX_VM_MARKER_KEY} = ${cloudVms.idempotencyKey}`,
  ));
}
