import { describe, expect, test } from "bun:test";
import { hetznerFirecrackerStub, percentile, runCell, selectProvider, summarize, type ProviderAdapter } from "./resume-slo-provider";

describe("resume-slo-provider", () => {
  test("percentile is nearest-rank", () => {
    expect(percentile([], 50)).toBeNull();
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50)).toBe(5);
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95)).toBe(10);
  });

  test("off without credentials, and a stub never measures", async () => {
    expect(selectProvider("morph", {})).toEqual({ skipped: "morph: MORPH_API_KEY is not set" });
    expect(selectProvider("morph", { MORPH_API_KEY: "k" })).toHaveProperty("skipped");
    expect(selectProvider("morph", { MORPH_API_KEY: "k", MORPH_SNAPSHOT_ID: "s" })).toHaveProperty("adapter");
    expect(selectProvider("nope", {})).toHaveProperty("skipped");
    await expect(hetznerFirecrackerStub().create()).rejects.toThrow("not implemented");
  });

  test("a cell times resume and first exec per round and counts failures", async () => {
    let t = 0, calls = 0;
    const a: ProviderAdapter = {
      name: "fake", create: async () => "x", pause: async () => {}, probe: async () => { t += 20; },
      resume: async () => { t += 100; if (++calls === 2) throw new Error("boom"); }, remove: async () => {},
    };
    const cell = await runCell(a, 5, 3, async () => {}, () => t);
    expect(cell.failures).toBe(1);
    expect(cell.resumeMs).toEqual([100, 100]);
    expect(cell.firstExecMs).toEqual([120, 120]);
    expect(summarize([cell])[0]).toMatchObject({ pause_s: 5, n: 3, resume_p50_ms: 100, to_running_p95_ms: 120 });
  });
});
