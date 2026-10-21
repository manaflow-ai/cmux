import { randomUUID, createHash } from "node:crypto";
import * as Effect from "effect/Effect";
import { and, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { runAttempts } from "../../db/schema";
import { runCloudClient, type RunCloudClient } from "./cloudClient";
import { RUN_CLOUD_CREATE_PENDING_LIMIT_MS, RunCloudOperationPending, runCloudCreatePendingExpired } from "./cloudClientContract";
import { claimNextRunAttempt, renewRunAttemptLease, checkpointRunAttempt, finishRunAttempt, cancelClaimedRunAttempt, reconcileCancelledRunAttempts, type ClaimedRunAttempt } from "./worker";
import { normalizeRunSpec } from "./spec";
import { parseSourceVerificationReceipt, sourceVerificationCommand } from "./sourceVerification";
import { storeRunArtifact } from "./repository";
import { withVariantExecution } from "./agentCommand";
import { labelRunStage, runFailureDetail } from "./failureStage";

const LEASE_MS = 90_000;
const quote = (text: string) => `'${text.replace(/'/g, `'"'"'`)}'`;
class RunInterrupted extends Error {}
class RunPending extends Error {}

async function checkpoint(attempt: ClaimedRunAttempt, value: Record<string, unknown>, providerVmId?: string) {
  const changed = await checkpointRunAttempt({ ...attempt, checkpoint: value, providerVmId });
  if (!changed) throw new RunInterrupted("Run lease lost or cancellation requested");
}

/** Remote receipt file and flock prevent a reclaimed lease from executing the
 * same task twice. An interrupted nonzero command requires a new attempt. */
export function replaySafeGuestCommand(attemptId: string, script: string): string {
  if (!/^[0-9a-f-]{36}$/i.test(attemptId)) throw new Error("Invalid attempt identity");
  const dir = `/tmp/cmux-attempt-${attemptId}`;
  const inner = [
    `if [ -f ${quote(`${dir}/completed`)} ]; then cat ${quote(`${dir}/completed`)}; exit 0; fi`,
    `if [ -f ${quote(`${dir}/started`)} ]; then echo 'cmux-attempt-interrupted' >&2; exit 76; fi`,
    `touch ${quote(`${dir}/started`)}`,
    `bash -se >${quote(`${dir}/receipt.tmp`)} 2>${quote(`${dir}/stderr`)} <<'CMUX_RUN_SCRIPT'`,
    script,
    "CMUX_RUN_SCRIPT",
    `code=$?; if [ "$code" != 0 ]; then exit "$code"; fi`,
    `mv ${quote(`${dir}/receipt.tmp`)} ${quote(`${dir}/completed`)}`,
    `cat ${quote(`${dir}/completed`)}`,
  ].join("\n");
  return `umask 077\nmkdir -p ${quote(dir)}\nflock -n -E 75 ${quote(`${dir}/lock`)} bash -c ${quote(inner)}`;
}

async function executeClaim(attempt: ClaimedRunAttempt, client: RunCloudClient) {
  const spec = normalizeRunSpec(attempt.spec);
  let providerVmId = typeof attempt.checkpoint?.providerVmId === "string" ? attempt.checkpoint.providerVmId : undefined;
  if (!providerVmId) {
    const vm = await labelRunStage("vm-create", () => client("POST", "/api/vm", { provider: "freestyle", displayName: `run-${attempt.runId.slice(0, 8)}-${attempt.ordinal}` }, `run:${attempt.runId}:attempt:${attempt.attemptId}`));
    if (typeof vm.id !== "string") throw new RunPending("VM provisioning has not returned an identity");
    providerVmId = vm.id;
    try {
      await labelRunStage("checkpoint", () => checkpoint(attempt, { providerVmId, provider: "freestyle", imageVersion: vm.imageVersion }, providerVmId));
    } catch (error) {
      // A cancellation or lease loss can fence the checkpoint immediately
      // after create returns. Remove that just-created VM while its identity
      // is still local; otherwise the durable cleanup query cannot discover
      // an allocation that never made it into the attempt row.
      await client("DELETE", `/api/vm/${encodeURIComponent(providerVmId)}`).catch(() => undefined);
      throw error;
    }
  }
  const marker = `${attempt.runId}:${attempt.attemptId}:completed`;
  const source = sourceVerificationCommand(spec, marker);
  const instruction = spec.variants[attempt.ordinal]?.instruction;
  // Source/setup verifier owns the workspace and inserts the optional recipe
  // before its final receipt; no deployment token is passed to guest commands.
  const script = withVariantExecution(source, instruction, attempt.attemptId);
  const command = replaySafeGuestCommand(attempt.attemptId, script);
  const response = await labelRunStage("guest-command", () => client("POST", `/api/vm/${encodeURIComponent(providerVmId)}/exec`, { command, timeoutMs: spec.resources.wallTimeoutMs }));
  if (response.exitCode === 75) throw new RunPending("Guest command remains active");
  if (response.exitCode !== 0 || typeof response.stdout !== "string") {
    // Exit 0 without stdout is still a failure; only a nonzero code is named.
    throw Object.assign(new Error("Guest source/setup or recipe failed"), { runStage: "guest-command", ...(response.exitCode !== 0 ? { exitCode: response.exitCode } : {}) });
  }
  const stdout = response.stdout;
  const sourceReceipt = await labelRunStage("source-receipt", async () => parseSourceVerificationReceipt(stdout, spec));
  if (!stdout.includes(`cmux-run:${marker}`)) throw Object.assign(new Error("Run completion marker missing"), { runStage: "completion-marker" });
  const result = { sourceReceipt, commandReceipt: { commandDigest: `sha256:${createHash("sha256").update(command).digest("hex")}`, stdout: `cmux-run:${marker}\n` } };
  await labelRunStage("artifact", () => storeRunArtifact({ runId: attempt.runId, attemptId: attempt.attemptId, name: "execution-receipt", payload: result }));
  return { providerVmId, result, retainMs: spec.resources.retainMs };
}

async function processClaim(attempt: ClaimedRunAttempt): Promise<string> {
  // Renew before opening the owner's session: that setup has no timeout of
  // its own, and failClaim can only record 'failed' under a live lease.
  let lost = false;
  let renewing = false;
  const timer = setInterval(() => {
    if (renewing) return;
    renewing = true;
    void renewRunAttemptLease({ ...attempt, leaseMs: LEASE_MS }).then((ok) => { if (!ok) lost = true; }).catch(() => { lost = true; }).finally(() => { renewing = false; });
  }, 20_000);
  try {
    // Every failure after the claim, including opening the owner's session,
    // must end the attempt. An escaped throw left it 'running', and each later
    // cron claim failed the same way, so the Run never ended.
    let client: RunCloudClient;
    try {
      if (!attempt.ownerTeamId) throw new Error("Queued Run lacks an immutable owner");
      client = await runCloudClient(attempt.userId, attempt.ownerTeamId);
    } catch (error) {
      return await failClaim(attempt, `Run worker could not open the owner's Cloud session${sessionSetupStage(error)}`);
    }
    const executed = await executeClaim(attempt, client);
    if (lost) throw new RunInterrupted("Run lease lost");
    let cleanupState = "retained";
    let retainedUntil: Date | null = new Date(Date.now() + executed.retainMs);
    if (!executed.retainMs) {
      await client("DELETE", `/api/vm/${encodeURIComponent(executed.providerVmId)}`);
      cleanupState = "deleted";
      retainedUntil = null;
    }
    const applied = await finishRunAttempt({ ...attempt, status: "succeeded", ...executed, cleanupState, retainedUntil });
    return applied ? "succeeded" : "fenced";
  } catch (error) {
    // VM create answers 409 while the same idempotent provider operation is
    // still running in the Cloud control plane. Leave the attempt running so
    // its lease expires and the next cron turn retries the same key; a generic
    // failure here would strand the Run even though the create may succeed.
    // A create whose continuation died answers 409 forever, so stop once no
    // live create can still be running and free the Run's concurrency slot.
    if (error instanceof RunCloudOperationPending) {
      if (!runCloudCreatePendingExpired({ startedAt: attempt.startedAt })) return "pending";
      return await failClaim(attempt, `Cloud VM create did not finish within ${RUN_CLOUD_CREATE_PENDING_LIMIT_MS / 60_000} minutes`);
    }
    if (error instanceof RunPending) return "pending";
    return await failClaim(attempt, `Run source/setup, recipe, or Cloud operation failed${runFailureDetail(error)}`);
  } finally {
    clearInterval(timer);
  }
}

const SESSION_SETUP_STAGES = new Set(["owner-lookup", "session-create", "session-tokens", "cloud-origin"]);

/** Only a known stage label, never the provider's message, joins the receipt. */
function sessionSetupStage(error: unknown): string {
  const stage = error instanceof Error ? (error as { stage?: unknown }).stage : undefined;
  return typeof stage === "string" && SESSION_SETUP_STAGES.has(stage) ? ` (${stage})` : "";
}

/** Raw provider/database errors must never enter durable receipts. */
async function failClaim(attempt: ClaimedRunAttempt, error: string): Promise<string> {
  const applied = await finishRunAttempt({ ...attempt, status: "failed", error });
  if (!applied) await cancelClaimedRunAttempt(attempt);
  return applied ? "failed" : "fenced";
}

/** Protected cron is the durable trigger; after() only reduces first-run latency. */
export async function processRunQueue(filter: { runId?: string; ownerTeamId?: string } = {}) {
  const workerId = `cloud-run-${randomUUID()}`;
  const program = Effect.tryPromise(async () => {
    await reconcileCancelledRunAttempts({ limit: 8 });
    await cleanupRunMachines();
    // At most two concurrent remote attempts; total invocation duration stays
    // inside one attempt budget. Database admission also enforces each Run cap.
    const results = await Promise.all([0, 1].map(async () => {
      const attempt = await claimNextRunAttempt({ ...filter, workerId, leaseMs: LEASE_MS });
      return attempt ? processClaim(attempt) : "idle";
    }));
    await cleanupRunMachines();
    return { ok: true, results };
  });
  return Effect.runPromise(program);
}

export async function cleanupRunMachines(): Promise<number> {
  const rows = await cloudDb().execute(sql`
    select a.id::text, a.run_id::text, a.provider_vm_id, r.user_id, r.owner_team_id
    from run_attempts a join runs r on r.id=a.run_id
    where a.provider_vm_id is not null and a.promoted_at is null
      and (a.status in ('failed','cancelled') or (a.status='succeeded' and a.retained_until <= now()))
      and a.cleanup_state <> 'deleted'
      and (a.cleanup_state <> 'cleaning' or a.updated_at < now()-interval '5 minutes')
    order by a.updated_at limit 8
  `) as readonly Record<string, unknown>[];
  let deleted = 0;
  for (const row of rows) {
    const claimed = await cloudDb().transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${row.run_id}`},0))`);
      return await tx.update(runAttempts).set({ cleanupState: "cleaning", updatedAt: new Date() }).where(and(eq(runAttempts.id, String(row.id)), sql`${runAttempts.promotedAt} is null`, sql`${runAttempts.cleanupState} <> 'deleted'`, sql`(${runAttempts.cleanupState} <> 'cleaning' or ${runAttempts.updatedAt} < now()-interval '5 minutes')`)).returning({ id: runAttempts.id });
    });
    if (!claimed.length || typeof row.owner_team_id !== "string") continue;
    try {
      const client = await runCloudClient(String(row.user_id), row.owner_team_id);
      await client("DELETE", `/api/vm/${encodeURIComponent(String(row.provider_vm_id))}`);
      await cloudDb().update(runAttempts).set({ cleanupState: "deleted", updatedAt: new Date() }).where(eq(runAttempts.id, String(row.id)));
      await storeRunArtifact({ runId: String(row.run_id), attemptId: String(row.id), name: "cleanup-receipt", payload: { providerVmId: row.provider_vm_id, deleted: true } });
      deleted++;
    } catch {
      await cloudDb().update(runAttempts).set({ cleanupState: "failed", updatedAt: new Date() }).where(eq(runAttempts.id, String(row.id)));
      console.error("Run cleanup failed", { attemptId: row.id });
    }
  }
  return deleted;
}
