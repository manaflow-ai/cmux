import { describe, expect, test } from "bun:test";
import type { Span } from "@opentelemetry/api";

import {
  SPAN_ID_RESPONSE_HEADER,
  TRACE_ID_RESPONSE_HEADER,
  recordSpanError,
  spanTraceIds,
  summarizeErrorCauses,
  withTraceIdHeaders,
} from "../services/telemetry";
import {
  captureVmRequestOutcome,
  VM_ERROR_CODE_HEADER,
  VM_REQUEST_POSTHOG_EVENT,
} from "../services/vms/observability";
import {
  currentVmRequestContext,
  runWithVmRequestContext,
  traceIdFromTraceparent,
  vmClientIdentityFromRequest,
  type VmRequestContext,
} from "../services/vms/requestContext";
import { vmErrorResponse } from "../services/vms/routeHelpers";
import { ProviderError } from "../services/vms/drivers/types";

const TRACE_ID = "0af7651916cd43dd8448eb211c80319c";
const SPAN_ID = "b7ad6b7169203331";

function fakeSpan(options: { readonly valid?: boolean } = {}): { span: Span; attributes: Record<string, unknown> } {
  const attributes: Record<string, unknown> = {};
  const span = {
    setAttributes(values: Record<string, unknown>) {
      Object.assign(attributes, values);
      return span;
    },
    setAttribute(key: string, value: unknown) {
      attributes[key] = value;
      return span;
    },
    setStatus() {
      return span;
    },
    recordException() {},
    spanContext() {
      return options.valid === false
        ? { traceId: "0".repeat(32), spanId: "0".repeat(16), traceFlags: 0 }
        : { traceId: TRACE_ID, spanId: SPAN_ID, traceFlags: 1 };
    },
  } as unknown as Span;
  return { span, attributes };
}

function context(overrides: Partial<VmRequestContext> = {}): VmRequestContext {
  return {
    route: "/api/vm",
    method: "POST",
    operation: "create",
    startedAtMs: 0,
    client: { name: "cmux-mac", version: "1.2.3", channel: "nightly", requestId: "req-1" },
    userId: "user-1",
    traceId: TRACE_ID,
    spanId: SPAN_ID,
    ...overrides,
  };
}

type Captured = { batch: Array<{ event: string; distinct_id: string; properties: Record<string, unknown> }> } | null;

function capture(
  ctx: VmRequestContext,
  response: Response,
  span?: Span,
): { body: Captured; url: string | null } {
  let body: Captured = null;
  let url: string | null = null;
  const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
    url = String(input);
    body = JSON.parse(String(init?.body)) as Captured;
    return Promise.resolve(new Response("ok"));
  }) as typeof fetch;
  captureVmRequestOutcome(
    { context: ctx, response, span, durationMs: 42.123 },
    { fetch: fakeFetch, env: { CMUX_VM_ANALYTICS_FORCE: "1" } },
  );
  return { body, url };
}

describe("trace ids on responses", () => {
  test("route responses carry the trace and span id headers", () => {
    const { span } = fakeSpan();
    const response = withTraceIdHeaders(new Response("{}", { status: 200 }), span);
    expect(response.headers.get(TRACE_ID_RESPONSE_HEADER)).toBe(TRACE_ID);
    expect(response.headers.get(SPAN_ID_RESPONSE_HEADER)).toBe(SPAN_ID);
  });

  test("an invalid span context adds no headers", () => {
    const { span } = fakeSpan({ valid: false });
    const response = withTraceIdHeaders(new Response("{}"), span);
    expect(response.headers.get(TRACE_ID_RESPONSE_HEADER)).toBeNull();
    expect(spanTraceIds(span)).toBeUndefined();
  });

  test("immutable headers are re-wrapped instead of thrown", async () => {
    const { span } = fakeSpan();
    const immutable = await fetch(`data:application/json,${encodeURIComponent('{"ok":true}')}`);
    const response = withTraceIdHeaders(immutable, span);
    expect(response.headers.get(TRACE_ID_RESPONSE_HEADER)).toBe(TRACE_ID);
    expect(await response.json()).toEqual({ ok: true });
  });

  test("fake spans without a context are tolerated", () => {
    expect(spanTraceIds({} as Span)).toBeUndefined();
  });
});

describe("client identity and trace context from request headers", () => {
  test("reads the cmux client headers, a valid traceparent and the client request id", () => {
    const request = new Request("https://cmux.test/api/vm", {
      headers: {
        "x-cmux-client": "cmux-mac",
        "x-cmux-app-version": "0.65.0",
        "x-cmux-app-build": "1234",
        "x-cmux-channel": "nightly",
        "x-cmux-client-request-id": "8d2a6c1e-7f1b-4a3e-9a2c-0c1d2e3f4a5b",
        traceparent: `00-${TRACE_ID}-${SPAN_ID}-01`,
        "user-agent": "cmux/0.65.0",
      },
    });
    expect(vmClientIdentityFromRequest(request)).toEqual({
      name: "cmux-mac",
      version: "0.65.0",
      build: "1234",
      channel: "nightly",
      userAgent: "cmux/0.65.0",
      requestId: "8d2a6c1e-7f1b-4a3e-9a2c-0c1d2e3f4a5b",
      traceId: TRACE_ID,
    });
  });

  test("malformed ids and control characters are dropped, values are bounded", () => {
    const request = new Request("https://cmux.test/api/vm", {
      headers: {
        "x-cmux-client-request-id": "not valid because of spaces",
        traceparent: "garbage",
        "x-cmux-app-version": `${"a".repeat(200)}`,
      },
    });
    const identity = vmClientIdentityFromRequest(request);
    expect(identity.requestId).toBeUndefined();
    expect(identity.traceId).toBeUndefined();
    expect(identity.version).toBe("a".repeat(120));
    expect(identity.name).toBeUndefined();
  });

  test("traceparent parsing rejects all-zero trace ids", () => {
    expect(traceIdFromTraceparent(`00-${"0".repeat(32)}-${SPAN_ID}-01`)).toBeUndefined();
    expect(traceIdFromTraceparent(`00-${TRACE_ID.toUpperCase()}-${SPAN_ID}-00`)).toBe(TRACE_ID);
    expect(traceIdFromTraceparent(null)).toBeUndefined();
  });

  test("the request context is visible inside the run scope only", () => {
    const ctx = context();
    expect(currentVmRequestContext()).toBeUndefined();
    runWithVmRequestContext(ctx, () => {
      expect(currentVmRequestContext()).toBe(ctx);
    });
    expect(currentVmRequestContext()).toBeUndefined();
  });
});

describe("vm error payloads", () => {
  test("record the error on the request context for the finalizer", () => {
    const ctx = context();
    runWithVmRequestContext(ctx, () => {
      vmErrorResponse({
        error: "vm_billing_team_required",
        status: 409,
        message: "Select a team.",
        action: "Select a team in cmux, then retry.",
        phase: "billing",
      });
    });
    expect(ctx.lastError?.error).toBe("vm_billing_team_required");
    expect(ctx.lastError?.phase).toBe("billing");
  });

  test("carry no trace id when no span is active", async () => {
    const response = vmErrorResponse({
      error: "vm_internal_error",
      status: 500,
      message: "boom",
      action: "retry",
    });
    const payload = await response.json() as { traceId?: string; ui: { traceId?: string } };
    expect(payload.traceId).toBeUndefined();
    expect(payload.ui.traceId).toBeUndefined();
  });
});

describe("error cause chains on spans", () => {
  test("the innermost provider failure reaches the span", () => {
    const apiError = Object.assign(new Error("snapshot 'sh-abc' not found; Bearer secret-token-value"), {
      name: "FreestyleApiError",
      status: 404,
      body: { code: "SNAPSHOT_NOT_FOUND" },
    });
    const wrapped = new ProviderError("freestyle", "create(sh-abc) failed", apiError);
    const summary = summarizeErrorCauses(wrapped);
    expect(summary?.depth).toBe(1);
    expect(summary?.httpStatus).toBe(404);
    expect(summary?.code).toBe("SNAPSHOT_NOT_FOUND");
    expect(summary?.chain).toContain("FreestyleApiError: snapshot 'sh-abc' not found");
    expect(summary?.chain).not.toContain("secret-token-value");

    const { span, attributes } = fakeSpan();
    recordSpanError(span, wrapped);
    expect(attributes["cmux.error_name"]).toBe("ProviderError");
    expect(attributes["cmux.error_cause_http_status"]).toBe(404);
    expect(attributes["cmux.error_cause_code"]).toBe("SNAPSHOT_NOT_FOUND");
    expect(attributes["cmux.error_cause_depth"]).toBe(1);
  });

  test("errors without a cause add no cause attributes and cycles terminate", () => {
    expect(summarizeErrorCauses(new Error("plain"))).toBeUndefined();
    const a: Error & { cause?: unknown } = new Error("a");
    const b: Error & { cause?: unknown } = new Error("b");
    a.cause = b;
    b.cause = a;
    const summary = summarizeErrorCauses(a);
    expect(summary?.depth).toBe(2);
  });
});

describe("cloud_vm_request capture", () => {
  test("a failure ships cloud_vm_request and $exception with the trace id and error detail", () => {
    const ctx = context();
    const { span, attributes } = fakeSpan();
    const response = runWithVmRequestContext(ctx, () => vmErrorResponse({
      error: "vm_cloud_service_unavailable",
      status: 502,
      message: "Cloud VM service is temporarily unavailable.",
      action: "retry",
      reason: "Cloud VM service is temporarily unavailable: upstream 503",
      phase: "create",
      retryable: true,
      diagnostics: { provider: "freestyle" },
    }));
    expect(response.headers.get(VM_ERROR_CODE_HEADER)).toBe("vm_cloud_service_unavailable");
    const { body, url } = capture(ctx, response, span);
    expect(url).toContain("/batch/");
    expect(body?.batch.map((entry) => entry.event)).toEqual([VM_REQUEST_POSTHOG_EVENT, "$exception"]);
    const [request, exception] = body!.batch;
    expect(request.distinct_id).toBe("user-1");
    expect(request.properties).toMatchObject({
      operation: "create",
      route: "/api/vm",
      method: "POST",
      success: false,
      status: 502,
      duration_ms: 42.12,
      error_code: "vm_cloud_service_unavailable",
      error_phase: "create",
      retryable: true,
      operator_fault: true,
      provider: "freestyle",
      trace_id: TRACE_ID,
      span_id: SPAN_ID,
      client_request_id: "req-1",
      client_name: "cmux-mac",
      client_version: "1.2.3",
      client_channel: "nightly",
      schema_version: 1,
    });
    expect(exception.properties).toMatchObject({
      trace_id: TRACE_ID,
      error_code: "vm_cloud_service_unavailable",
      $exception_level: "error",
      $exception_fingerprint: "cmux-vm-error:vm_cloud_service_unavailable",
    });
    const list = JSON.parse(String(exception.properties.$exception_list)) as Array<{ type: string; value: string }>;
    expect(list[0].type).toBe("vm_cloud_service_unavailable");
    expect(list[0].value).toContain("upstream 503");
    expect(attributes["cmux.vm.request_success"]).toBe(false);
    expect(attributes["cmux.vm.request_duration_ms"]).toBe(42.12);
    expect(attributes["cmux.vm.request_error_code"]).toBe("vm_cloud_service_unavailable");
    expect(attributes["cmux.user_id"]).toBe("user-1");
    expect(attributes["cmux.client.request_id"]).toBe("req-1");
  });

  test("a user-fault failure is a warning-level exception", () => {
    const ctx = context({ operation: "status", method: "GET", route: "/api/vm/[id]" });
    const response = runWithVmRequestContext(ctx, () => vmErrorResponse({
      error: "vm_not_found",
      status: 404,
      message: "not found",
      action: "list",
      phase: "status",
    }));
    const { body } = capture(ctx, response);
    expect(body?.batch).toHaveLength(2);
    expect(body?.batch[0].properties.operator_fault).toBe(false);
    expect(body?.batch[1].properties.$exception_level).toBe("warning");
  });

  test("an error that bypassed vmErrorResponse is still captured by status", () => {
    const ctx = context({ operation: "open_attach" });
    const { body } = capture(ctx, new Response('{"error":"invalid_request"}', { status: 400 }));
    expect(body?.batch[0].properties).toMatchObject({ success: false, status: 400, operator_fault: false });
    expect(body?.batch[0].properties.error_code).toBeUndefined();
    expect(body?.batch[1].properties.error_code).toBe("http_400");
  });

  test("a create success ships one cloud_vm_request with its latency and no exception", () => {
    const ctx = context();
    const { body } = capture(ctx, new Response("{}", { status: 200 }));
    expect(body?.batch.map((entry) => entry.event)).toEqual([VM_REQUEST_POSTHOG_EVENT]);
    expect(body?.batch[0].properties).toMatchObject({ success: true, status: 200, duration_ms: 42.12, operation: "create" });
    expect(body?.batch[0].properties.error_code).toBeUndefined();
  });

  test("polled read successes stay out of PostHog but still annotate the span", () => {
    for (const operation of ["list", "status", "stats", "list_sessions", "get_tunnel"]) {
      const ctx = context({ operation, method: "GET" });
      const { span, attributes } = fakeSpan();
      const { body } = capture(ctx, new Response("{}", { status: 200 }), span);
      expect(body).toBeNull();
      expect(attributes["cmux.vm.request_success"]).toBe(true);
    }
  });

  test("polled read failures are captured", () => {
    const ctx = context({ operation: "list", method: "GET" });
    const { body } = capture(ctx, new Response("{}", { status: 503 }));
    expect(body?.batch).toHaveLength(2);
  });

  test("an unauthenticated failure uses the anonymous distinct id", () => {
    const ctx = context({ userId: undefined });
    const { body } = capture(ctx, new Response('{"error":"unauthorized"}', { status: 401 }));
    expect(body?.batch[0].distinct_id).toBe("cmux-vm-anonymous");
  });

  test("nothing is sent outside production without the force flag", () => {
    let called = false;
    captureVmRequestOutcome(
      { context: context(), response: new Response("{}", { status: 500 }), durationMs: 1 },
      { fetch: (() => { called = true; return Promise.resolve(new Response("ok")); }) as typeof fetch, env: {} },
    );
    expect(called).toBe(false);
  });

  test("the client trace id is the fallback reference when the span has none", () => {
    const ctx = context({ traceId: undefined, spanId: undefined, client: { traceId: "c".repeat(32) } });
    const { body } = capture(ctx, new Response("{}", { status: 500 }));
    expect(body?.batch[0].properties.trace_id).toBeUndefined();
    expect(body?.batch[0].properties.client_trace_id).toBe("c".repeat(32));
  });
});
