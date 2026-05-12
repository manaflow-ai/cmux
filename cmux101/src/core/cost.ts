/**
 * Cost estimation for model usage.
 *
 * Prices are per million tokens (USD). Uses conservative published pricing.
 */

export interface PricePoint {
  inputPerM: number;
  outputPerM: number;
  cacheReadPerM?: number;
  cacheWritePerM?: number;
}

// Prices per million tokens (USD), conservative estimates.
export const MODEL_PRICES: Record<string, PricePoint> = {
  // Anthropic Claude
  "claude-opus-4-7":       { inputPerM: 15.00, outputPerM: 75.00, cacheReadPerM: 1.50,  cacheWritePerM: 18.75 },
  "claude-opus-4":         { inputPerM: 15.00, outputPerM: 75.00, cacheReadPerM: 1.50,  cacheWritePerM: 18.75 },
  "claude-sonnet-4-5":     { inputPerM:  3.00, outputPerM: 15.00, cacheReadPerM: 0.30,  cacheWritePerM:  3.75 },
  "claude-sonnet-4":       { inputPerM:  3.00, outputPerM: 15.00, cacheReadPerM: 0.30,  cacheWritePerM:  3.75 },
  "claude-haiku-4-5":      { inputPerM:  0.80, outputPerM:  4.00, cacheReadPerM: 0.08,  cacheWritePerM:  1.00 },
  "claude-haiku-4":        { inputPerM:  0.80, outputPerM:  4.00, cacheReadPerM: 0.08,  cacheWritePerM:  1.00 },
  "claude-3-5-sonnet":     { inputPerM:  3.00, outputPerM: 15.00, cacheReadPerM: 0.30,  cacheWritePerM:  3.75 },
  "claude-3-5-haiku":      { inputPerM:  0.80, outputPerM:  4.00, cacheReadPerM: 0.08,  cacheWritePerM:  1.00 },
  "claude-3-opus":         { inputPerM: 15.00, outputPerM: 75.00, cacheReadPerM: 1.50,  cacheWritePerM: 18.75 },
  "claude-3-haiku":        { inputPerM:  0.25, outputPerM:  1.25, cacheReadPerM: 0.03,  cacheWritePerM:  0.30 },
  // OpenAI
  "gpt-4o":                { inputPerM:  2.50, outputPerM: 10.00 },
  "gpt-4o-mini":           { inputPerM:  0.15, outputPerM:  0.60 },
  "gpt-4-turbo":           { inputPerM: 10.00, outputPerM: 30.00 },
  "gpt-4":                 { inputPerM: 30.00, outputPerM: 60.00 },
  "gpt-3.5-turbo":         { inputPerM:  0.50, outputPerM:  1.50 },
  "o1":                    { inputPerM: 15.00, outputPerM: 60.00 },
  "o1-mini":               { inputPerM:  3.00, outputPerM: 12.00 },
  "o3-mini":               { inputPerM:  1.10, outputPerM:  4.40 },
  // Google Gemini
  "gemini-2.5-pro":        { inputPerM:  1.25, outputPerM:  5.00 },
  "gemini-2.5-flash":      { inputPerM:  0.075,outputPerM:  0.30 },
  "gemini-2.0-pro":        { inputPerM:  1.25, outputPerM:  5.00 },
  "gemini-2.0-flash":      { inputPerM:  0.075,outputPerM:  0.30 },
  "gemini-1.5-pro":        { inputPerM:  1.25, outputPerM:  5.00 },
  "gemini-1.5-flash":      { inputPerM:  0.075,outputPerM:  0.30 },
};

// Default fallback pricing (sonnet-class).
const DEFAULT_PRICE: PricePoint = { inputPerM: 3.00, outputPerM: 15.00 };

export interface UsageTotals {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}

export function estimateCost(
  model: string,
  usage: UsageTotals,
): { usd: number; breakdown: string } {
  // Try exact match first, then strip provider prefix (e.g. "anthropic/claude-opus-4-7").
  let price = MODEL_PRICES[model];
  if (!price) {
    const slashIdx = model.lastIndexOf("/");
    if (slashIdx !== -1) {
      price = MODEL_PRICES[model.slice(slashIdx + 1)];
    }
  }
  // Fuzzy: check if any known key is a prefix of or contained in the model string.
  if (!price) {
    for (const key of Object.keys(MODEL_PRICES)) {
      if (model.includes(key) || key.includes(model)) {
        price = MODEL_PRICES[key];
        break;
      }
    }
  }
  if (!price) price = DEFAULT_PRICE;

  const inputCost  = (usage.inputTokens        / 1_000_000) * price.inputPerM;
  const outputCost = (usage.outputTokens        / 1_000_000) * price.outputPerM;
  const cacheReadCost  = (usage.cacheReadTokens    / 1_000_000) * (price.cacheReadPerM  ?? 0);
  const cacheWriteCost = (usage.cacheCreationTokens/ 1_000_000) * (price.cacheWritePerM ?? 0);

  const usd = inputCost + outputCost + cacheReadCost + cacheWriteCost;

  const lines: string[] = [
    `  input:        ${usage.inputTokens.toLocaleString()} tokens  → $${inputCost.toFixed(6)}`,
    `  output:       ${usage.outputTokens.toLocaleString()} tokens  → $${outputCost.toFixed(6)}`,
  ];
  if (usage.cacheReadTokens > 0) {
    lines.push(`  cache read:   ${usage.cacheReadTokens.toLocaleString()} tokens  → $${cacheReadCost.toFixed(6)}`);
  }
  if (usage.cacheCreationTokens > 0) {
    lines.push(`  cache write:  ${usage.cacheCreationTokens.toLocaleString()} tokens  → $${cacheWriteCost.toFixed(6)}`);
  }
  lines.push(`  total:        $${usd.toFixed(6)}`);

  return { usd, breakdown: lines.join("\n") };
}
