/**
 * Unit tests for src/core/cost.ts
 */

import { describe, it, expect } from "bun:test";
import { estimateCost, MODEL_PRICES } from "../../../src/core/cost.js";
import type { UsageTotals } from "../../../src/core/cost.js";

const zeroUsage: UsageTotals = {
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheCreationTokens: 0,
};

describe("estimateCost", () => {
  it("returns zero cost for zero usage", () => {
    const { usd } = estimateCost("claude-sonnet-4-5", zeroUsage);
    expect(usd).toBe(0);
  });

  it("correctly calculates cost for claude-sonnet-4-5 input tokens", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("claude-sonnet-4-5", usage);
    // $3.00 per M input tokens
    expect(usd).toBeCloseTo(3.0, 5);
  });

  it("correctly calculates cost for claude-sonnet-4-5 output tokens", () => {
    const usage: UsageTotals = {
      inputTokens: 0,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("claude-sonnet-4-5", usage);
    // $15.00 per M output tokens
    expect(usd).toBeCloseTo(15.0, 5);
  });

  it("correctly calculates cost for claude-opus-4-7", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("claude-opus-4-7", usage);
    // $15 input + $75 output = $90
    expect(usd).toBeCloseTo(90.0, 5);
  });

  it("correctly calculates cost for claude-haiku-4-5", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("claude-haiku-4-5", usage);
    // $0.80 input + $4.00 output = $4.80
    expect(usd).toBeCloseTo(4.8, 5);
  });

  it("correctly calculates cost for gpt-4o", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("gpt-4o", usage);
    // $2.50 input + $10.00 output = $12.50
    expect(usd).toBeCloseTo(12.5, 5);
  });

  it("correctly calculates cost for gpt-4o-mini", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("gpt-4o-mini", usage);
    // $0.15 input + $0.60 output = $0.75
    expect(usd).toBeCloseTo(0.75, 5);
  });

  it("correctly calculates cost for gemini-2.5-pro", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("gemini-2.5-pro", usage);
    // $1.25 input + $5.00 output = $6.25
    expect(usd).toBeCloseTo(6.25, 5);
  });

  it("correctly calculates cost for gemini-2.5-flash", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("gemini-2.5-flash", usage);
    // $0.075 input + $0.30 output = $0.375
    expect(usd).toBeCloseTo(0.375, 5);
  });

  it("falls back to default pricing ($3/$15) for unknown model", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("some-unknown-model-xyz", usage);
    // Default: $3 input + $15 output = $18
    expect(usd).toBeCloseTo(18.0, 5);
  });

  it("handles provider-prefixed model names (e.g. anthropic/claude-sonnet-4-5)", () => {
    const usage: UsageTotals = {
      inputTokens: 1_000_000,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { usd } = estimateCost("anthropic/claude-sonnet-4-5", usage);
    // Should resolve to claude-sonnet-4-5: $3 per M input
    expect(usd).toBeCloseTo(3.0, 5);
  });

  it("includes cache read and cache write costs", () => {
    const usage: UsageTotals = {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 1_000_000,
      cacheCreationTokens: 1_000_000,
    };
    const { usd } = estimateCost("claude-sonnet-4-5", usage);
    // cacheRead: $0.30/M, cacheWrite: $3.75/M => $4.05
    expect(usd).toBeCloseTo(4.05, 5);
  });

  it("breakdown string includes 'input' and 'output' lines", () => {
    const usage: UsageTotals = {
      inputTokens: 100,
      outputTokens: 50,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { breakdown } = estimateCost("claude-sonnet-4-5", usage);
    expect(breakdown).toContain("input:");
    expect(breakdown).toContain("output:");
    expect(breakdown).toContain("total:");
  });

  it("breakdown string includes cache lines when cache tokens > 0", () => {
    const usage: UsageTotals = {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 1000,
      cacheCreationTokens: 2000,
    };
    const { breakdown } = estimateCost("claude-sonnet-4-5", usage);
    expect(breakdown).toContain("cache read:");
    expect(breakdown).toContain("cache write:");
  });

  it("breakdown string does NOT include cache lines when cache tokens are zero", () => {
    const usage: UsageTotals = {
      inputTokens: 100,
      outputTokens: 50,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    const { breakdown } = estimateCost("gpt-4o", usage);
    expect(breakdown).not.toContain("cache read:");
    expect(breakdown).not.toContain("cache write:");
  });

  it("MODEL_PRICES has entries for expected models", () => {
    expect(MODEL_PRICES["claude-opus-4-7"]).toBeDefined();
    expect(MODEL_PRICES["claude-sonnet-4-5"]).toBeDefined();
    expect(MODEL_PRICES["claude-haiku-4-5"]).toBeDefined();
    expect(MODEL_PRICES["gpt-4o"]).toBeDefined();
    expect(MODEL_PRICES["gpt-4o-mini"]).toBeDefined();
    expect(MODEL_PRICES["gemini-2.5-pro"]).toBeDefined();
    expect(MODEL_PRICES["gemini-2.5-flash"]).toBeDefined();
  });
});
