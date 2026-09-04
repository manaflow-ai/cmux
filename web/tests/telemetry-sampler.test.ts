import { afterAll, describe, expect, test } from "bun:test";
import { context as otelContext, trace, TraceFlags, type Span } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import {
  BasicTracerProvider,
  InMemorySpanExporter,
  SamplingDecision,
  SimpleSpanProcessor,
} from "@opentelemetry/sdk-trace-base";

import { buildCmuxTraceSampler, isPriorityPath, isPrioritySpan, isVmPrioritySpan } from "../services/observability/sampler";
import { recordSpanError, withApiRouteSpan, withPrioritySpan } from "../services/telemetry";

describe("buildCmuxTraceSampler", () => {
  const neverSample = buildCmuxTraceSampler({ CMUX_OTEL_BASE_SAMPLE_RATIO: "0" });
  const root = otelContext.active();

  function decideRoot(name: string, attributes: Record<string, string>): SamplingDecision {
    return neverSample.shouldSample(root, "0af7651916cd43dd8448eb211c80319c", name, 1, attributes, [])
      .decision;
  }

  test("vm routes are always kept, judged by creation-time signals", () => {
    expect(decideRoot("POST /api/vm", { "http.route": "/api/vm" })).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
    expect(decideRoot("POST", { "http.target": "/api/vm/abc/attach-endpoint" })).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
    expect(decideRoot("cmux.api.POST /api/vm/base/open", {})).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
    expect(decideRoot("anything", { "cmux.subsystem": "vm-cloud" })).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
  });

  test("coderouter data-plane and control-plane routes are always kept", () => {
    expect(decideRoot("POST /v1/responses", { "http.route": "/v1/responses" })).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
    expect(decideRoot("cmux.api.POST /v1/messages", {})).toBe(SamplingDecision.RECORD_AND_SAMPLED);
    expect(decideRoot("GET", { "url.path": "/api/coderouter/opencode/config" })).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
    expect(decideRoot("anything", { "cmux.subsystem": "coderouter" })).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
    expect(decideRoot("GET /v1beta/other", { "http.route": "/v1beta/other" })).toBe(
      SamplingDecision.NOT_RECORD,
    );
    expect(isPriorityPath("/v1/models?x=1")).toBe(true);
    expect(isPriorityPath("/v10/models")).toBe(false);
    expect(isPriorityPath("/api/coderouterx")).toBe(false);
    expect(isPrioritySpan("GET /api/coderouter/health", { "cmux.priority": false })).toBe(false);
    expect(decideRoot("GET /api/admin/pro-users", { "http.route": "/api/admin/pro-users" })).toBe(
      SamplingDecision.RECORD_AND_SAMPLED,
    );
  });

  test("a client-sent sampled traceparent cannot bypass the ratio", () => {
    const remoteSampled = trace.setSpanContext(root, {
      traceId: "2af7651916cd43dd8448eb211c80319c",
      spanId: "c7ad6b7169203331",
      traceFlags: TraceFlags.SAMPLED,
      isRemote: true,
    });
    expect(
      neverSample.shouldSample(
        remoteSampled,
        "2af7651916cd43dd8448eb211c80319c",
        "GET /",
        1,
        { "http.route": "/" },
        [],
      ).decision,
    ).toBe(SamplingDecision.NOT_RECORD);
    expect(
      neverSample.shouldSample(
        remoteSampled,
        "2af7651916cd43dd8448eb211c80319c",
        "POST /api/vm",
        1,
        { "http.route": "/api/vm" },
        [],
      ).decision,
    ).toBe(SamplingDecision.RECORD_AND_SAMPLED);
  });

  test("everything else follows the base ratio", () => {
    expect(decideRoot("GET /", { "http.route": "/" })).toBe(SamplingDecision.NOT_RECORD);
    expect(decideRoot("GET /api/devices", { "http.route": "/api/devices" })).toBe(
      SamplingDecision.NOT_RECORD,
    );
    const alwaysSample = buildCmuxTraceSampler({ CMUX_OTEL_BASE_SAMPLE_RATIO: "1" });
    expect(
      alwaysSample.shouldSample(root, "0af7651916cd43dd8448eb211c80319c", "GET /", 1, {}, [])
        .decision,
    ).toBe(SamplingDecision.RECORD_AND_SAMPLED);
  });

  test("invalid or missing ratios fall back to the default without throwing", () => {
    for (const raw of [undefined, "", "nan", "-1", "7"]) {
      expect(() => buildCmuxTraceSampler({ CMUX_OTEL_BASE_SAMPLE_RATIO: raw })).not.toThrow();
    }
  });

  test("isVmPrioritySpan does not match unrelated paths", () => {
    expect(isVmPrioritySpan("GET /api/vmstats-lookalike", {})).toBe(false);
    expect(isVmPrioritySpan("GET", { "url.path": "/api/devices" })).toBe(false);
    expect(isVmPrioritySpan("POST /v1/responses", { "http.route": "/v1/responses" })).toBe(false);
    expect(isVmPrioritySpan("anything", { "cmux.subsystem": "coderouter" })).toBe(false);
    // Prefix semantics are intentional: /api/vm/... and /api/vm itself.
    expect(isVmPrioritySpan("GET", { "url.path": "/api/vm" })).toBe(true);
  });

});

describe("withApiRouteSpan re-rooting under head sampling", () => {
  const exporter = new InMemorySpanExporter();
  const provider = new BasicTracerProvider({
    sampler: buildCmuxTraceSampler({ CMUX_OTEL_BASE_SAMPLE_RATIO: "0" }),
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  trace.setGlobalTracerProvider(provider);
  // The API's default context manager is a no-op (`context.with` does not
  // propagate); production gets a real one from @vercel/otel's registerOTel.
  const contextManager = new AsyncLocalStorageContextManager().enable();
  otelContext.setGlobalContextManager(contextManager);

  afterAll(async () => {
    await provider.shutdown();
    trace.disable();
    otelContext.disable();
  });

  function unsampledParentContext() {
    return trace.setSpanContext(otelContext.active(), {
      traceId: "1af7651916cd43dd8448eb211c80319c",
      spanId: "b7ad6b7169203331",
      traceFlags: TraceFlags.NONE,
    });
  }

  test("a vm route under a dropped trace re-roots and is exported with a link", async () => {
    exporter.reset();
    await otelContext.with(unsampledParentContext(), () =>
      withApiRouteSpan(
        new Request("https://cmux.com/api/vm", { method: "POST" }),
        "/api/vm",
        { "cmux.subsystem": "vm-cloud" },
        async () => new Response("{}", { status: 200 }),
      ));
    const spans = exporter.getFinishedSpans();
    expect(spans.length).toBe(1);
    const span = spans[0]!;
    expect(span.name).toBe("cmux.api.POST /api/vm");
    // New trace, not the dropped parent's.
    expect(span.spanContext().traceId).not.toBe("1af7651916cd43dd8448eb211c80319c");
    expect(span.parentSpanContext).toBeUndefined();
    expect(span.links.length).toBe(1);
    expect(span.links[0]?.context.traceId).toBe("1af7651916cd43dd8448eb211c80319c");
  });

  test("a non-vm route under a dropped trace stays dropped", async () => {
    exporter.reset();
    await otelContext.with(unsampledParentContext(), () =>
      withApiRouteSpan(
        new Request("https://cmux.com/api/devices", { method: "GET" }),
        "/api/devices",
        {},
        async () => new Response("{}", { status: 200 }),
      ));
    expect(exporter.getFinishedSpans().length).toBe(0);
  });

  test("explicit priority spans are kept and linked when the request is dropped", async () => {
    exporter.reset();
    await otelContext.with(unsampledParentContext(), () =>
      withPrioritySpan(
        "cmux-dashboard",
        "cmux.dashboard.auth",
        { "http.route": "/dashboard" },
        async () => undefined,
      ));
    const spans = exporter.getFinishedSpans();
    expect(spans.length).toBe(1);
    expect(spans[0]?.name).toBe("cmux.dashboard.auth");
    expect(spans[0]?.parentSpanContext).toBeUndefined();
    expect(spans[0]?.links[0]?.context.traceId).toBe("1af7651916cd43dd8448eb211c80319c");
  });

  test("priority marker cannot be disabled by caller attributes", async () => {
    exporter.reset();
    await withPrioritySpan(
      "cmux-dashboard",
      "cmux.dashboard.auth",
      { "cmux.priority": false },
      async () => undefined,
    );
    expect(exporter.getFinishedSpans()[0]?.attributes["cmux.priority"]).toBe(true);
  });

  test("every span error sink redacts sensitive Error metadata", () => {
    let recorded: unknown;
    let status: unknown;
    const attributes: Record<string, unknown> = {};
    const span = {
      recordException(exception: unknown) {
        recorded = exception;
      },
      setStatus(value: unknown) {
        status = value;
      },
      setAttributes(value: Record<string, unknown>) {
        Object.assign(attributes, value);
      },
    } as unknown as Span;
    const cause = Object.assign(new Error("cause Bearer cause-secret-token"), {
      name: "Cause Bearer cause-name-secret",
      code: "crt_0123456789abcdef0123456789abcdef",
    });
    const error = new Error("request failed Bearer super-secret-token", { cause });
    error.name = "Top Bearer top-name-secret";
    recordSpanError(span, error);
    expect(recorded).toEqual({
      name: "Top [redacted]",
      message: "request failed [redacted]",
      stack: expect.stringContaining("request failed [redacted]"),
    });
    expect(status).toEqual({ code: 2, message: "request failed [redacted]" });
    expect(attributes).toMatchObject({
      "cmux.error_name": "Top [redacted]",
      "cmux.error_message": "request failed [redacted]",
      "cmux.error_cause_chain": "Cause [redacted]: cause [redacted]",
      "cmux.error_cause_code": "[redacted]",
    });
    expect(JSON.stringify({ recorded, status, attributes })).not.toContain("secret");
  });

  test("non-Error inputs are redacted in every span sink", () => {
    let recorded: unknown;
    let status: unknown;
    const attributes: Record<string, unknown> = {};
    const span = {
      recordException(exception: unknown) {
        recorded = exception;
      },
      setStatus(value: unknown) {
        status = value;
      },
      setAttributes(value: Record<string, unknown>) {
        Object.assign(attributes, value);
      },
    } as unknown as Span;
    recordSpanError(span, "request failed Bearer primitive-secret-token");
    expect(recorded).toBe("request failed [redacted]");
    expect(status).toEqual({ code: 2, message: "request failed [redacted]" });
    expect(attributes).toEqual({
      "cmux.error_name": "NonError",
      "cmux.error_message": "request failed [redacted]",
    });
  });

  test("a vm route inside a sampled trace nests normally", async () => {
    exporter.reset();
    const tracer = trace.getTracer("test");
    await tracer.startActiveSpan("POST /api/vm", { attributes: { "http.route": "/api/vm" } }, async (parent) => {
      await withApiRouteSpan(
        new Request("https://cmux.com/api/vm", { method: "POST" }),
        "/api/vm",
        { "cmux.subsystem": "vm-cloud" },
        async () => new Response("{}", { status: 200 }),
      );
      parent.end();
    });
    const spans = exporter.getFinishedSpans();
    expect(spans.length).toBe(2);
    const child = spans.find((s) => s.name === "cmux.api.POST /api/vm");
    const parent = spans.find((s) => s.name === "POST /api/vm");
    expect(child?.parentSpanContext?.spanId).toBe(parent?.spanContext().spanId);
    expect(child?.links.length ?? 0).toBe(0);
  });
});
