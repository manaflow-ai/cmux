import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import { randomUUID } from "node:crypto";

// A Run whose worker fails before it reaches the VM (owner session, Cloud
// origin) must end failed. When that failure escaped processClaim, the attempt
// kept status 'running', every later cron claim threw the same way, and the
// Run stayed "running" until callers gave up (staging dogfood, 2026-10-18).
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
type TestSql = ((strings: TemplateStringsArray, ...values: unknown[]) => Promise<Record<string, unknown>[]>) & { end(options?: { timeout?: number }): Promise<void>; json(value: unknown): unknown };
let sqlClient: TestSql | null = null;
const cleanupRunIds: string[] = [];

mock.module("../services/runs/legacy/cloudClient", () => ({
  runCloudOrigin: () => "https://cmux-staging.vercel.app",
  runCloudClient: async () => {
    throw Object.assign(new Error("Run worker setup failed at session-create"), { stage: "session-create" });
  },
}));

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

describe("Run queue worker", () => {
  dbTest("a worker that cannot open the owner's Cloud session ends the attempt and the Run failed", async () => {
    const db = database();
    const runId = randomUUID();
    const attemptId = randomUUID();
    cleanupRunIds.push(runId);
    await db`
      insert into runs (id, user_id, owner_team_id, request_digest, source, spec, recipe, desired_attempts, status)
      values (${runId}::uuid, ${`runner-test-${runId}`}, ${`team-${runId}`}, 'sha256:runner-test', '{}'::jsonb,
        ${db.json({ schema: "cmux.run/v1", resources: { maxConcurrent: 1 } })}, 'runner-test', 1, 'queued')
    `;
    await db`
      insert into run_attempts (id, run_id, ordinal, variant, status)
      values (${attemptId}::uuid, ${runId}::uuid, 0, ${db.json({ id: "v0" })}, 'queued')
    `;

    const { processRunQueue } = await import("../services/runs/legacy/runner");
    const outcome = await processRunQueue({ runId });
    expect(outcome.results).toContain("failed");

    const [attempt] = await db`select status::text, error, lease_id from run_attempts where id = ${attemptId}::uuid`;
    expect(attempt?.status).toBe("failed");
    expect(attempt?.error).toBe("Run worker could not open the owner's Cloud session (session-create)");
    const [run] = await db`select status::text from runs where id = ${runId}::uuid`;
    expect(run?.status).toBe("failed");
    const events = await db`select kind::text as kind from run_events where run_id = ${runId}::uuid order by sequence`;
    expect(events.map((event) => event.kind)).toEqual(["attempt.started", "attempt.failed"]);
  });
});
