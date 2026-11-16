import { describe, expect, test } from "bun:test";
import { daemonListening, imageLatency, measureCloneRetrying, providerLatency, ProviderUnfinished } from "../scripts/cmux-vm-image/smoke";
import type { Vm } from "../scripts/cmux-vm-image/guest";

const clone = (vmId: string) => ({ vm: {} as Vm, vmId, name: `cmuxnp-dev-vmimg-t-smoke-${vmId}` });
const row = (createApiMs: number, listening: number, ready: number) => ({ vmId: "vm", createApiMs, createDoneToListeningMs: listening, createDoneToReadyMs: ready });

describe("smoke daemon-listening judges the image, not the provider", () => {
  test("a slow create call does not fail the check", () => {
    // Roll 43953739384: createApi raw 40323/7132/25760/4371/2866 ms.
    const rows = [row(40323, 900, 1200), row(7132, 800, 1100), row(25760, 950, 1300), row(4371, 700, 1000), row(2866, 750, 1050)];
    expect(daemonListening(rows)).toBe(true);
    expect((providerLatency(rows, []).createApi as { p95: number }).p95).toBe(40323);
    expect(imageLatency(rows)).not.toHaveProperty("createApi");
  });

  test("a daemon that never listened on a finished clone fails it", () => {
    expect(daemonListening([row(500, 900, 1200), row(500, -1, -1)])).toBe(false);
    expect(daemonListening([row(500, 900, -1)])).toBe(false);
    expect(daemonListening([])).toBe(false);
  });
});

describe("measureCloneRetrying", () => {
  test("replaces a clone the provider never finished and deletes it", async () => {
    const deleted: string[] = [];
    const budget = { left: 3, unfinished: [] as string[] };
    const result = await measureCloneRetrying(
      async (attempt) => {
        if (attempt === 0) throw new ProviderUnfinished(clone("vm-a"), "first exec: guest never answered an exec");
        return { clone: clone("vm-b"), row: row(500, 900, 1200) };
      },
      async (c) => void deleted.push(c.vmId),
      budget,
      0,
    );
    expect(result.clone.vmId).toBe("vm-b");
    expect(deleted).toEqual(["vm-a"]);
    expect(budget).toEqual({ left: 2, unfinished: ["first exec: guest never answered an exec"] });
  });

  test("a failed create has no clone to delete", async () => {
    const deleted: string[] = [];
    const budget = { left: 1, unfinished: [] as string[] };
    await measureCloneRetrying(
      async (attempt) => {
        if (attempt === 0) throw new ProviderUnfinished(undefined, "create: 429");
        return { clone: clone("vm-b"), row: row(500, 900, 1200) };
      },
      async (c) => void deleted.push(c.vmId),
      budget,
      0,
    );
    expect(deleted).toEqual([]);
  });

  test("stops at the budget, naming the provider", async () => {
    const budget = { left: 1, unfinished: [] as string[] };
    const run = measureCloneRetrying(async () => { throw new ProviderUnfinished(clone("vm-x"), "create: 500"); }, async () => {}, budget, 0);
    await expect(run).rejects.toThrow("provider never finished 2 clones: create: 500; create: 500");
  });

  test("never retries an image failure", async () => {
    let calls = 0;
    const budget = { left: 3, unfinished: [] as string[] };
    const run = measureCloneRetrying(async () => { calls++; throw new Error("image broke"); }, async () => {}, budget, 0);
    await expect(run).rejects.toThrow("image broke");
    expect(calls).toBe(1);
    expect(budget.left).toBe(3);
  });
});
