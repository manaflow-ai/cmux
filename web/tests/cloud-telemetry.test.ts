import { describe, expect, test } from "bun:test";
import { parseCloudTelemetryBatch } from "../services/observability/cloudTelemetryContract";
import { makeCloudTelemetryHandler } from "../services/observability/cloudTelemetryIngest";
import { cloudSpanToOtlp } from "../services/observability/cloudTelemetryExport";

const now = Date.now();
function span(overrides: Record<string, unknown> = {}) {
  return {
    eventId: "e51c27bc-b0ad-4149-9d92-0fc79c5d2292",
    operationId: "48607a8f-e79b-4f1b-bec6-1412d1f25c0b",
    traceId: "0af7651916cd43dd8448eb211c80319c",
    spanId: "b7ad6b7169203331",
    parentSpanId: "ba6633dd11002244",
    operation: "create",
    phase: "request",
    outcome: "failure",
    startedAtMs: now - 1500,
    endedAtMs: now,
    attempt: 1,
    failure: "network",
    ...overrides,
  };
}
function batch(spans = [span()]) { return { version: 1, client: { channel: "nightly", version: "0.1.0", build: "123", revision: "abcdef1234567", osVersion: "26.0", architecture: "arm64" }, spans }; }
function request(body: unknown = batch(), headers: Record<string, string> = {}) {
  return new Request("https://cmux.test/api/observability/cloud", {
    method: "POST", headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

describe("Cloud diagnostic boundary", () => {
  test("accepts a timed operation with a real parent span", () => {
    expect(parseCloudTelemetryBatch(batch(), now)?.spans[0]).toEqual(span());
  });
  test.each(["message", "body", "userId", "teamId", "dataset", "authorization", "attributes", "command"])(
    "rejects undeclared %s fields, including user content and claimed identity", (key) => {
      expect(parseCloudTelemetryBatch(batch([span({ [key]: "secret" })]), now)).toBeNull();
      expect(parseCloudTelemetryBatch({ ...batch(), [key]: "secret" }, now)).toBeNull();
    },
  );
  test("rejects invalid IDs, time ranges and unbounded batches", () => {
    for (const invalid of [
      { traceId: "0".repeat(32) }, { spanId: "x" }, { parentSpanId: "b7ad6b7169203331" },
      { operationId: "not-an-id" }, { startedAtMs: now + 1 }, { endedAtMs: now + 600_000 },
      { startedAtMs: now - 8 * 86_400_000 }, { attempt: -1 }, { phase: "terminal-content" },
      { failure: "my-secret-key" },
    ]) expect(parseCloudTelemetryBatch(batch([span(invalid)]), now)).toBeNull();
    expect(parseCloudTelemetryBatch(batch(Array.from({ length: 101 }, () => span())), now)).toBeNull();
  });
  test("exports original Swift timing and IDs, not upload timing", () => {
    const parsed = parseCloudTelemetryBatch(batch(), now)!;
    const exported = cloudSpanToOtlp(parsed.spans[0]!);
    expect(exported.traceId).toBe(span().traceId);
    expect(exported.spanId).toBe(span().spanId);
    expect(exported.parentSpanId).toBe(span().parentSpanId);
    expect(BigInt(exported.endTimeUnixNano) - BigInt(exported.startTimeUnixNano)).toBe(BigInt(1_500_000_000));
    expect(exported.status.code).toBe(2);
    expect(JSON.stringify(exported)).not.toContain("secret");
  });
  test("authentication supplies ownership; receipt waits for durable acceptance", async () => {
    const stored: unknown[] = [];
    let release!: () => void;
    const durableWrite = new Promise<void>((resolve) => { release = resolve; });
    const handler = makeCloudTelemetryHandler({
      authenticate: async () => ({ id: "server-user" }),
      checkIngress: async () => true,
      accept: async (userId, value) => { await durableWrite; stored.push({ userId, value }); return value.spans.length; },
      scheduleDrain: () => {}, now: () => now,
    });
    let answered = false;
    const response = handler(request()).then((value) => { answered = true; return value; });
    await Promise.resolve();
    expect(answered).toBe(false);
    release();
    expect((await response).status).toBe(202);
    expect(stored).toEqual([{ userId: "server-user", value: batch() }]);
  });
  test("rejects signed-out callers and cookies without writing", async () => {
    let writes = 0;
    const handler = makeCloudTelemetryHandler({
      authenticate: async () => null, checkIngress: async () => true,
      accept: async () => { writes++; return 1; }, scheduleDrain: () => {}, now: () => now,
    });
    expect((await handler(request(batch(), { cookie: "session=x" }))).status).toBe(401);
    expect(writes).toBe(0);
  });
  test("a storage failure is retryable and never reports acceptance", async () => {
    const handler = makeCloudTelemetryHandler({
      authenticate: async () => ({ id: "server-user" }), checkIngress: async () => true,
      accept: async () => { throw new Error("database unavailable with secret"); },
      scheduleDrain: () => {}, now: () => now,
    });
    const response = await handler(request());
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("secret");
    expect(response.headers.get("retry-after")).not.toBeNull();
  });
  test("rejects oversized and compressed bodies before decoding", async () => {
    let writes = 0;
    const handler = makeCloudTelemetryHandler({
      authenticate: async () => ({ id: "server-user" }), checkIngress: async () => true,
      accept: async () => { writes++; return 1; }, scheduleDrain: () => {}, now: () => now,
    });
    expect((await handler(request(batch(), { "content-encoding": "gzip" }))).status).toBe(415);
    expect((await handler(request({ padding: "x".repeat(70_000) }))).status).toBe(413);
    expect(writes).toBe(0);
  });
  test("rate limiting runs before authentication and parsing", async () => {
    let authCalls = 0;
    const handler = makeCloudTelemetryHandler({
      authenticate: async () => { authCalls++; return { id: "server-user" }; },
      checkIngress: async () => false, accept: async () => 1, scheduleDrain: () => {}, now: () => now,
    });
    expect((await handler(request())).status).toBe(429);
    expect(authCalls).toBe(0);
  });
});
