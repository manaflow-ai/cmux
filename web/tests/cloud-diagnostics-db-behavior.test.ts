import { afterEach, describe, expect, test } from "bun:test";
import { randomBytes, randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { cloudDb } from "../db/client";
import { acceptCloudTelemetry, claimCloudDiagnostics, cloudDiagnosticsFinishStatement, expireCloudDiagnostics, finishCloudDiagnostics } from "../services/observability/cloudTelemetryRepository";
import { CloudTelemetryConflictError } from "../services/observability/cloudTelemetryIngest";
import { CloudOperationProgress, readCloudOperationProgress } from "../services/observability/cloudOperationProgress";
import type { CloudTelemetryBatch } from "../services/observability/cloudTelemetryContract";
import { parseCloudTelemetryBatch } from "../services/observability/cloudTelemetryContract";

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
  dbTest("accepted placement diagnostics retain their category through the durable outbox", async () => {
    const { owner, batch } = fixture();
    const submitted = { ...batch, spans: [{ ...batch.spans[0]!, failure: "placement" }] };
    const parsed = parseCloudTelemetryBatch(submitted);
    expect(parsed).not.toBeNull();
    expect(await acceptCloudTelemetry(owner, parsed!)).toBe(1);
    const claimed = await claimCloudDiagnostics(100, owner);
    expect(claimed.rows).toHaveLength(1);
    expect(claimed.rows[0]!.payload.span).toEqual(submitted.spans[0]);
    await finishCloudDiagnostics(claimed, true);
    expect((await claimCloudDiagnostics(100, owner)).rows).toEqual([]);
  });

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
    await finishCloudDiagnostics(first, true);
    const [pending] = await cloudDb().execute(sql`select delivered_at from cloud_diagnostic_events where user_id = ${owner}`);
    expect(pending?.delivered_at).toBeNull();
    await finishCloudDiagnostics(second, true);
    const [delivered] = await cloudDb().execute(sql`select delivered_at from cloud_diagnostic_events where user_id = ${owner}`);
    expect(delivered?.delivered_at).not.toBeNull();
  });
  dbTest("finishing a lease reads only its claimed rows, never the whole outbox", async () => {
    // Production finished every drain with a sequential scan of the multi-GB
    // outbox, which starved the shared database. With sequential scans
    // disabled, a statement that has no usable index still plans one.
    const { owner, batch } = fixture();
    await acceptCloudTelemetry(owner, batch);
    const claimed = await claimCloudDiagnostics(100, owner);
    expect(claimed.rows).toHaveLength(1);
    for (const delivered of [true, false]) {
      const plan = await cloudDb().transaction(async (tx) => {
        await tx.execute(sql`set local enable_seqscan = off`);
        const rows = await tx.execute(sql`explain ${cloudDiagnosticsFinishStatement(claimed, delivered)}`);
        return rows.map((row) => String(row["QUERY PLAN"])).join("\n");
      });
      expect(plan).not.toContain("Seq Scan on cloud_diagnostic_events");
    }
    await finishCloudDiagnostics(claimed, true);
  });
  dbTest("a sampled span stores its weight without changing its retry identity", async () => {
    const { owner, batch } = fixture();
    const eventId = batch.spans[0]!.eventId;
    const weights = new Map([[eventId, 50]]);
    expect(await acceptCloudTelemetry(owner, batch, { sampleWeights: weights })).toBe(1);
    // A retry is deduplicated by the submitted content, not by the ingest weight.
    expect(await acceptCloudTelemetry(owner, batch)).toBe(1);
    const claimed = await claimCloudDiagnostics(100, owner);
    expect(claimed.rows.map((row) => row.payload.sampleWeight)).toEqual([50]);
    await finishCloudDiagnostics(claimed, true);
  });
  dbTest("retention drops delivered rows after the retry window and keeps undelivered rows for a week", async () => {
    const { owner, batch } = fixture();
    const span = batch.spans[0]!;
    const ages = { deliveredFresh: "2 hours", deliveredOld: "26 hours", pendingOld: "26 hours", pendingExpired: "8 days" };
    const ids: Record<string, string> = {};
    for (const [name, age] of Object.entries(ages)) {
      ids[name] = randomUUID();
      await acceptCloudTelemetry(owner, { ...batch, spans: [{ ...span, eventId: ids[name]! }] });
      await cloudDb().execute(sql`
        update cloud_diagnostic_events set received_at = now() - ${age}::interval,
          delivered_at = ${name.startsWith("delivered") ? sql`now()` : sql`null`}
        where user_id = ${owner} and event_id = ${ids[name]}::uuid
      `);
    }
    // Scoped to this owner: other suites' rows in a shared database cannot consume the batches.
    expect(await expireCloudDiagnostics(owner)).toMatchObject({ expiredDelivered: 1, expiredUndelivered: 1 });
    const rows = await cloudDb().execute(sql`select event_id::text from cloud_diagnostic_events where user_id = ${owner}`);
    expect(new Set(rows.map((row) => String(row.event_id)))).toEqual(new Set([ids.deliveredFresh!, ids.pendingOld!]));
  });
  dbTest("a delivered backlog larger than both batches cannot starve undelivered expiry", async () => {
    const { owner, batch } = fixture();
    await cloudDb().execute(sql`
      insert into cloud_diagnostic_events (user_id, event_id, payload, payload_hash, received_at, delivered_at)
      select ${owner}, gen_random_uuid(), '{}'::jsonb, 'backlog', now() - interval '9 days', now()
      from generate_series(1, 2001)
    `);
    const stranded = batch.spans[0]!.eventId;
    await acceptCloudTelemetry(owner, batch);
    await cloudDb().execute(sql`
      update cloud_diagnostic_events set received_at = now() - interval '8 days'
      where user_id = ${owner} and event_id = ${stranded}::uuid
    `);
    expect(await expireCloudDiagnostics(owner)).toMatchObject({ expiredDelivered: 1000, expiredUndelivered: 1 });
    const left = await cloudDb().execute(sql`select count(*)::int as count from cloud_diagnostic_events where user_id = ${owner} and event_id = ${stranded}::uuid`);
    expect(Number(left[0]?.count)).toBe(0);
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
