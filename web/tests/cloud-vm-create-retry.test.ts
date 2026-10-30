import { describe, expect, test } from "bun:test";

import {
  createVmRequest,
  createVmWithRetry,
  readResponseText,
} from "../scripts/cloud-vm/smokeCreate.mjs";
import { stackServerAppOptions } from "../scripts/cloud-vm/stackConfig.mjs";

describe("Cloud VM smoke create retry", () => {
  test("keeps the publishable client key optional for production canaries", () => {
    expect(stackServerAppOptions({ projectId: "project", secretServerKey: "secret" })).toEqual({
      projectId: "project",
      secretServerKey: "secret",
    });
    expect(stackServerAppOptions({ projectId: "project", publishableClientKey: "client", secretServerKey: "secret" })).toEqual({
      projectId: "project",
      publishableClientKey: "client",
      secretServerKey: "secret",
    });
  });

  test("aborts a stalled response body and cancels its stream", async () => {
    const controller = new AbortController();
    let cancelled = false;
    const response = {
      body: {
        getReader: () => ({
          read: () => new Promise(() => {}),
          cancel: async () => { cancelled = true; },
          releaseLock: () => {},
        }),
      },
      text: () => new Promise<string>(() => {}),
    };
    const pending = readResponseText(response as unknown as Response, { signal: controller.signal, timeoutMs: 1_000 });
    controller.abort(new Error("test cancellation"));
    await expect(pending).rejects.toThrow("test cancellation");
    expect(cancelled).toBe(true);
  });

  test("caller preserves the idempotency key and payload across retries", async () => {
    const responses = [
      { status: 503, body: { error: "vm_operation_in_progress", phase: "create", retryable: true } },
      { status: 409, body: { error: "vm_create_in_progress" } },
      { status: 200, body: { id: "vm-1", provider: "freestyle" } },
    ];
    const requests: Array<{ url: string; init: RequestInit }> = [];
    const controller = new AbortController();
    const signals: Array<AbortSignal | undefined> = [];
    const send = createVmRequest({
      targetUrl: "https://cmux.test",
      authHeaders: { authorization: "Bearer test" },
      provider: "default",
      image: undefined,
      fetchWithTimeout: async (url: string, init: RequestInit, _timeout: number | undefined, signal: AbortSignal | undefined) => {
        requests.push({ url, init });
        signals.push(signal);
        const response = responses.shift()!;
        return { status: response.status, text: async () => JSON.stringify(response.body) };
      },
    });

    await createVmWithRetry({
      idempotencyKey: "smoke-key",
      send,
      signal: controller.signal,
      sleep: async () => {},
      now: (() => {
        let current = 0;
        return () => current++;
      })(),
    });

    expect(requests).toHaveLength(3);
    expect(requests.map(({ init }) => new Headers(init.headers).get("idempotency-key"))).toEqual([
      "smoke-key", "smoke-key", "smoke-key",
    ]);
    expect(requests.map(({ init }) => init.body)).toEqual([
      "{}", "{}", "{}",
    ]);
    expect(signals).toEqual([controller.signal, controller.signal, controller.signal]);
  });

  test("retries an in-progress create with the same idempotency key until it is ready", async () => {
    const responses = [
      { status: 503, body: { error: "vm_operation_in_progress", phase: "create", retryable: true, retryAfterSeconds: 15 } },
      { status: 409, body: { error: "vm_create_in_progress" } },
      { status: 200, body: { id: "vm-1", provider: "freestyle" } },
    ];
    const idempotencyKeys: string[] = [];
    const sleeps: number[] = [];
    const result = await createVmWithRetry({
      idempotencyKey: "smoke-key",
      send: async (key: string) => {
        idempotencyKeys.push(key);
        return responses.shift()!;
      },
      sleep: async (ms) => { sleeps.push(ms); },
      now: (() => {
        let current = 0;
        return () => current++;
      })(),
    });

    expect(result).toEqual({ id: "vm-1", provider: "freestyle" });
    expect(idempotencyKeys).toEqual(["smoke-key", "smoke-key", "smoke-key"]);
    expect(sleeps).toEqual([15_000, 15_000]);
  });

  test("does not retry a terminal create response", async () => {
    let sends = 0;
    await expect(createVmWithRetry({
      idempotencyKey: "smoke-key",
      send: async () => {
        sends += 1;
        return { status: 503, body: { error: "vm_cloud_service_unavailable", retryable: true } };
      },
      sleep: async () => {},
      now: () => 0,
    })).rejects.toThrow("vm_cloud_service_unavailable");
    expect(sends).toBe(1);
  });

  test("bounds an in-progress wait before issuing another create request", async () => {
    let now = 0;
    let sends = 0;
    const sleeps: number[] = [];
    await expect(createVmWithRetry({
      idempotencyKey: "smoke-key",
      budgetMs: 1_000,
      send: async () => {
        sends += 1;
        return { status: 503, body: { error: "vm_operation_in_progress", phase: "create", retryable: true } };
      },
      sleep: async (ms) => {
        sleeps.push(ms);
        now += ms;
      },
      now: () => now,
    })).rejects.toThrow("remained in progress for 1000 ms");
    expect(sends).toBe(1);
    expect(sleeps).toEqual([1_000]);
  });

  test("cancellation stops the retry wait before another request", async () => {
    const controller = new AbortController();
    let sends = 0;
    let markWaitStarted!: () => void;
    const waitStarted = new Promise<void>((resolve) => { markWaitStarted = resolve; });
    const pending = createVmWithRetry({
      idempotencyKey: "smoke-key",
      send: async () => {
        sends += 1;
        return { status: 503, body: { error: "vm_operation_in_progress", phase: "create", retryable: true, retryAfterSeconds: 60 } };
      },
      sleep: async (_ms: number, signal: AbortSignal | undefined) => {
        markWaitStarted();
        return new Promise<never>((_resolve, reject) => {
          signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
        });
      },
      signal: controller.signal,
    });
    await waitStarted;
    controller.abort(new Error("test cancellation"));
    await expect(pending).rejects.toThrow("aborted");
    expect(sends).toBe(1);
  });
});
