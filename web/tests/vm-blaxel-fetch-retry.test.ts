import { afterEach, beforeEach, describe, expect, test } from "bun:test";

import {
  BLAXEL_FETCH_MAX_ATTEMPTS,
  BlaxelRetryExhaustedError,
  blaxelFetch,
  blaxelRetryDelayMs,
} from "../services/vms/drivers/blaxel";
import { ProviderError } from "../services/vms/drivers/types";

const realFetch = globalThis.fetch;
let envBackup: Record<string, string | undefined>;

beforeEach(() => {
  envBackup = {
    BL_API_KEY: process.env.BL_API_KEY,
    BL_WORKSPACE: process.env.BL_WORKSPACE,
  };
  process.env.BL_API_KEY = "test-key";
  process.env.BL_WORKSPACE = "test-workspace";
});

afterEach(() => {
  globalThis.fetch = realFetch;
  for (const [key, value] of Object.entries(envBackup)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

function jsonResponse(status: number, body: unknown = {}, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

function scriptedFetch(script: Array<Response | Error>): { calls: number } {
  const state = { calls: 0 };
  globalThis.fetch = (async () => {
    const step = script[Math.min(state.calls, script.length - 1)];
    state.calls += 1;
    if (step instanceof Error) throw step;
    return step.clone();
  }) as typeof fetch;
  return state;
}

function seams(sleeps: number[]): { sleep: (ms: number) => Promise<void>; random: () => number } {
  return {
    sleep: async (ms: number) => {
      sleeps.push(ms);
    },
    random: () => 1,
  };
}

const URL_UNDER_TEST = "https://api.blaxel.test/sandboxes/machine-1";

describe("blaxelFetch retry", () => {
  test("GET retries transient 5xx and succeeds", async () => {
    const state = scriptedFetch([jsonResponse(503), jsonResponse(502), jsonResponse(200, { ok: true })]);
    const sleeps: number[] = [];
    const result = await blaxelFetch<{ ok: boolean }>("GET", URL_UNDER_TEST, undefined, seams(sleeps));
    expect(result).toEqual({ ok: true });
    expect(state.calls).toBe(3);
    // Full jitter with random()=1: min(4000, 250 * 2^attempt).
    expect(sleeps).toEqual([250, 500]);
  });

  test("GET surfaces a distinct error after the retry budget", async () => {
    const state = scriptedFetch([jsonResponse(503, { code: "UNAVAILABLE" })]);
    const err = await blaxelFetch("GET", URL_UNDER_TEST, undefined, seams([])).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(BlaxelRetryExhaustedError);
    expect(err).toBeInstanceOf(ProviderError);
    expect(String((err as Error).message)).toContain(`retries exhausted after ${BLAXEL_FETCH_MAX_ATTEMPTS} attempts`);
    expect(String((err as Error).message)).toContain("503");
    expect(state.calls).toBe(BLAXEL_FETCH_MAX_ATTEMPTS);
  });

  test("POST is not replayed on 5xx", async () => {
    const state = scriptedFetch([jsonResponse(500, { code: "INTERNAL" })]);
    const err = await blaxelFetch("POST", URL_UNDER_TEST, { spec: {} }, seams([])).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ProviderError);
    expect(err).not.toBeInstanceOf(BlaxelRetryExhaustedError);
    expect(String((err as Error).message)).toMatch(/-> 500/);
    expect(state.calls).toBe(1);
  });

  test("POST is retried on 429 and honors Retry-After", async () => {
    const state = scriptedFetch([
      jsonResponse(429, {}, { "retry-after": "2" }),
      jsonResponse(200, { created: true }),
    ]);
    const sleeps: number[] = [];
    const result = await blaxelFetch<{ created: boolean }>("POST", URL_UNDER_TEST, { spec: {} }, seams(sleeps));
    expect(result).toEqual({ created: true });
    expect(state.calls).toBe(2);
    expect(sleeps).toEqual([2000]);
  });

  test("POST network failures propagate without replay", async () => {
    const boom = new TypeError("fetch failed");
    const state = scriptedFetch([boom]);
    const err = await blaxelFetch("POST", URL_UNDER_TEST, { spec: {} }, seams([])).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBe(boom);
    expect(state.calls).toBe(1);
  });

  test("GET network failures are retried", async () => {
    const state = scriptedFetch([new TypeError("fetch failed"), jsonResponse(200, { ok: true })]);
    const result = await blaxelFetch<{ ok: boolean }>("GET", URL_UNDER_TEST, undefined, seams([]));
    expect(result).toEqual({ ok: true });
    expect(state.calls).toBe(2);
  });

  test("4xx keeps the historical message shape the create collision loop matches", async () => {
    const state = scriptedFetch([jsonResponse(409, { error: "name already exists" })]);
    const err = await blaxelFetch("POST", URL_UNDER_TEST, { spec: {} }, seams([])).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ProviderError);
    expect(String((err as Error).message)).toMatch(/-> 409/);
    expect(state.calls).toBe(1);
  });
});

describe("blaxelRetryDelayMs", () => {
  test("full-jitter backoff grows per attempt and is capped", () => {
    expect(blaxelRetryDelayMs(0, null, () => 1)).toBe(250);
    expect(blaxelRetryDelayMs(1, null, () => 1)).toBe(500);
    expect(blaxelRetryDelayMs(2, null, () => 1)).toBe(1000);
    expect(blaxelRetryDelayMs(10, null, () => 1)).toBe(4000);
    expect(blaxelRetryDelayMs(0, null, () => 0)).toBe(0);
  });

  test("Retry-After wins over backoff and is capped", () => {
    expect(blaxelRetryDelayMs(0, "2", () => 1)).toBe(2000);
    expect(blaxelRetryDelayMs(0, "60", () => 1)).toBe(15000);
  });
});
