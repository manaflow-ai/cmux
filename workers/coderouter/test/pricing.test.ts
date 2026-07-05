import { describe, expect, test } from "bun:test";
import { lookupPrice, priceComponent, priceUsageMicros } from "../src/pricing";

describe("pricing", () => {
  test("rounds each component up", () => {
    expect(priceComponent(1, 1)).toBe(1);
    expect(priceComponent(1_000_000, 3)).toBe(3);
  });

  test("matches exact ids and date-suffixed model ids", () => {
    expect(lookupPrice("gpt-5")?.family).toBe("openai");
    expect(lookupPrice("gpt-5-mini-2026-01-01")).toMatchObject({
      family: "openai",
      inputPer1M: 250_000,
      outputPer1M: 2_000_000,
    });
    expect(lookupPrice("claude-sonnet-4-5-20250929")).toMatchObject({
      family: "anthropic",
      inputPer1M: 3_000_000,
      outputPer1M: 15_000_000,
    });
    expect(lookupPrice("missing-model")).toBeNull();
  });

  test("returns null for unknown models", () => {
    expect(priceUsageMicros("unknown", { inputTokens: 10, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0, estimated: false })).toBeNull();
    expect(priceUsageMicros("gpt-5", { inputTokens: 1, outputTokens: 1, cacheReadTokens: 1, cacheWriteTokens: 0, estimated: false })).toBeGreaterThan(0);
  });
});
