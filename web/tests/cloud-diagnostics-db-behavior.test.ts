import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { context as otelContext, trace, type Attributes } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { BasicTracerProvider, InMemorySpanExporter, SimpleSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { sql } from "drizzle-orm";
import { cloudDb } from "../db/client";
import { acceptCloudTelemetry, claimCloudDiagnostics, cloudDiagnosticsFinishStatement, expireCloudDiagnostics, finishCloudDiagnostics } from "../services/observability/cloudTelemetryRepository";
import { CLOUD_TELEMETRY_REFUSAL_SPAN, CloudTelemetryConflictError, makeCloudTelemetryHandler } from "../services/observability/cloudTelemetryIngest";
import { buildCmuxTraceSampler } from "../services/observability/sampler";
import { CloudOperationProgress, readCloudOperationProgress } from "../services/observability/cloudOperationProgress";
import type { CloudTelemetryBatch, CloudTelemetrySpan } from "../services/observability/cloudTelemetryContract";
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

// The ingest route as deployed: the real handler, durable acceptance in Postgres,
// and the production trace sampler with its head-sampling ratio at zero, so only
// spans that are always kept reach the exporter.
const exporter = new InMemorySpanExporter();
const provider = new BasicTracerProvider({
  sampler: buildCmuxTraceSampler({ CMUX_OTEL_BASE_SAMPLE_RATIO: "0" }),
  spanProcessors: [new SimpleSpanProcessor(exporter)],
});
trace.disable();
trace.setGlobalTracerProvider(provider);
otelContext.setGlobalContextManager(new AsyncLocalStorageContextManager().enable());
afterAll(async () => { await provider.shutdown(); trace.disable(); otelContext.disable(); });

const identityKey = "cloud-diagnostics-test-identity-key-0123456789";
function telemetrySpan(overrides: Partial<CloudTelemetrySpan> = {}): CloudTelemetrySpan {
  const now = Date.now();
  return {
    eventId: randomUUID(), operationId: randomUUID(), traceId: randomBytes(16).toString("hex"),
    spanId: randomBytes(8).toString("hex"), operation: "exec", phase: "request", outcome: "success",
    startedAtMs: now - 100, endedAtMs: now, attempt: 1, ...overrides,
  };
}
const routine = (count: number) => Array.from({ length: count }, () => telemetrySpan());
const failures = (count: number) => Array.from({ length: count }, () => telemetrySpan({ outcome: "failure", failure: "network" }));
const instanceId = randomUUID();
async function upload(owner: string, spans: CloudTelemetrySpan[], ingress: boolean | { rateLimitRule: string } = true, nowMs = Date.now()) {
  let drains = 0;
  const handler = makeCloudTelemetryHandler({
    authenticate: async () => ({ id: owner }),
    checkIngress: async () => ingress,
    accept: (userId, batch, sampleWeights) => acceptCloudTelemetry(userId, batch, { sampleWeights }),
    scheduleDrain: () => { drains += 1; },
    now: () => nowMs,
  });
  const body = { version: 1, client: { channel: "production", version: "0.65.0", build: "110", revision: "abcdef123", osVersion: "26.0", architecture: "arm64", instanceId }, spans };
  exporter.reset();
  const response = await trace.getTracer("cloud-diagnostics-test").startActiveSpan("POST /api/observability/cloud", async (span) => {
    try {
      return await handler(new Request("https://cmux.test/api/observability/cloud", {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
      }));
    } finally { span.end(); }
  });
  const exported = exporter.getFinishedSpans();
  return {
    status: response.status, drains,
    refusals: exported.filter((finished) => finished.name === CLOUD_TELEMETRY_REFUSAL_SPAN).map((finished) => finished.attributes as Attributes),
    routeSpanExported: exported.some((finished) => finished.name === "POST /api/observability/cloud"),
  };
}
async function uploadUntilRefused(owner: string, batch: () => CloudTelemetrySpan[]) {
  let result = await upload(owner, batch());
  for (let attempt = 0; result.status === 202 && attempt < 40; attempt += 1) result = await upload(owner, batch());
  return result;
}
async function storedEventIds(owner: string): Promise<Set<string>> {
  const rows = await cloudDb().execute(sql`select event_id::text from cloud_diagnostic_events where user_id = ${owner}`);
  return new Set(rows.map((row) => String(row.event_id)));
}

describe("Cloud diagnostic ingest refusals", () => {
  dbTest("routine detail that fills an account's minute cannot refuse its failures, and every refusal is counted", async () => {
    const owner = fixture().owner;
    const previousKey = process.env.CMUX_CLOUD_TELEMETRY_ID_KEY;
    process.env.CMUX_CLOUD_TELEMETRY_ID_KEY = identityKey;
    try {
      // Successful command spans are not sampled, so 40 per upload fill the routine budget in a few uploads.
      const full = await uploadUntilRefused(owner, () => routine(40));
      expect(full.status).toBe(429);
      // The route span is head-sampled away; the refusal is still exported, once.
      expect(full.routeSpanExported).toBe(false);
      expect(full.refusals).toEqual([expect.objectContaining({
        "cmux.telemetry.refusal": "account_byte_budget", "http.response.status_code": 429, "cmux.priority": true,
        "cmux.telemetry.submitted_spans": 40, "cmux.telemetry.accepted_spans": 0,
        "cmux.account_key": createHmac("sha256", identityKey).update(owner).digest("hex"),
        "cmux.client.instance_id": instanceId,
      })]);

      // Evidence that shares a batch with routine detail is stored on the first attempt; the batch still answers 429.
      let failure = telemetrySpan();
      let signIn = telemetrySpan();
      let mixed: CloudTelemetrySpan[] = [];
      let refusedMixed = full;
      for (let attempt = 0; attempt < 2; attempt += 1) {
        // A minute boundary resets the budget; fill it again before the evidence arrives.
        if (attempt > 0) await uploadUntilRefused(owner, () => routine(40));
        failure = telemetrySpan({ outcome: "failure", failure: "network" });
        signIn = telemetrySpan({ operation: "session", phase: "authentication", outcome: "failure", failure: "rate_limit", httpStatus: 429 });
        mixed = [...routine(38), failure, signIn];
        refusedMixed = await upload(owner, mixed);
        if (refusedMixed.status === 429) break;
      }
      expect(refusedMixed.status).toBe(429);
      expect(refusedMixed.refusals[0]).toMatchObject({
        "cmux.telemetry.refusal": "account_byte_budget", "cmux.telemetry.accepted_spans": 0, "cmux.telemetry.stored_spans": 2,
      });
      // The kept evidence is delivered now, not at the next cron drain.
      expect(refusedMixed.drains).toBe(1);
      let stored = await storedEventIds(owner);
      expect([stored.has(failure.eventId), stored.has(signIn.eventId), stored.has(mixed[0]!.eventId)]).toEqual([true, true, false]);
      // The client's retry of the same batch is deduplicated, never a conflict.
      expect((await upload(owner, mixed)).status).not.toBe(409);

      // A batch of only evidence is accepted in full.
      const evidence = failures(2);
      expect((await upload(owner, evidence)).status).toBe(202);
      stored = await storedEventIds(owner);
      expect(evidence.every((span) => stored.has(span.eventId))).toBe(true);

      // The reserve is bounded: an account that sends only failures is still refused.
      expect((await uploadUntilRefused(owner, () => failures(40))).status).toBe(429);
    } finally {
      if (previousKey === undefined) delete process.env.CMUX_CLOUD_TELEMETRY_ID_KEY;
      else process.env.CMUX_CLOUD_TELEMETRY_ID_KEY = previousKey;
    }
  });

  dbTest("firewall refusals answer 429 before authentication, store nothing, and a flood leaves one counted span per window", async () => {
    const owner = fixture().owner;
    const rule = { rateLimitRule: `cmux-analytics-${randomUUID()}` };
    const start = Date.now();
    const refused = await upload(owner, failures(1), rule, start);
    expect(refused.status).toBe(429);
    expect(refused.refusals).toEqual([expect.objectContaining({
      "cmux.telemetry.refusal": "ingress_rate_limited", "cmux.telemetry.rate_limit_rule": rule.rateLimitRule,
      "http.response.status_code": 429, "cmux.telemetry.refusal_count": 1,
    })]);
    expect(refused.refusals[0]!["cmux.account_key"]).toBeUndefined();
    // Within the window the refusals are still answered but only counted.
    for (let index = 0; index < 5; index += 1) {
      const flooded = await upload(owner, failures(1), rule, start + 1_000);
      expect([flooded.status, flooded.refusals.length]).toEqual([429, 0]);
    }
    const next = await upload(owner, failures(1), rule, start + 10_000);
    expect(next.refusals).toEqual([expect.objectContaining({ "cmux.telemetry.refusal_count": 6 })]);
    expect((await storedEventIds(owner)).size).toBe(0);
  });

  dbTest("a sampled-out routine poll that reports client queue drops is stored with its count", async () => {
    const owner = fixture().owner;
    // A trace ID whose last four hex digits are not divisible by 50 is outside the 2% poll sample.
    const reported = telemetrySpan({ operation: "list", traceId: `${randomBytes(14).toString("hex")}0001`, droppedCount: 7 });
    const silent = telemetrySpan({ operation: "list", traceId: `${randomBytes(14).toString("hex")}0001` });
    const accepted = await upload(owner, [reported, silent]);
    expect(accepted.status).toBe(202);
    expect(accepted.refusals).toEqual([]);
    const claimed = await claimCloudDiagnostics(100, owner);
    expect(claimed.rows.map((row) => [row.eventId, row.payload.span.droppedCount, row.payload.sampleWeight])).toEqual([[reported.eventId, 7, undefined]]);
    await finishCloudDiagnostics(claimed, true);
  });
});
