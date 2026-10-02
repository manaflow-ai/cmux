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
function batch(spans = [span()], channel = "nightly") { return { version: 1, client: { channel, version: "0.1.0", build: "123", revision: "abcdef1234567", osVersion: "26.0", architecture: "arm64" }, spans }; }
function request(body: unknown = batch(), headers: Record<string, string> = {}) {
  return new Request("https://cmux.test/api/observability/cloud", {
    method: "POST", headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

describe("Cloud diagnostic boundary", () => {
  test("acknowledges and exports placement failures without dropping neighboring spans", async () => {
    const { exportCloudDiagnostics } = await import("../services/observability/cloudTelemetryExport");
    const payload = batch([
      span({ operation: "terminal", phase: "materialize", failure: "placement" }),
      span({ eventId: "8cc333de-a1bc-4eb1-8d69-1decd01e17a9" }),
    ]);
    const accepted: unknown[] = [];
    const sent: { url: string; body: any }[] = [];
    const handler = makeCloudTelemetryHandler({
      authenticate: async () => ({ id: "synthetic-owner" }),
      checkIngress: async () => true,
      accept: async (userId, value) => {
        accepted.push(value);
        await exportCloudDiagnostics(value.spans.map((span) => ({
          userId, eventId: span.eventId, attempts: 1, payload: { client: value.client, span },
        })), {
          origin: "https://us-east-1.aws.edge.axiom.co", token: "test-only",
          identityKey: "test-only-identity-key".repeat(2), tracesDataset: "test-traces",
          errorsDataset: "test-errors", environment: "preview", revision: "abcdef123",
        }, (async (url, init) => {
          sent.push({ url: String(url), body: JSON.parse(String(init?.body)) });
          return new Response("{}");
        }) as typeof fetch);
        return value.spans.length;
      },
      scheduleDrain: () => {}, now: () => now,
    });
    const response = await handler(request(payload));
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      accepted: 2, eventIds: payload.spans.map((span) => span.eventId),
    });
    expect(accepted).toEqual([payload]);
    const errors = sent.find((item) => item.url.endsWith("/v1/ingest/test-errors"))!.body;
    expect(errors.map((item: any) => item.failure)).toEqual(["placement", "network"]);
    expect(errors[0]).toMatchObject({
      event_id: payload.spans[0]!.eventId, operation_id: payload.spans[0]!.operationId,
      trace_id: payload.spans[0]!.traceId, span_id: payload.spans[0]!.spanId,
      operation: "terminal", phase: "materialize", outcome: "failure",
    });
    const spans = sent.find((item) => item.url.endsWith("/v1/traces"))!.body.resourceSpans;
    expect(spans[0].scopeSpans[0].spans[0].attributes).toContainEqual({
      key: "error.type", value: { stringValue: "placement" },
    });
    expect(JSON.stringify(sent)).not.toContain("synthetic-owner");
  });

  test("accepts authenticated RC diagnostics and exports rc separately from production", async () => {
    const { exportCloudDiagnostics } = await import("../services/observability/cloudTelemetryExport");
    const sent: { url: string; body: any }[] = [];
    const configuration = {
      origin: "https://us-east-1.aws.edge.axiom.co", token: "test-only",
      identityKey: "test-only-identity-key".repeat(2), tracesDataset: "test-traces",
      errorsDataset: "test-errors", environment: "production", revision: "abcdef123",
    } as const;
    const handler = makeCloudTelemetryHandler({
      authenticate: async () => ({ id: "synthetic-owner" }),
      checkIngress: async () => true,
      accept: async (userId, value) => {
        await exportCloudDiagnostics(value.spans.map((span) => ({
          userId, eventId: span.eventId, attempts: 1, payload: { client: value.client, span },
        })), configuration, (async (url, init) => {
          sent.push({ url: String(url), body: JSON.parse(String(init?.body)) });
          return new Response("{}");
        }) as typeof fetch);
        return value.spans.length;
      },
      scheduleDrain: () => {}, now: () => now,
    });
    const rcPayload = batch([span({ eventId: "e51c27bc-b0ad-4149-9d92-0fc79c5d2292" })], "rc");
    const productionPayload = batch([span({ eventId: "8cc333de-a1bc-4eb1-8d69-1decd01e17a9" })], "production");

    const rcResponse = await handler(request(rcPayload));
    const productionResponse = await handler(request(productionPayload));
    expect(rcResponse.status).toBe(202);
    expect(productionResponse.status).toBe(202);
    expect((await rcResponse.json()).accepted).toBe(1);
    expect((await productionResponse.json()).accepted).toBe(1);

    const errorChannels = sent.filter((item) => item.url.endsWith("/v1/ingest/test-errors"))
      .flatMap((item) => item.body.map((row: any) => row.client_channel)).sort();
    expect(errorChannels).toEqual(["production", "rc"]);
    const traceChannels = sent.filter((item) => item.url.endsWith("/v1/traces"))
      .map((item) => item.body.resourceSpans[0].resource.attributes
        .find((attribute: any) => attribute.key === "cmux.client.channel").value.stringValue).sort();
    expect(traceChannels).toEqual(["production", "rc"]);
  });

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

describe("shared development error destination", () => {
  test("routes client and server errors to the dev dataset with backend identity", async () => {
    const { cloudAxiomConfiguration, exportCloudDiagnostics } = await import("../services/observability/cloudTelemetryExport");
    const configuration = cloudAxiomConfiguration({
      CMUX_CLOUD_AXIOM_TOKEN: "test-token",
      CMUX_CLOUD_TELEMETRY_ID_KEY: "k".repeat(32),
      CMUX_DEV_BUILD_TAG: "errhub",
      CMUX_DEV_BUILD_COMMIT: "a".repeat(40),
      CMUX_DEV_BUILD_SOURCE_SHA256: "b".repeat(64),
    } as unknown as NodeJS.ProcessEnv)!;
    expect(configuration.tracesDataset).toBe("cmux-dev-otel-traces");
    expect(configuration.errorsDataset).toBe("cmux-dev-otel-traces");
    const parsed = parseCloudTelemetryBatch(batch(), now)!;
    const sent: { url: string; body: any }[] = [];
    await exportCloudDiagnostics(["client", "server"].map((source) => ({
      userId: "private-account", eventId: source, attempts: 1,
      payload: { client: parsed.client, span: parsed.spans[0]!, source: source as "client" | "server", backend: { tag: "errhub", revision: "a".repeat(40), sourceSha256: "b".repeat(64) } },
    })), configuration, (async (url, init) => {
      sent.push({ url: String(url), body: JSON.parse(String(init?.body)) });
      return new Response("{}");
    }) as typeof fetch);
    const errors = sent.find((item) => item.url.includes("/ingest/"))!.body;
    expect(errors.map((item: any) => item.source)).toEqual(["client", "server"]);
    expect(errors[0].backend_tag).toBe("errhub");
    expect(errors[0].client_tag).toBeUndefined();
    expect(errors[0].backend_revision).toBe("a".repeat(40));
    expect(errors[0].backend_source_sha256).toBe("b".repeat(64));
    expect(JSON.stringify(sent)).not.toContain("private-account");
  });

  test("hosted production never follows a dev tag into a dev dataset", async () => {
    const { cloudAxiomConfiguration } = await import("../services/observability/cloudTelemetryExport");
    const config = cloudAxiomConfiguration({
      VERCEL_ENV: "production", CMUX_DEV_BUILD_TAG: "errhub",
      CMUX_CLOUD_AXIOM_TOKEN: "test", CMUX_CLOUD_TELEMETRY_ID_KEY: "k".repeat(32),
    } as unknown as NodeJS.ProcessEnv)!;
    expect(config.errorsDataset).toBe("cmux-cloud-errors-prod");
  });

  test("client tags survive the strict diagnostics boundary", () => {
    const original = batch();
    const value = { ...original, client: { ...original.client, tag: "pr-123-cloud" } };
    expect(parseCloudTelemetryBatch(value, now)?.client.tag).toBe("pr-123-cloud");
  });
});
