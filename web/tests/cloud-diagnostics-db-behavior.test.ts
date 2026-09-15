import { afterEach, describe, expect, test } from "bun:test";
import { randomBytes, randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { cloudDb } from "../db/client";
import { acceptCloudTelemetry, claimCloudDiagnostics, finishCloudDiagnostics } from "../services/observability/cloudTelemetryRepository";
import { CloudTelemetryConflictError } from "../services/observability/cloudTelemetryIngest";
import { CloudOperationProgress, readCloudOperationProgress } from "../services/observability/cloudOperationProgress";
import type { CloudTelemetryBatch } from "../services/observability/cloudTelemetryContract";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const owners: string[] = [];
function fixture(): { owner: string; batch: CloudTelemetryBatch } {
  const owner = `cloud-test-${randomUUID()}`;
  owners.push(owner);
  const now = Date.now();
  return { owner, batch: {
    version: 1,
    client: { channel: "nightly", version: "1.0.0", build: "1", revision: "abcdef123", osVersion: "26.0", architecture: "arm64" },
    spans: [{ eventId: randomUUID(), operationId: randomUUID(), traceId: randomBytes(16).toString("hex"),
      spanId: randomBytes(8).toString("hex"), operation: "create", phase: "operation", outcome: "failure",
      startedAtMs: now - 100, endedAtMs: now, attempt: 1, failure: "network" }],
  } };
}
afterEach(async () => {
  if (!enabled) return;
  for (const owner of owners.splice(0)) {
    await cloudDb().execute(sql`delete from cloud_diagnostic_events where user_id = ${owner}`);
    await cloudDb().execute(sql`delete from cloud_diagnostic_budgets where user_id = ${owner}`);
    await cloudDb().execute(sql`delete from cloud_operation_steps where user_id = ${owner}`);
  }
});

describe("Cloud diagnostic durable storage", () => {
  dbTest("concurrent retry receipts store one event and charge once", async () => {
    const { owner, batch } = fixture();
    expect(await Promise.all(Array.from({ length: 6 }, () => acceptCloudTelemetry(owner, batch)))).toEqual([1, 1, 1, 1, 1, 1]);
    const rows = await cloudDb().execute(sql`select payload from cloud_diagnostic_events where user_id = ${owner}`);
    expect(rows.length).toBe(1);
    const budgets = await cloudDb().execute(sql`select bytes from cloud_diagnostic_budgets where user_id = ${owner}`);
    expect(Number(budgets[0]?.bytes)).toBeLessThan(2000);
  });
  dbTest("the same event ID cannot replace previously accepted evidence", async () => {
    const { owner, batch } = fixture();
    await acceptCloudTelemetry(owner, batch);
    const changed = { ...batch, spans: [{ ...batch.spans[0]!, failure: "server" as const }] };
    await expect(acceptCloudTelemetry(owner, changed)).rejects.toBeInstanceOf(CloudTelemetryConflictError);
  });
  dbTest("account ownership scopes duplicate IDs", async () => {
    const { owner, batch } = fixture();
    const other = fixture().owner;
    await acceptCloudTelemetry(owner, batch);
    await acceptCloudTelemetry(other, batch);
    const rows = await cloudDb().execute(sql`select user_id from cloud_diagnostic_events where event_id = ${batch.spans[0]!.eventId}::uuid`);
    expect(new Set(rows.map((row) => String(row.user_id)))).toEqual(new Set([owner, other]));
  });
  dbTest("export leases survive retries and stale workers cannot acknowledge a new lease", async () => {
    const { owner, batch } = fixture();
    await acceptCloudTelemetry(owner, batch);
    const first = await claimCloudDiagnostics(100, owner);
    expect(first.rows.some((row) => row.userId === owner)).toBe(true);
    await cloudDb().execute(sql`update cloud_diagnostic_events set next_attempt_at = now() - interval '1 second' where user_id = ${owner}`);
    const second = await claimCloudDiagnostics(100, owner);
    expect(second.rows.some((row) => row.userId === owner)).toBe(true);
    await finishCloudDiagnostics(first.leaseId, true);
    const [pending] = await cloudDb().execute(sql`select delivered_at from cloud_diagnostic_events where user_id = ${owner}`);
    expect(pending?.delivered_at).toBeNull();
    await finishCloudDiagnostics(second.leaseId, true);
    const [delivered] = await cloudDb().execute(sql`select delivered_at from cloud_diagnostic_events where user_id = ${owner}`);
    expect(delivered?.delivered_at).not.toBeNull();
  });
  dbTest("progress is owner-only and preserves parallel provider steps", async () => {
    const { owner, batch } = fixture();
    const operationId = batch.spans[0]!.operationId;
    const progress = new CloudOperationProgress(owner, operationId);
    await Promise.all([progress.run("provider", async () => 1), progress.run("tunnel", async () => 2)]);
    await progress.flush();
    expect(await readCloudOperationProgress("another-user", operationId)).toEqual([]);
    const steps = await readCloudOperationProgress(owner, operationId);
    expect(steps.length).toBe(2);
    expect(steps.every((step) => step.outcome === "success" && step.endedAtMs !== null)).toBe(true);
  });
});
