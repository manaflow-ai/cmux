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
    return typeof step.clone === "function" ? step.clone() : step;
  }) as typeof fetch;
  return state;
}

function timeoutThenSuccessFetch(): { calls: number } {
  const state = { calls: 0 };
  globalThis.fetch = (async (_input, init) => {
    state.calls += 1;
    if (state.calls === 1) {
      const signal = init?.signal;
      await new Promise<never>((_resolve, reject) => {
        if (!signal) {
          reject(new Error("missing attempt signal"));
          return;
        }
        if (signal.aborted) {
          reject(signal.reason);
          return;
        }
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
    }
    return jsonResponse(200, { recovered: true });
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

  test("POST is not replayed on 429 without idempotency protection", async () => {
    const state = scriptedFetch([jsonResponse(429, {}, { "retry-after": "2" })]);
    const err = await blaxelFetch("POST", URL_UNDER_TEST, { spec: {} }, seams([])).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ProviderError);
    expect(err).not.toBeInstanceOf(BlaxelRetryExhaustedError);
    expect(String((err as Error).message)).toMatch(/-> 429/);
    expect(state.calls).toBe(1);
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

  test("GET retries a timed-out first attempt under the default retry budget", async () => {
    const state = timeoutThenSuccessFetch();
    const result = await blaxelFetch<{ recovered: boolean }>("GET", URL_UNDER_TEST, undefined, {
      timeoutMs: 25,
      sleep: async () => undefined,
      random: () => 0,
    });
    expect(result).toEqual({ recovered: true });
    expect(state.calls).toBe(2);
  });

  test("missing configuration is not treated as a retryable network failure", async () => {
    delete process.env.BL_API_KEY;
    const state = scriptedFetch([jsonResponse(200, { ok: true })]);
    const err = await blaxelFetch("GET", URL_UNDER_TEST, undefined, seams([])).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ProviderError);
    expect(String((err as Error).message)).toContain("BL_API_KEY is not configured");
    expect(state.calls).toBe(0);
  });

  test("idempotent requests retry a response-body transport failure", async () => {
    const brokenResponse = {
      ok: true,
      status: 200,
      headers: new Headers(),
      text: async () => { throw new TypeError("body stream failed"); },
    } as unknown as Response;
    const state = scriptedFetch([brokenResponse, jsonResponse(200, { recovered: true })]);
    const result = await blaxelFetch<{ recovered: boolean }>("GET", URL_UNDER_TEST, undefined, seams([]));
    expect(result).toEqual({ recovered: true });
    expect(state.calls).toBe(2);
  });

  test("abort during backoff stops before the next attempt", async () => {
    const controller = new AbortController();
    const state = scriptedFetch([jsonResponse(503)]);
    const sleeps: number[] = [];
    const err = await blaxelFetch("GET", URL_UNDER_TEST, undefined, {
      ...seams(sleeps),
      signal: controller.signal,
      sleep: async (ms: number) => {
        sleeps.push(ms);
        controller.abort(new Error("request cancelled"));
      },
    }).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(Error);
    expect(String((err as Error).message)).toBe("request cancelled");
    expect(state.calls).toBe(1);
    expect(sleeps).toEqual([250]);
  });

  test("already-aborted requests do not read configuration or call fetch", async () => {
    const controller = new AbortController();
    const reason = new Error("request already cancelled");
    controller.abort(reason);
    const state = scriptedFetch([jsonResponse(200, { unexpected: true })]);
    const err = await blaxelFetch("GET", URL_UNDER_TEST, undefined, {
      signal: controller.signal,
      sleep: async () => undefined,
    }).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBe(reason);
    expect(state.calls).toBe(0);
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
