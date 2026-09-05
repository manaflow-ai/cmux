import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";

import { makeMobileNetworkOutcomeHandler } from "../app/api/observability/mobile-network/route";
import type { MobileNetworkOutcome } from "../services/observability/mobileNetworkOutcome";

const originalVercel = process.env.VERCEL;
const originalRuleId = process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID;

let authenticatedUser: { readonly id: string } | null = { id: "user-7" };
let authError: unknown = null;
let emitError: unknown = null;
let flushResult = true;
let rateLimitResult: Awaited<ReturnType<typeof checkVercelRateLimit>> = { rateLimited: false };
const emitted: Array<{ readonly userId: string; readonly batch: readonly MobileNetworkOutcome[] }> = [];
const flushTimeouts: Array<number | undefined> = [];

const verifyRequest = mock(async () => {
  if (authError) throw authError;
  return authenticatedUser;
});
const checkRateLimit: typeof checkVercelRateLimit = async () => rateLimitResult;
const emitOutcomes = async (userId: string, batch: readonly MobileNetworkOutcome[]): Promise<void> => {
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

  test("acknowledges an emitted batch when trace flush is ambiguous", async () => {
    flushResult = false;
    const response = await POST(outcomeRequest([
      outcome({ phase: "transport_dial", outcome: "timeout", duration_ms: 10 }),
    ]));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, accepted: 1 });
    expect(emitted).toHaveLength(1);
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

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
