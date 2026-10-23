import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { RunCloudOperationPending } from "../services/runs/cloudClientContract";
import { normalizeRunSpec } from "../services/runs/spec";

// /api/vm answers vm_create_in_progress while the same idempotent create runs.
// A create whose background continuation died never finishes, so the worker
// must stop retrying it: otherwise the Run stays running and holds its
// maxConcurrent slot forever.
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
type TestSql = ((strings: TemplateStringsArray, ...values: unknown[]) => Promise<Record<string, unknown>[]>) & { end(options?: { timeout?: number }): Promise<void>; json(value: unknown): unknown };
let sqlClient: TestSql | null = null;
const cleanupRunIds: string[] = [];

mock.module("../services/runs/cloudClient", () => ({
  runCloudOrigin: () => "https://cmux-staging.vercel.app",
  RunCloudOperationPending,
  runCloudClient: async () => async (method: string, path: string) => {
    if (method === "POST" && path === "/api/vm") throw new RunCloudOperationPending();
    throw new Error(`unexpected Cloud call ${method} ${path}`);
  },
}));

const DIGEST = `sha256:${"a".repeat(64)}`;
const RUN_SPEC = normalizeRunSpec({
  schema: "cmux.run/v1",
  operationId: "runner-create-pending",
  source: { repository: "manaflow-ai/cmux", ref: "main", commit: "b".repeat(40), setupManifestDigest: DIGEST },
  intent: { digest: DIGEST },
  recipe: { id: "cloud-vm-dogfood", version: 1 },
  variants: [{ id: "default", label: "Default", instructionDigest: DIGEST }],
  workspace: { kind: "ephemeral" },
  resources: { maxAttempts: 1, maxConcurrent: 1, memoryClass: "standard", cpuClass: "standard", wallTimeoutMs: 30_000, retainMs: 30_000 },
  routing: { executionProvider: "cloud-vm", backend: "freestyle" },
  capabilities: { secretRefs: [] },
  checks: [],
  policy: { mode: "fanout", humanApprovalRequired: false, evidenceKinds: ["patch"] },
});

function database(): TestSql {
  if (!sqlClient) throw new Error("database test is not initialized");
  return sqlClient;
}

beforeAll(async () => {
  if (!runDbTests) return;
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  const postgres = (await import("postgres")).default;
  sqlClient = postgres(url, { max: 2 }) as unknown as TestSql;
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

async function seedRun(startedMinutesAgo: number | null): Promise<{ runId: string; attemptId: string }> {
  const db = database();
  const runId = randomUUID();
  const attemptId = randomUUID();
  cleanupRunIds.push(runId);
  await db`
    insert into runs (id, user_id, owner_team_id, request_digest, source, spec, recipe, desired_attempts, status)
    values (${runId}::uuid, ${`runner-pending-${runId}`}, ${`team-${runId}`}, 'sha256:runner-pending', '{}'::jsonb,
      ${db.json(RUN_SPEC)}, 'runner-test', 1, 'queued')
  `;
  // An earlier claim started the create; its lease has lapsed, so the next
  // cron turn re-claims the attempt and retries the same idempotency key.
  await db`
    insert into run_attempts (id, run_id, ordinal, variant, status, started_at, lease_until)
    values (${attemptId}::uuid, ${runId}::uuid, 0, ${db.json({ id: "v0" })},
      ${startedMinutesAgo === null ? "queued" : "running"},
      ${startedMinutesAgo === null ? null : new Date(Date.now() - startedMinutesAgo * 60_000).toISOString()}::timestamptz,
      ${startedMinutesAgo === null ? null : new Date(Date.now() - 1_000).toISOString()}::timestamptz)
  `;
  return { runId, attemptId };
}

describe("Run queue worker, Cloud VM create in progress", () => {
  dbTest("keeps a recent in-progress create running so the next cron turn retries it", async () => {
    const { runId, attemptId } = await seedRun(null);
    const { processRunQueue } = await import("../services/runs/runner");
    const outcome = await processRunQueue({ runId });
    expect(outcome.results).toContain("pending");

    const db = database();
    const [attempt] = await db`select status::text, error from run_attempts where id = ${attemptId}::uuid`;
    expect(attempt?.status).toBe("running");
    expect(attempt?.error).toBeNull();
    const [run] = await db`select status::text from runs where id = ${runId}::uuid`;
    expect(run?.status).toBe("running");
  });

  dbTest("fails the attempt and the Run once the create has been in progress past the ceiling", async () => {
    const { runId, attemptId } = await seedRun(21);
    const { processRunQueue } = await import("../services/runs/runner");
    const outcome = await processRunQueue({ runId });
    expect(outcome.results).toContain("failed");

    const db = database();
    const [attempt] = await db`select status::text, error from run_attempts where id = ${attemptId}::uuid`;
    expect(attempt?.status).toBe("failed");
    expect(String(attempt?.error)).toContain("Cloud VM create did not finish");
    const [run] = await db`select status::text from runs where id = ${runId}::uuid`;
    expect(run?.status).toBe("failed");
  });
});
