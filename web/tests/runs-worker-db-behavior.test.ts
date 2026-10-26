import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const NOW = new Date("2026-10-18T06:00:00.000Z");
type TestSql = ((strings: TemplateStringsArray, ...values: unknown[]) => Promise<unknown[]>) & { end(options?: { timeout?: number }): Promise<void>; json(value: unknown): unknown };
type WorkerModule = typeof import("../services/runs/worker");
let sqlClient: TestSql | null = null;
let worker: Pick<WorkerModule, "cancelClaimedRunAttempt" | "cancelRun" | "claimNextRunAttempt" | "finishRunAttempt"> | null = null;
const cleanupRunIds: string[] = [];

function database(): TestSql {
  if (!sqlClient) throw new Error("database test is not initialized");
  return sqlClient;
}

function requiredWorker(): NonNullable<typeof worker> {
  if (!worker) throw new Error("worker module not initialized");
  return worker;
}

async function fixture(input: { readonly attempts?: number; readonly maxConcurrent?: number }): Promise<{ runId: string; attemptIds: string[] }> {
  const db = database();
  const runId = randomUUID();
  const attemptIds = Array.from({ length: input.attempts ?? 1 }, () => randomUUID());
  cleanupRunIds.push(runId);
  const runSpec = db.json({ schema: "cmux.run/v1", resources: { maxConcurrent: input.maxConcurrent ?? 1 } });
  await db`
    insert into runs (id, user_id, owner_team_id, request_digest, source, spec, recipe, desired_attempts, status)
    values (${runId}::uuid, ${`worker-test-${runId}`}, ${`team-${runId}`}, 'sha256:worker-test', '{}'::jsonb,
      ${runSpec},
      'worker-test', ${attemptIds.length}, 'queued')
  `;
  for (const [ordinal, attemptId] of attemptIds.entries()) {
    await db`
      insert into run_attempts (id, run_id, ordinal, variant, status)
      values (${attemptId}::uuid, ${runId}::uuid, ${ordinal}, ${db.json({ id: `v${ordinal}` })}, 'queued')
    `;
  }
  return { runId, attemptIds };
}

beforeAll(async () => {
  if (!runDbTests) return;
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  const [postgresModule, workerModule] = await Promise.all([import("postgres"), import("../services/runs/worker")]);
  sqlClient = postgresModule.default(url, { max: 2 }) as unknown as TestSql;
  worker = workerModule;
});

afterAll(async () => {
  if (sqlClient) {
    for (const runId of cleanupRunIds) await sqlClient`delete from runs where id = ${runId}::uuid`;
    await sqlClient.end({ timeout: 5 });
  }
  if (runDbTests) {
    const { closeCloudDbForTests } = await import("../db/client");
    await closeCloudDbForTests();
  }
});

describe("Run attempt worker database protocol", () => {
  dbTest("claims with per-run concurrency, reclaims expired leases, and fences stale/replayed completion", async () => {
    const { runId } = await fixture({ attempts: 2, maxConcurrent: 1 });
    const first = await requiredWorker().claimNextRunAttempt({ workerId: "worker-a", runId, now: NOW, leaseMs: 60_000 });
    expect(first?.runId).toBe(runId);
    expect(await requiredWorker().claimNextRunAttempt({ workerId: "worker-b", runId, now: NOW, leaseMs: 60_000 })).toBeNull();

    const second = await requiredWorker().claimNextRunAttempt({ workerId: "worker-b", runId, now: new Date(NOW.getTime() + 61_000), leaseMs: 60_000 });
    expect(second?.runId).toBe(runId);
    expect(second?.leaseId).not.toBe(first?.leaseId);
    expect(await requiredWorker().finishRunAttempt({ runId, attemptId: first!.attemptId, leaseId: first!.leaseId, status: "succeeded", now: new Date(NOW.getTime() + 62_000) })).toBe(false);
    expect(await requiredWorker().finishRunAttempt({ runId, attemptId: second!.attemptId, leaseId: second!.leaseId, status: "succeeded", now: new Date(NOW.getTime() + 62_000) })).toBe(true);
    expect(await requiredWorker().finishRunAttempt({ runId, attemptId: second!.attemptId, leaseId: second!.leaseId, status: "succeeded", now: new Date(NOW.getTime() + 62_000) })).toBe(false);
  });

  dbTest("cancellation fences new claims and lets the current worker acknowledge it once", async () => {
    const { runId } = await fixture({ attempts: 1 });
    const claimed = await requiredWorker().claimNextRunAttempt({ workerId: "worker-c", runId, now: NOW, leaseMs: 60_000 });
    expect(claimed).not.toBeNull();
    expect(await requiredWorker().cancelRun({ runId, now: new Date(NOW.getTime() + 1_000) })).toBe(true);
    expect(await requiredWorker().cancelRun({ runId, now: new Date(NOW.getTime() + 2_000) })).toBe(false);
    expect(await requiredWorker().claimNextRunAttempt({ workerId: "worker-d", runId, now: new Date(NOW.getTime() + 2_000), leaseMs: 60_000 })).toBeNull();
    expect(await requiredWorker().cancelClaimedRunAttempt({ runId, attemptId: claimed!.attemptId, leaseId: claimed!.leaseId, now: new Date(NOW.getTime() + 3_000) })).toBe(true);
    expect(await requiredWorker().cancelClaimedRunAttempt({ runId, attemptId: claimed!.attemptId, leaseId: claimed!.leaseId, now: new Date(NOW.getTime() + 3_000) })).toBe(false);
  });

  // The production worker passes retainedUntil as a Date. The postgres-js
  // driver used to reject it at Bind, which failed every retained Run attempt.
  dbTest("records a retained success with a Date retention deadline", async () => {
    const { runId } = await fixture({ attempts: 1 });
    const claimed = await requiredWorker().claimNextRunAttempt({ workerId: "worker-r", runId, now: NOW, leaseMs: 60_000 });
    expect(claimed).not.toBeNull();
    const retainedUntil = new Date(NOW.getTime() + 15 * 60_000);
    expect(await requiredWorker().finishRunAttempt({ runId, attemptId: claimed!.attemptId, leaseId: claimed!.leaseId, status: "succeeded", providerVmId: "vm-retained", cleanupState: "retained", retainedUntil, now: new Date(NOW.getTime() + 1_000) })).toBe(true);
    const [row] = await database()`select status, cleanup_state, retained_until from run_attempts where id = ${claimed!.attemptId}::uuid` as { status: string; cleanup_state: string; retained_until: Date }[];
    expect(row?.status).toBe("succeeded");
    expect(row?.cleanup_state).toBe("retained");
    expect(new Date(row!.retained_until).toISOString()).toBe(retainedUntil.toISOString());
  });

  dbTest("allows two attempts when the run resource cap is two", async () => {
    const { runId } = await fixture({ attempts: 3, maxConcurrent: 2 });
    const first = await requiredWorker().claimNextRunAttempt({ workerId: "worker-e", runId, now: NOW, leaseMs: 60_000 });
    const second = await requiredWorker().claimNextRunAttempt({ workerId: "worker-f", runId, now: NOW, leaseMs: 60_000 });
    expect(first?.runId).toBe(runId);
    expect(second?.runId).toBe(runId);
    expect(await requiredWorker().claimNextRunAttempt({ workerId: "worker-g", runId, now: NOW, leaseMs: 60_000 })).toBeNull();
  });
});
