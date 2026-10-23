import { randomUUID } from "node:crypto";
import { and, eq, sql } from "drizzle-orm";
import { closeCloudDbForTests, cloudDb } from "../../db/client";
import { cloudDbConfig } from "../../db/config";
import { runWithCloudDbQuerySignal } from "../../db/queryScope";
import { runs } from "../../db/schema";
import { createRunRecord, readRunSnapshot } from "../../services/runs/repository";
import { normalizeRunSpec, runSpecDigest } from "../../services/runs/spec";

/** Never serialize messages, stacks, SQL, parameters, connection options or causes. */
export function safeRunAdmissionError(error: unknown): Record<string, string> {
  const result: Record<string, string> = {};
  let current = error;
  const visited = new Set<unknown>();
  while (current && typeof current === "object" && !visited.has(current)) {
    visited.add(current);
    const fields = current as Record<string, unknown>;
    if (typeof fields.code === "string" && /^[0-9A-Z]{5}$/.test(fields.code)) result.sqlstate = fields.code;
    for (const key of ["constraint", "column", "table", "schema"] as const) {
      const value = typeof fields[key] === "string" ? fields[key] : fields[`${key}_name`];
      if (typeof value === "string" && /^[a-z_][a-z0-9_]{0,62}$/.test(value)) result[key] = value;
    }
    current = fields.cause;
  }
  return result;
}

export async function runAdmissionProbe(): Promise<boolean> {
  const nonce = randomUUID();
  const scope = { userId: `cmux-admission-probe-${nonce}`, ownerTeamId: `cmux-admission-probe-${nonce}` };
  const key = `probe-${nonce}`;
  const receipt: Record<string, unknown> = { schema: "cmux.run-admission-probe/v1", ok: false };
  let stage = "config";
  let admissionAttempted = false;
  const rollback = new Error("Admission probe rollback");
  try {
    receipt.driver = cloudDbConfig().driver;
    stage = "schema";
    // Metadata only: no customer rows, defaults, constraint expressions or URLs.
    receipt.columns = await runWithCloudDbQuerySignal(AbortSignal.timeout(30_000), () => cloudDb().execute(sql`
      select table_name, column_name, data_type, udt_name, is_nullable,
             column_default is not null as has_default
      from information_schema.columns
      where table_schema = 'public'
        and table_name in ('runs', 'run_attempts', 'run_events', 'run_artifacts')
      order by table_name, ordinal_position
    `));
    receipt.constraints = await runWithCloudDbQuerySignal(AbortSignal.timeout(30_000), () => cloudDb().execute(sql`
      select c.relname as table_name, con.conname as constraint_name, con.contype as constraint_type
      from pg_constraint con join pg_class c on c.oid = con.conrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname in ('runs', 'run_attempts', 'run_events', 'run_artifacts')
      order by c.relname, con.conname
    `));
    const digest = `sha256:${"b".repeat(64)}`;
    const spec = normalizeRunSpec({
      schema: "cmux.run/v1", operationId: key,
      source: { repository: "manaflow-ai/cmux", ref: "main", commit: "a".repeat(40), setupManifestDigest: digest },
      intent: { digest }, recipe: { id: "cloud-vm-dogfood", version: 1 },
      variants: [{ id: "probe", label: "Admission probe", instructionDigest: digest }],
      workspace: { kind: "ephemeral" }, routing: { executionProvider: "cloud-vm", backend: "freestyle" },
      capabilities: { secretRefs: [] }, checks: [],
      policy: { mode: "fanout", humanApprovalRequired: false, evidenceKinds: ["patch"] },
    });
    stage = "create";
    admissionAttempted = true;
    await runWithCloudDbQuerySignal(AbortSignal.timeout(30_000), () => cloudDb().transaction(async (tx) => {
      const created = await createRunRecord({ ...scope, billingTeamId: scope.ownerTeamId, idempotencyKey: key, requestDigest: runSpecDigest(spec), spec }, tx);
      receipt.runId = created.snapshot.run.id;
      stage = "snapshot";
      const snapshot = await readRunSnapshot(created.snapshot.run.id, scope, tx);
      if (!snapshot || snapshot.attempts.length !== 1 || snapshot.events.length !== 2
        || snapshot.events[0].kind !== "run.created" || snapshot.events[1].kind !== "attempt.queued"
        || snapshot.events[0].sequence !== 0 || snapshot.events[1].sequence !== 1) {
        throw new Error("Probe snapshot invariant failed");
      }
      receipt.attemptId = snapshot.attempts[0].id;
      receipt.events = snapshot.events.map(({ sequence, kind }) => ({ sequence, kind }));
      // Never commit a queued synthetic Run: global workers cannot observe it.
      throw rollback;
    }));
  } catch (error) {
    if (error === rollback) receipt.ok = true;
    else receipt.failure = { stage, ...safeRunAdmissionError(error) };
  } finally {
    try {
      // A separate transaction must confirm rollback; never delete a committed
      // row to disguise a visibility failure.
      const owned = and(eq(runs.ownerTeamId, scope.ownerTeamId), eq(runs.userId, scope.userId), eq(runs.idempotencyKey, key));
      const remaining = admissionAttempted
        ? await runWithCloudDbQuerySignal(AbortSignal.timeout(10_000), () => cloudDb().select({ id: runs.id }).from(runs).where(owned))
        : [];
      receipt.cleanup = { ok: remaining.length === 0, rolledBack: admissionAttempted && remaining.length === 0, verifiedAbsent: remaining.length === 0 };
      if (remaining.length > 0) receipt.ok = false;
    } catch (error) {
      receipt.ok = false;
      receipt.cleanup = { ok: false, ...safeRunAdmissionError(error) };
      // Synthetic scope is safe to retain so failed cleanup can be resumed.
      receipt.cleanupScope = { ...scope, idempotencyKey: key };
    }
    try {
      await closeCloudDbForTests();
    } catch (error) {
      receipt.ok = false;
      receipt.close = { ok: false, ...safeRunAdmissionError(error) };
    }
  }
  console.log(JSON.stringify(receipt, null, 2));
  return receipt.ok === true;
}

if ((import.meta as ImportMeta & { main?: boolean }).main) process.exitCode = await runAdmissionProbe() ? 0 : 1;
