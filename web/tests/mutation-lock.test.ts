import { describe, expect, test } from "bun:test";

import {
  acquireMutationLock,
  MUTATION_FENCE_BUCKET_COUNT,
  mutationFenceKey,
} from "../db/mutationLock";

function fakeTransaction() {
  const calls: string[] = [];
  const tx = {
    execute: async () => {
      calls.push("execute");
    },
  };
  return { calls, tx };
}

describe("cross-runtime mutation fences", () => {
  test("maps the same lock name to a bounded stable bucket", () => {
    const first = mutationFenceKey("iroh:binding:account-a");
    expect(first).toBe(mutationFenceKey("iroh:binding:account-a"));
    expect(first).toMatch(/^bucket:[0-9]+$/);
    const bucket = Number(first.slice("bucket:".length));
    expect(bucket).toBeGreaterThanOrEqual(0);
    expect(bucket).toBeLessThan(MUTATION_FENCE_BUCKET_COUNT);
  });

  test("takes exactly one transaction lock statement per mode", async () => {
    const row = fakeTransaction();
    await acquireMutationLock(row.tx, "iroh:binding:account-a", "row");
    expect(row.calls).toEqual(["execute"]);

    const advisory = fakeTransaction();
    await acquireMutationLock(advisory.tx, "iroh:binding:account-a", "advisory");
    expect(advisory.calls).toEqual(["execute"]);

    const hybrid = fakeTransaction();
    await acquireMutationLock(hybrid.tx, "iroh:binding:account-a", "hybrid");
    expect(hybrid.calls).toEqual(["execute"]);
  });
});
