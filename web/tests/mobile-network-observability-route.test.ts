import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";

import { makeMobileNetworkOutcomeHandler } from "../app/api/observability/mobile-network/route";
import type { MobileObservabilityEvent } from "../services/observability/mobileNetworkOutcome";

const originalVercel = process.env.VERCEL;
const originalRuleId = process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID;

let authenticatedUser: { readonly id: string } | null = { id: "user-7" };
let authError: unknown = null;
let emitError: unknown = null;
let flushResult = true;
let rateLimitResult: Awaited<ReturnType<typeof checkVercelRateLimit>> = { rateLimited: false };
const emitted: Array<{ readonly userId: string; readonly batch: readonly MobileObservabilityEvent[] }> = [];
const flushTimeouts: Array<number | undefined> = [];

const verifyRequest = mock(async () => {
  if (authError) throw authError;
  return authenticatedUser;
});
const checkRateLimit: typeof checkVercelRateLimit = async () => rateLimitResult;
const emitOutcomes = async (userId: string, batch: readonly MobileObservabilityEvent[]): Promise<void> => {
  if (emitError) throw emitError;
  emitted.push({ userId, batch });
};
const flushTraces = async (timeoutMs?: number): Promise<boolean> => {
  flushTimeouts.push(timeoutMs);
  return flushResult;
};
const POST = makeMobileNetworkOutcomeHandler({
  verifyRequest,
  checkRateLimit,
  emitOutcomes,
  flushTraces,
});

beforeEach(() => {
  delete process.env.VERCEL;
  process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID = "mobile-observability-test";
  authenticatedUser = { id: "user-7" };
  authError = null;
  emitError = null;
  flushResult = true;
  rateLimitResult = { rateLimited: false };
  emitted.length = 0;
  flushTimeouts.length = 0;
  verifyRequest.mockClear();
});

afterAll(() => {
  restoreEnv("VERCEL", originalVercel);
  restoreEnv("CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID", originalRuleId);
});

describe("iOS mobile network observability route", () => {
  test("attributes an accepted failure batch to the authenticated user", async () => {
    const response = await POST(outcomeRequest([
      outcome({
        phase: "transport_dial",
        outcome: "timeout",
        duration_ms: 1_250,
        failure: "timedOut",
        transport: "iroh",
        client_channel: "nightly",
        event_code: "transportDialFailed",
        event_code_raw: 27,
        event_surface: 8,
        event_a: 1,
        event_b: 2,
        event_c: 7,
      }),
    ]));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, accepted: 1 });
    expect(emitted).toHaveLength(1);
    expect(emitted[0]?.userId).toBe("user-7");
    expect(emitted[0]?.batch[0]).toMatchObject({
      phase: "transport_dial",
      outcome: "timeout",
      durationMs: 1_250,
      failure: "timedOut",
      transport: "iroh",
      clientChannel: "nightly",
      eventCode: "transportDialFailed",
      eventCodeRaw: 27,
      eventSurface: 8,
      eventA: 1,
      eventB: 2,
      eventC: 7,
    });
    expect(flushTimeouts).toEqual([1_000]);
  });

  test("accepts a successful readiness observation and flushes it", async () => {
    const response = await POST(outcomeRequest([
      outcome({
        phase: "rpc_ready",
        outcome: "success",
        duration_ms: 890,
        user_usable: true,
      }),
    ]));

    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({ phase: "rpc_ready", durationMs: 890 });
    expect(flushTimeouts).toEqual([1_000]);
  });

  test("accepts Iroh path lifecycle events for route selection evidence", async () => {
    const response = await POST(outcomeRequest([{
      event: "ios_iroh_path_event",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        operation: "selected",
        path: "private_network",
        transport: "iroh",
        event_code: "transportPathEvent",
        event_code_raw: 55,
        event_surface: 8,
        event_a: 3,
        event_b: 3,
        event_c: 23,
        platform: "ios",
      },
    }]));

    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({
      operation: "selected",
      path: "private_network",
      transport: "iroh",
      eventCode: "transportPathEvent",
      eventCodeRaw: 55,
      eventSurface: 8,
      eventA: 3,
      eventB: 3,
      eventC: 23,
    });
  });

  test("distinguishes an initial Iroh path snapshot from a native selection change", async () => {
    const response = await POST(outcomeRequest([{
      event: "ios_iroh_path_event",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        operation: "snapshot", path: "relay", transport: "iroh",
        event_code: "selectedPathChanged", event_code_raw: 40,
        event_surface: 8, event_a: 2, event_c: 23, platform: "ios",
      },
    }]));
    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({ operation: "snapshot", path: "relay" });
  });

  test.each([
    ["raw event code", { event_code_raw: 40 }],
    ["lifecycle operation", { operation: "opened" }],
    ["path class", { path: "relay" }],
    ["missing operation slot", { event_a: undefined }],
    ["missing path slot", { event_b: undefined }],
    ["snapshot raw code", { event_code: "selectedPathChanged", operation: "snapshot" }],
    ["snapshot operation", { event_code: "selectedPathChanged", event_code_raw: 40 }],
    ["snapshot path slot", { event_code: "selectedPathChanged", event_code_raw: 40, operation: "snapshot", event_a: 2 }],
    ["lag marker with a known path", { operation: "lagged", event_a: 4 }],
  ] as const)("rejects an Iroh event with inconsistent %s", async (_, overrides) => {
    const response = await POST(outcomeRequest([{
      event: "ios_iroh_path_event",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        operation: "selected", path: "private_network", transport: "iroh",
        event_code: "transportPathEvent", event_code_raw: 55,
        event_a: 3, event_b: 3, event_c: 23, platform: "ios",
        ...overrides,
      },
    }]));
    expect(response.status).toBe(400);
    expect(emitted).toEqual([]);
  });

  test.each([
    ["opened", 1, "direct", 1],
    ["closed", 2, "relay", 2],
    ["selected", 3, "loopback", 4],
    ["lagged", 4, "unknown", 0],
  ] as const)("accepts consistent Iroh %s events", async (operation, operationCode, path, pathCode) => {
    const response = await POST(outcomeRequest([{
      event: "ios_iroh_path_event",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        operation, path, transport: "iroh",
        event_code: "transportPathEvent", event_code_raw: 55,
        event_a: operationCode, event_b: pathCode, event_c: 23, platform: "ios",
      },
    }]));
    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({ operation, path });
  });

  test("accepts task model discovery failures for Axiom root-cause spans", async () => {
    const response = await POST(outcomeRequest([{
      event: "ios_task_model_discovery",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        operation: "model_list",
        outcome: "failure",
        duration_ms: 850,
        model_count: 0,
        failure: "hostUnreachable",
        platform: "ios",
      },
    }]));

    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({
      outcome: "failure",
      durationMs: 850,
      modelCount: 0,
      failure: "hostUnreachable",
    });
  });

  test("accepts task model retry decisions and rejects unknown stop reasons", async () => {
    const retry = {
      event: "ios_task_model_discovery",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        operation: "model_list", phase: "retry_scheduled", outcome: "failure",
        duration_ms: 0, model_count: 0, failure: "timedOut",
        attempt: 8, retry_delay_ms: 15_000, correlation_id: 42,
      },
    };
    const stopped = {
      ...retry,
      properties: {
        operation: "model_list", phase: "retry_stopped", outcome: "failure",
        duration_ms: 0, model_count: 0, failure: "authorizationFailed",
        stop_reason: "authorizationRequired",
      },
    };
    const response = await POST(outcomeRequest([retry, stopped]));
    expect(response.status).toBe(200);
    expect(emitted[0]?.batch).toMatchObject([
      { discoveryPhase: "retry_scheduled", attempt: 8, retryDelayMs: 15_000, correlationId: 42 },
      { discoveryPhase: "retry_stopped", stopReason: "authorizationRequired" },
    ]);
    const invalid = await POST(outcomeRequest([{
      ...stopped, properties: { ...stopped.properties, stop_reason: "private error text" },
    }]));
    expect(invalid.status).toBe(400);
  });

  test("accepts task model result metadata", async () => {
    const response = await POST(outcomeRequest([{
      event: "ios_task_model_result",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        operation: "model_list",
        provider: "codex",
        source: "discovered",
        effort_count: 6,
        correlation_id: 42,
        platform: "ios",
      },
    }]));

    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({
      provider: "codex",
      source: "discovered",
      effortCount: 6,
      correlationId: 42,
    });
  });

  test("accepts a terminal latency window with bounded percentile fields", async () => {
    const response = await POST(outcomeRequest([terminalWindow()]));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, accepted: 1 });
    expect(emitted[0]?.batch[0]).toMatchObject({
      windowMs: 10_000,
      inputCount: 4,
      inputToVisibleP95Ms: 86,
      renderP99Ms: 12,
    });
  });

  test("accepts per-hop stage histograms and pacer counters when present", async () => {
    const event = terminalWindow();
    const properties = event.properties as Record<string, unknown>;
    const counts = JSON.stringify([0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    Object.assign(properties, {
      histogram_version: 1,
      input_to_output_histogram: counts,
      input_to_visible_histogram: counts,
      render_histogram: counts,
      uplink_histogram: counts,
      uplink_p50_ms: 128,
      uplink_p95_ms: 128,
      uplink_p99_ms: 128,
      pacer_period_histogram: counts,
      pacer_sample_count: 3,
      pacer_emitted_count: 33,
      pacer_coalesced_count: 48,
      pacer_shed_count: 1,
      pacer_period_max_ms: 135,
    });
    const response = await POST(outcomeRequest([event]));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, accepted: 1 });
    expect(emitted[0]?.batch[0]).toMatchObject({
      histograms: { uplink: counts, pacer_period: counts },
      stageMetrics: { uplink_p95_ms: 128, pacer_coalesced_count: 48, pacer_period_max_ms: 135 },
    });
  });

  test("rejects a malformed per-hop stage histogram", async () => {
    const event = terminalWindow();
    const counts = JSON.stringify(Array(17).fill(0));
    Object.assign(event.properties as Record<string, unknown>, {
      histogram_version: 1,
      input_to_output_histogram: counts,
      input_to_visible_histogram: counts,
      render_histogram: counts,
      downlink_histogram: "[1,2]",
    });
    const response = await POST(outcomeRequest([event]));

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "invalid_outcome" });
  });

  test("accepts a terminal anomaly as a failure signal", async () => {
    const response = await POST(outcomeRequest([{
      event: "ios_terminal_latency_anomaly",
      timestamp: "2026-09-04T12:00:00.000Z",
      properties: {
        duration_ms: 1_250,
        threshold_ms: 1_000,
        stage: "input_to_output",
        platform: "ios",
      },
    }]));

    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({ stage: "input_to_output", durationMs: 1_250 });
  });

  test("accepts a bounded terminal trace correlation", async () => {
    const response = await POST(outcomeRequest([
      outcome({
        phase: "terminal_trace",
        outcome: "success",
        duration_ms: 12_300,
        trace_id: "0000000000001234",
        operation: "replay",
        terminal_phase: "applied",
      }),
    ]));

    expect(response.status).toBe(200);
    expect(emitted[0]?.batch[0]).toMatchObject({
      phase: "terminal_trace",
      traceId: "0000000000001234",
      operation: "replay",
      terminalPhase: "applied",
      durationMs: 12_300,
    });
  });

  test("rejects a mismatched stable event code and name", async () => {
    const response = await POST(outcomeRequest([
      outcome({ phase: "transport_dial", outcome: "bogus", duration_ms: 10 }),
    ]));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_outcome" });
    expect(emitted).toHaveLength(0);
  });

  test("rejects unknown properties instead of accepting user content", async () => {
    const response = await POST(outcomeRequest([
      outcome({ phase: "rpc_ready", outcome: "success", duration_ms: 10, message: "secret" }),
    ]));

    expect(response.status).toBe(400);
    expect(emitted).toHaveLength(0);
  });

  test("rejects unbounded diagnostic payload slots", async () => {
    const response = await POST(outcomeRequest([
      outcome({ phase: "transport_dial", outcome: "failure", duration_ms: 10, event_a: -1 }),
    ]));

    expect(response.status).toBe(400);
    expect(emitted).toHaveLength(0);
  });

  test("rejects unknown diagnostic event vocabulary", async () => {
    const response = await POST(outcomeRequest([
      outcome({ phase: "transport_dial", outcome: "failure", duration_ms: 10, event_code: "user_supplied" }),
    ]));

    expect(response.status).toBe(400);
    expect(emitted).toHaveLength(0);
  });

  test("requires native Stack authentication", async () => {
    authenticatedUser = null;

    const response = await POST(outcomeRequest([
      outcome({ phase: "rpc_ready", outcome: "success", duration_ms: 10 }),
    ]));

    expect(response.status).toBe(401);
    expect(emitted).toHaveLength(0);
  });

  test("returns retryable backpressure when Stack Auth is unavailable", async () => {
    authError = new Error("Stack Auth unavailable");

    const response = await POST(outcomeRequest([
      outcome({ phase: "rpc_ready", outcome: "success", duration_ms: 10 }),
    ]));

    expect(response.status).toBe(503);
    expect(emitted).toHaveLength(0);
  });

  test("rate limits deployed ingress before auth or parsing", async () => {
    process.env.VERCEL = "1";
    rateLimitResult = { rateLimited: true };

    const response = await POST(new Request("https://cmux.test/api/observability/mobile-network", {
      method: "POST",
      body: "{not-json",
    }));

    expect(response.status).toBe(429);
    expect(verifyRequest).not.toHaveBeenCalled();
    expect(emitted).toHaveLength(0);
  });

  test("returns retryable backpressure when span emission fails", async () => {
    emitError = new Error("exporter unavailable");

    const response = await POST(outcomeRequest([
      outcome({ phase: "rpc_ready", outcome: "success", duration_ms: 10 }),
    ]));

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "observability_unavailable" });
  });

  test("accepts bounded histogram summaries and rejects malformed buckets", async () => {
    const event = terminalWindow();
    const properties = event.properties as Record<string, unknown>;
    properties.histogram_version = 1;
    properties.input_failed_count = 0;
    for (const name of ["input_to_output", "input_to_visible", "render"]) {
      properties[`${name}_histogram`] = JSON.stringify([4, ...Array(16).fill(0)]);
    }
    expect((await POST(outcomeRequest([event]))).status).toBe(200);
    properties.render_histogram = JSON.stringify([4, ...Array(15).fill(0), -1]);
    expect((await POST(outcomeRequest([event]))).status).toBe(400);
  });

  test("acknowledges an emitted batch when trace flush is ambiguous", async () => {
    flushResult = false;
    const response = await POST(outcomeRequest([
      outcome({ phase: "transport_dial", outcome: "timeout", duration_ms: 10 }),
    ]));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, accepted: 1 });
    expect(emitted).toHaveLength(1);
  });

  test("accepts an initial-connect outcome with its population and attempt id", async () => {
    const response = await POST(outcomeRequest([
      outcome({
        phase: "initial_connect",
        population: "cold_open",
        attempt_id: "6F7B6E35-1B94-4B9D-9F8A-37F1D54B9C45",
        terminal_ready: true,
      }),
    ]));

    expect(response.status).toBe(200);
    expect(emitted).toHaveLength(1);
    expect(emitted[0]?.batch[0]).toMatchObject({
      phase: "initial_connect",
      population: "cold_open",
      attemptId: "6F7B6E35-1B94-4B9D-9F8A-37F1D54B9C45",
      terminalReady: true,
    });
  });

  test("fails closed when deployed rate limiting is unconfigured", async () => {
    process.env.VERCEL = "1";
    delete process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID;

    const response = await POST(outcomeRequest([
      outcome({ phase: "rpc_ready", outcome: "success", duration_ms: 10 }),
    ]));

    expect(response.status).toBe(503);
    expect(verifyRequest).not.toHaveBeenCalled();
  });
});

function outcome(
  properties: Record<string, unknown>,
): Record<string, unknown> {
  return {
    event: "ios_connectivity_latency",
    timestamp: "2026-09-04T12:00:00.000Z",
    properties: {
      runtime_role: "mobileClient",
      phase: "rpc_ready",
      outcome: "success",
      duration_ms: 10,
      user_usable: false,
      platform: "ios",
      app_version: "1.2.3",
      build_number: "456",
      bundle_identifier: "dev.cmux.ios.axnet",
      os_version: "26.0",
      device_model: "iPhone",
      ...properties,
    },
  };
}

function outcomeRequest(batch: readonly Record<string, unknown>[]): Request {
  return new Request("https://cmux.test/api/observability/mobile-network", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ batch }),
  });
}

function terminalWindow(): Record<string, unknown> {
  return {
    event: "ios_terminal_latency_window",
    timestamp: "2026-09-04T12:00:00.000Z",
    properties: {
      window_ms: 10_000,
      input_count: 4,
      output_count: 8,
      presented_count: 8,
      correlated_output_count: 4,
      dropped_count: 0,
      output_bytes: 512,
      max_queue_depth: 2,
      input_to_output_p50_ms: 20,
      input_to_output_p95_ms: 64,
      input_to_output_p99_ms: 80,
      input_to_visible_p50_ms: 31,
      input_to_visible_p95_ms: 86,
      input_to_visible_p99_ms: 100,
      render_p50_ms: 4,
      render_p95_ms: 8,
      render_p99_ms: 12,
      platform: "ios",
    },
  };
}

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
