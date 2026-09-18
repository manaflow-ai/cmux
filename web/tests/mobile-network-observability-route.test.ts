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
