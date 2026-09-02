import { describe, expect, test } from "bun:test";
import { estimateApiEquivalent } from "../services/coderouter/apiEquivalentPricing";

// The API-equivalent estimate prices the three Anthropic prompt-token classes
// at their own list rates: uncached input, cache reads (0.1x), and cache
// writes (1.25x). OpenAI-shaped usage never reports cache writes.

describe("estimateApiEquivalent", () => {
  test("prices Anthropic cache writes at 1.25x input", () => {
    const estimate = estimateApiEquivalent({
      model: "claude-sonnet-5",
      inputTokens: 1_000_000,
      cachedInputTokens: 0,
      cacheCreationInputTokens: 1_000_000,
      outputTokens: 0,
      totalTokens: 1_000_000,
    });
    expect(estimate.usd).toBeCloseTo(2 * 1.25, 6);
    expect(estimate.pricedTokens).toBe(1_000_000);
  });

  test("splits input into uncached, cached, and cache-write slices", () => {
    const estimate = estimateApiEquivalent({
      model: "claude-sonnet-5",
      inputTokens: 1_000_000,
      cachedInputTokens: 500_000,
      cacheCreationInputTokens: 200_000,
      outputTokens: 100_000,
      totalTokens: 1_100_000,
    });
    // 300k uncached @2 + 500k cached @0.2 + 200k writes @2.5 + 100k out @10.
    expect(estimate.usd).toBeCloseTo(0.6 + 0.1 + 0.5 + 1, 6);
  });

  test("never lets cache writes exceed the uncached remainder", () => {
    const estimate = estimateApiEquivalent({
      model: "claude-sonnet-5",
      inputTokens: 100,
      cachedInputTokens: 100,
      cacheCreationInputTokens: 100,
      outputTokens: 0,
      totalTokens: 100,
    });
    expect(estimate.usd).toBeCloseTo(100 * 0.2 / 1_000_000, 12);
  });

  test("treats absent cache writes as plain input for OpenAI-shaped usage", () => {
    const estimate = estimateApiEquivalent({
      model: "gpt-5.2-codex",
      inputTokens: 1_000_000,
      cachedInputTokens: 0,
      outputTokens: 0,
      totalTokens: 1_000_000,
    });
    expect(estimate.usd).toBeCloseTo(1.75, 6);
  });
});
