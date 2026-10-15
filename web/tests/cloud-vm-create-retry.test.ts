import { describe, expect, test } from "bun:test";

import { createVmWithRetry } from "../scripts/cloud-vm/smokeCreate.mjs";

describe("Cloud VM smoke create retry", () => {
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
});
