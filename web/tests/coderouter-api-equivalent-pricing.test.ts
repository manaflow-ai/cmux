import { describe, expect, test } from "bun:test";

import { estimateApiEquivalent } from "../services/coderouter/apiEquivalentPricing";

function usage(
  model: string,
  inputTokens: number,
  cachedInputTokens: number,
  outputTokens: number,
) {
  return {
    model,
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens: inputTokens + outputTokens,
  };
}

describe("coderouter API-equivalent pricing", () => {
  test.each<[string, number, number, number]>([
    ["gpt-6-astra", 10, 1, 50],
    ["gpt-6-sol", 2, 0.2, 10],
    ["gpt-6-luna", 0.1, 0.01, 0.5],
  ])("prices %s from the OpenAI list price", (model, input, cached, output) => {
    const estimate = estimateApiEquivalent(
      usage(model, 200_000, 100_000, 50_000),
    );
    expect(estimate.usd).toBeCloseTo(
      (100_000 * input + 100_000 * cached + 50_000 * output) / 1_000_000,
      10,
    );
    expect(estimate.pricedTokens).toBe(250_000);
    expect(estimate.unpricedTokens).toBe(0);
  });

  test("applies GPT-6 long-context pricing above 272K input tokens", () => {
    const estimate = estimateApiEquivalent(
      usage("gpt-6-sol", 300_000, 0, 100_000),
    );
    expect(estimate.usd).toBeCloseTo((300_000 * 2 * 2 + 100_000 * 10 * 1.5) / 1_000_000, 10);
  });

  test("matches dated GPT-6 snapshots but not unknown GPT-6 names", () => {
    expect(estimateApiEquivalent(usage("gpt-6-luna-2026-09-01", 100_000, 0, 0)).usd)
      .toBeCloseTo(0.01, 10);
    expect(estimateApiEquivalent(usage("gpt-6", 1_000, 0, 0)).unpricedTokens).toBe(1_000);
  });
});
