import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";

import * as analytics from "../services/coderouter/analytics";
import {
  CODEROUTER_REQUEST_ID_HEADER,
  classifyCoderouterFault,
  coderouterControlRoute,
  currentCoderouterRequest,
  newCoderouterRequestContext,
  recordCoderouterIdentity,
  recordCoderouterOutcome,
  recordCoderouterSpan,
  runWithCoderouterRequest,
  traceEvents,
  withCoderouterRoute,
} from "../services/coderouter/requestTelemetry";
import { exceptionEvent, stackFrames } from "../services/coderouter/exceptionEvent";
import { authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";
import { TRACE_ID_RESPONSE_HEADER } from "../services/telemetry";

type Captured = { event: string; teamId?: string; timestamp?: string; properties: Record<string, unknown> };

let rawBatch: ReturnType<typeof spyOn<typeof analytics, "captureCoderouterRawBatch">>;

/** Every event handed to the PostHog batch sink so far in this test. */
function captured(): Captured[] {
  return rawBatch.mock.calls.flatMap(([events]) =>
    events.map((entry) => ({
      event: entry.event,
      ...(entry.teamId ? { teamId: entry.teamId } : {}),
      ...(entry.timestamp ? { timestamp: entry.timestamp } : {}),
      properties: { ...entry.properties },
    })));
}

beforeEach(() => {
  // The real sink is disabled outside production, so spying without a
  // replacement keeps the batch out of the network while exposing the calls.
  rawBatch = spyOn(analytics, "captureCoderouterRawBatch");
});

afterEach(() => {
  rawBatch.mockRestore();
});

describe("classifyCoderouterFault", () => {
  test("splits outcomes by who can fix them", () => {
    expect(classifyCoderouterFault({ outcome: "success", failureStage: "none", status: 200 })).toBe("none");
    expect(classifyCoderouterFault({ outcome: "unauthorized", failureStage: "auth", status: 401 })).toBe("caller");
    expect(classifyCoderouterFault({ outcome: "client_error", failureStage: "request", status: 413 })).toBe("caller");
    expect(classifyCoderouterFault({ outcome: "route_crash", failureStage: "handler", status: 503 })).toBe("operator");
    expect(classifyCoderouterFault({ outcome: "provider_unavailable", failureStage: "account_selection", status: 503 })).toBe("operator");
    expect(classifyCoderouterFault({ outcome: "provider_unavailable", failureStage: "upstream_transport", status: 502 })).toBe("upstream");
    expect(classifyCoderouterFault({ outcome: "provider_unavailable", failureStage: "provider_config", status: 502 })).toBe("upstream");
    expect(classifyCoderouterFault({ outcome: "no_usable_account", failureStage: "provider_config", status: 503 })).toBe("tenant");
    expect(classifyCoderouterFault({ outcome: "no_usable_account", failureStage: "account_selection", status: 503 })).toBe("tenant");
    expect(classifyCoderouterFault({ outcome: "no_usable_account", failureStage: "credential_refresh", status: 503 })).toBe("upstream");
    expect(classifyCoderouterFault({ outcome: "upstream_error", failureStage: "upstream_response", status: 529 })).toBe("upstream");
    expect(classifyCoderouterFault({ outcome: "server_error", failureStage: "handler", status: 500 })).toBe("operator");
  });
});

describe("traceEvents", () => {
  test("builds one $ai_trace root, one $ai_span per step, and no $exception on success", () => {
    const request = new Request("https://coderouter.dev/v1/messages", { method: "POST" });
    const context = newCoderouterRequestContext({ request, surface: "messages", route: "/v1/messages", requestId: "req-1" });
    context.traceId = "0af7651916cd43dd8448eb211c80319c";
    runWithCoderouterRequest(context, () => {
      recordCoderouterIdentity({ teamId: "team-raw", stackUserId: "user-raw", vmId: "vm-1" });
      recordCoderouterSpan({ name: "auth", startedAt: context.startedAt, attributes: { outcome: "accepted", token: "crt_secret" } });
      recordCoderouterSpan({ name: "upstream_attempt", startedAt: context.startedAt, attributes: { provider: "claude", status: 200 } });
      recordCoderouterOutcome({
        outcome: "success",
        failureStage: "none",
        status: 200,
        provider: "claude",
        agent: "claude",
        attempts: 1,
        responseStreamed: true,
        upstreamKind: "bedrock",
      });
    });
    const events = traceEvents(context, { status: 200, durationMs: 1234 });
    expect(events.map((entry) => entry.event)).toEqual(["$ai_trace", "$ai_span", "$ai_span"]);
    const root = events[0]!;
    expect(root.teamId).toBe("team-raw");
    expect(root.properties.$ai_trace_id).toBe("req-1");
    expect(root.properties.$ai_latency).toBe(1.234);
    expect(root.properties.$ai_is_error).toBe(false);
    expect(root.properties.$ai_http_status).toBe(200);
    expect(root.properties.coderouter_fault).toBe("none");
    expect(root.properties.coderouter_vm_id).toBe("vm-1");
    expect(root.properties.trace_id).toBe("0af7651916cd43dd8448eb211c80319c");
    expect(root.properties.upstream_kind).toBe("bedrock");
    const auth = events[1]!;
    expect(auth.properties.$ai_parent_id).toBe("req-1");
    expect(auth.properties.$ai_span_name).toBe("auth");
    expect(auth.properties.token).toBeUndefined();
    expect(typeof auth.properties.$ai_span_id).toBe("string");
    expect(typeof auth.timestamp).toBe("string");
  });

  test("files an error-level $exception for an operator fault and a warning for an upstream one", () => {
    const request = new Request("https://coderouter.dev/v1/responses", { method: "POST" });
    const operator = newCoderouterRequestContext({ request, surface: "responses", route: "/v1/responses", requestId: "req-2" });
    operator.outcome = { outcome: "provider_unavailable", failureStage: "account_selection", status: 503, provider: "codex" };
    const operatorEvents = traceEvents(operator, { status: 503, durationMs: 50 });
    const exception = operatorEvents.find((entry) => entry.event === "$exception")!;
    expect(exception.properties.$exception_level).toBe("error");
    expect(exception.properties.$exception_fingerprint).toBe("coderouter:provider_unavailable:account_selection:codex");
    expect(exception.properties.$ai_trace_id).toBe("req-2");
    expect(JSON.parse(String(exception.properties.$exception_list))[0].type).toBe("coderouter_provider_unavailable");
    expect(operatorEvents[0]!.properties.$ai_is_error).toBe(true);
    expect(operatorEvents[0]!.properties.$ai_error).toBe("provider_unavailable/account_selection");

    const upstream = newCoderouterRequestContext({ request, surface: "responses", route: "/v1/responses", requestId: "req-3" });
    upstream.outcome = { outcome: "upstream_error", failureStage: "upstream_response", status: 529, provider: "claude" };
    const warning = traceEvents(upstream, { status: 529, durationMs: 50 }).find((entry) => entry.event === "$exception")!;
    expect(warning.properties.$exception_level).toBe("warning");
  });

  test("a caller fault produces a trace but no $exception", () => {
    const request = new Request("https://coderouter.dev/v1/responses", { method: "POST" });
    const context = newCoderouterRequestContext({ request, surface: "responses", route: "/v1/responses", requestId: "req-4" });
    context.outcome = { outcome: "unauthorized", failureStage: "auth", status: 401, provider: "codex" };
    const events = traceEvents(context, { status: 401, durationMs: 5 });
    expect(events.map((entry) => entry.event)).toEqual(["$ai_trace"]);
    expect(events[0]!.properties.$ai_is_error).toBe(false);
    expect(events[0]!.properties.coderouter_fault).toBe("caller");
  });

  test("an unhandled throw becomes a route_crash with the real stack", () => {
    const request = new Request("https://coderouter.dev/v1/responses", { method: "POST" });
    const context = newCoderouterRequestContext({ request, surface: "responses", route: "/v1/responses", requestId: "req-5" });
    const error = new TypeError("boom Bearer sk-ant-secret-value-1234567890");
    const events = traceEvents(context, { status: 503, durationMs: 5, error });
    const exception = events.find((entry) => entry.event === "$exception")!;
    const list = JSON.parse(String(exception.properties.$exception_list));
    expect(list[0].type).toBe("TypeError");
    expect(list[0].value).toBe("TypeError: boom [redacted]");
    expect(list[0].mechanism.handled).toBe(false);
    expect(list[0].stacktrace.type).toBe("raw");
    expect(list[0].stacktrace.frames.length).toBeGreaterThan(0);
    expect(exception.properties.$exception_level).toBe("error");
    expect(exception.properties.coderouter_outcome).toBe("route_crash");
  });
});

describe("stackFrames", () => {
  test("parses V8 frames outermost first and marks node_modules as not in_app", () => {
    const error = new Error("x");
    error.stack = [
      "Error: x",
      "    at inner (/app/web/services/coderouter/codexProxy.ts:10:5)",
      "    at /app/web/node_modules/next/dist/server.js:1:1",
      "    at outer (node:internal/process/task_queues:95:5)",
    ].join("\n");
    const frames = stackFrames(error);
    expect(frames.map((frame) => frame.function)).toEqual(["outer", "<anonymous>", "inner"]);
    expect(frames.map((frame) => frame.in_app)).toEqual([false, false, true]);
    expect(frames[2]).toMatchObject({ lineno: 10, colno: 5, platform: "node:javascript" });
  });

  test("exceptionEvent scrubs message text and drops nothing else", () => {
    const event = exceptionEvent({
      type: "coderouter.rds",
      value: "connect failed for crt_0123456789abcdef0123456789abcdef",
      fingerprint: "coderouter.rds:codex",
      level: "error",
      properties: { coderouter_failure: "rds", skipped: null },
    });
    const list = JSON.parse(String(event.properties.$exception_list));
    expect(list[0].value).toBe("connect failed for [redacted]");
    expect(list[0].mechanism.synthetic).toBe(true);
    expect(event.properties.coderouter_failure).toBe("rds");
    expect("skipped" in event.properties).toBe(false);
  });
});

describe("withCoderouterRoute", () => {
  test("stamps request and trace ids, runs the handler in a context, and ships the batch", async () => {
    const route = withCoderouterRoute(
      { surface: "responses", route: "/v1/responses", unavailable: () => new Response("nope", { status: 503 }) },
      async () => {
        const context = currentCoderouterRequest();
        expect(context?.surface).toBe("responses");
        recordCoderouterOutcome({ outcome: "success", failureStage: "none", status: 200, provider: "codex", agent: "codex", attempts: 1 });
        return new Response("ok", { status: 200 });
      },
    );
    const response = await route(new Request("https://coderouter.dev/v1/responses", { method: "POST" }), undefined);
    expect(response.status).toBe(200);
    const requestId = response.headers.get(CODEROUTER_REQUEST_ID_HEADER);
    expect(requestId).toMatch(/^[0-9a-f-]{36}$/);
    // No tracer provider is registered in tests, so the OTel header is absent
    // (the VM routes behave the same); the request id is always present.
    expect(response.headers.get(TRACE_ID_RESPONSE_HEADER)).toBeNull();
    expect(rawBatch).toHaveBeenCalledTimes(1);
    expect(captured()[0]!.event).toBe("$ai_trace");
    expect(captured()[0]!.properties.$ai_trace_id).toBe(requestId);
    expect(captured()[0]!.properties.coderouter_outcome).toBe("success");
  });

  test("an unhandled throw answers with the surface's 503 and files a route_crash exception", async () => {
    const route = withCoderouterRoute(
      {
        surface: "messages",
        route: "/v1/messages",
        unavailable: () => Response.json({ type: "error" }, { status: 503 }),
      },
      async () => {
        throw new RangeError("exploded");
      },
    );
    const response = await route(new Request("https://coderouter.dev/v1/messages", { method: "POST" }), undefined);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ type: "error" });
    expect(response.headers.get(CODEROUTER_REQUEST_ID_HEADER)).toBeTruthy();
    // reportCoderouterFailure("route_crash") files one $exception, the
    // finalizer files the trace batch with a second one for the request.
    const exceptions = captured().filter((entry) => entry.event === "$exception");
    expect(exceptions.length).toBe(2);
    expect(exceptions.some((entry) => entry.properties.coderouter_failure === "route_crash")).toBe(true);
    const trace = captured().find((entry) => entry.event === "$ai_trace")!;
    expect(trace.properties.coderouter_outcome).toBe("route_crash");
    expect(trace.properties.$ai_is_error).toBe(true);
  });

  test("control-plane routes derive the outcome from the status", async () => {
    const route = coderouterControlRoute("accounts", "/api/coderouter/accounts", async () => new Response(null, { status: 500 }));
    const response = await route(new Request("https://cmux.com/api/coderouter/accounts"), undefined);
    expect(response.status).toBe(500);
    const trace = captured().find((entry) => entry.event === "$ai_trace")!;
    expect(trace.properties.coderouter_outcome).toBe("server_error");
    expect(trace.properties.coderouter_fault).toBe("operator");
    expect(captured().some((entry) => entry.event === "$exception")).toBe(true);
  });

  test("a response with immutable headers is re-wrapped so the id still lands", async () => {
    const route = coderouterControlRoute("vm_usage", "/api/coderouter/vm-usage", async () => {
      const upstream = await fetch("data:text/plain,hello");
      return upstream;
    });
    const response = await route(new Request("https://cmux.com/api/coderouter/vm-usage"), undefined);
    expect(response.headers.get(CODEROUTER_REQUEST_ID_HEADER)).toBeTruthy();
    expect(await response.text()).toBe("hello");
  });
});

describe("route token auth spans", () => {
  test("records an auth span and the identity on the active request", async () => {
    const request = new Request("https://coderouter.dev/v1/responses", {
      headers: { authorization: "Bearer crt_abcdefghijklmnopqrstuvwxyz0123456789" },
    });
    const context = newCoderouterRequestContext({ request, surface: "responses", route: "/v1/responses" });
    await runWithCoderouterRequest(context, async () => {
      const result = await authenticateRequestRouteToken(request, async () => ({
        teamId: "team-1",
        stackUserId: "user-1",
        vmId: null,
      }));
      expect(result.ok).toBe(true);
    });
    expect(context.identity).toEqual({ teamId: "team-1", stackUserId: "user-1", vmId: null });
    expect(context.spans.map((span) => span.name)).toEqual(["auth"]);
    expect(context.spans[0]!.attributes.outcome).toBe("accepted");

    const rejected = newCoderouterRequestContext({ request, surface: "responses", route: "/v1/responses" });
    await runWithCoderouterRequest(rejected, async () => {
      await authenticateRequestRouteToken(request, async () => null);
    });
    expect(rejected.identity).toBeUndefined();
    expect(rejected.spans[0]!.error).toBe("invalid_route_token");
  });
});
