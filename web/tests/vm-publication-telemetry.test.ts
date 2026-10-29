import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { context, trace } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { BasicTracerProvider, InMemorySpanExporter, SimpleSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { buildCmuxTraceSampler } from "../services/observability/sampler";
import { TRACE_ID_RESPONSE_HEADER } from "../services/telemetry";
import { tracePublicationAuthOperation, withPublicationAuthRequest } from "../services/vm-publications/requestTelemetry";

const exporter = new InMemorySpanExporter();
const provider = new BasicTracerProvider({
  sampler: buildCmuxTraceSampler({ CMUX_OTEL_BASE_SAMPLE_RATIO: "0" }),
  spanProcessors: [new SimpleSpanProcessor(exporter)],
});
trace.setGlobalTracerProvider(provider);
context.setGlobalContextManager(new AsyncLocalStorageContextManager().enable());
beforeEach(() => exporter.reset());
afterAll(async () => { await provider.shutdown(); trace.disable(); context.disable(); });

function request() {
  return new Request("https://cmux.com/api/freestyle/forward-auth?code=private-code", {
    headers: { cookie: "private-cookie", authorization: "Bearer private-credential" },
  });
}

describe("publication authorization telemetry", () => {
  test("keeps a slow request and its operation timings even when success sampling is zero", async () => {
    let now = 0;
    const response = await withPublicationAuthRequest(request(), async () => {
      await tracePublicationAuthOperation("database.findRequestContext", async () => { now += 900; });
      await tracePublicationAuthOperation("identity", async () => { now += 50; });
      return new Response(null, { status: 204 });
    }, { now: () => now });
    const spans = exporter.getFinishedSpans();
    expect(spans).toHaveLength(1);
    const span = spans[0]!;
    expect(span.name).toBe("cmux.publication_auth.outcome");
    expect(span.attributes["cmux.publication_auth.duration_ms"]).toBe(950);
    expect(span.attributes["cmux.publication_auth.slow"]).toBe(true);
    expect(span.events.map(event => event.attributes?.operation)).toEqual(["database.findRequestContext", "identity"]);
    expect(response.headers.get(TRACE_ID_RESPONSE_HEADER)).toBe(span.spanContext().traceId);
    const serialized = JSON.stringify(spans.map(span => ({ attributes: span.attributes, events: span.events })));
    for (const secret of ["private-code", "private-cookie", "private-credential"]) expect(serialized).not.toContain(secret);
  });

  test("keeps an infrastructure failure without exporting exception secrets", async () => {
    const response = await withPublicationAuthRequest(request(), async () => {
      try {
        await tracePublicationAuthOperation("database.findRequestContext", async () => {
          throw new Error("database unavailable: private-cookie private-credential");
        });
      } catch {
        return new Response(null, { status: 503 });
      }
      throw new Error("unreachable");
    });
    expect(response.status).toBe(503);
    const spans = exporter.getFinishedSpans();
    expect(spans).toHaveLength(1);
    expect(spans[0]!.events[0]!.attributes?.failed).toBe(true);
    expect(JSON.stringify(spans[0]!.events)).not.toContain("private-");
  });

  test("does not force ordinary successful or denied requests into the priority stream", async () => {
    for (const status of [204, 302, 401, 404]) {
      await withPublicationAuthRequest(request(), async () => new Response(null, { status }), { now: () => 0 });
    }
    expect(exporter.getFinishedSpans()).toHaveLength(0);
  });

  test("bounds retained operation records even when the handler throws", async () => {
    const response = await withPublicationAuthRequest(request(), async () => {
      for (let i = 0; i < 40; i++) await tracePublicationAuthOperation("identity", async () => undefined);
      throw new Error("private-credential");
    });
    expect(response.status).toBe(503);
    const span = exporter.getFinishedSpans()[0]!;
    expect(span.events).toHaveLength(32);
    expect(span.attributes["cmux.publication_auth.dropped_operations"]).toBe(9);
    expect(JSON.stringify(span.events)).not.toContain("private-credential");
  });

  test("keeps operation records separate for concurrent requests", async () => {
    await Promise.all(["database.findRequestContext", "identity"].map(operation =>
      withPublicationAuthRequest(request(), async () => {
        await tracePublicationAuthOperation(operation, async () => { await Promise.resolve(); });
        return new Response(null, { status: 503 });
      }),
    ));
    const spans = exporter.getFinishedSpans();
    expect(spans).toHaveLength(2);
    expect(spans.map(span => span.events.map(event => event.attributes?.operation)).sort()).toEqual([
      ["database.findRequestContext"], ["identity"],
    ]);
  });
});
