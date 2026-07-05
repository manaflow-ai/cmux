import type { Family, Usage } from "./types";

export const CATALOG_AS_OF = "2026-07-05";

export interface PriceEntry {
  family: Family;
  inputPer1M: number;
  outputPer1M: number;
  cacheReadPer1M: number;
  cacheWritePer1M: number;
}

// Duplicated for worker-local pricing; the web-side counterpart owns billing re-price.
// Sources checked 2026-07-05: https://www.anthropic.com/pricing and https://openai.com/api/pricing/
export const PRICING_CATALOG: Record<string, PriceEntry> = {
  "claude-opus-4": { family: "anthropic", inputPer1M: 15_000_000, outputPer1M: 75_000_000, cacheReadPer1M: 1_500_000, cacheWritePer1M: 18_750_000 },
  "claude-opus-4-1": { family: "anthropic", inputPer1M: 15_000_000, outputPer1M: 75_000_000, cacheReadPer1M: 1_500_000, cacheWritePer1M: 18_750_000 },
  "claude-sonnet-4": { family: "anthropic", inputPer1M: 3_000_000, outputPer1M: 15_000_000, cacheReadPer1M: 300_000, cacheWritePer1M: 3_750_000 },
  "claude-sonnet-4-5": { family: "anthropic", inputPer1M: 3_000_000, outputPer1M: 15_000_000, cacheReadPer1M: 300_000, cacheWritePer1M: 3_750_000 },
  "claude-haiku-4-5": { family: "anthropic", inputPer1M: 1_000_000, outputPer1M: 5_000_000, cacheReadPer1M: 100_000, cacheWritePer1M: 1_250_000 },
  "gpt-5": { family: "openai", inputPer1M: 1_250_000, outputPer1M: 10_000_000, cacheReadPer1M: 125_000, cacheWritePer1M: 0 },
  "gpt-5-mini": { family: "openai", inputPer1M: 250_000, outputPer1M: 2_000_000, cacheReadPer1M: 25_000, cacheWritePer1M: 0 },
  "gpt-5-nano": { family: "openai", inputPer1M: 50_000, outputPer1M: 400_000, cacheReadPer1M: 5_000, cacheWritePer1M: 0 },
  "gpt-5.5-codex": { family: "openai", inputPer1M: 1_250_000, outputPer1M: 10_000_000, cacheReadPer1M: 125_000, cacheWritePer1M: 0 },
  "o3": { family: "openai", inputPer1M: 2_000_000, outputPer1M: 8_000_000, cacheReadPer1M: 500_000, cacheWritePer1M: 0 },
  "o4-mini": { family: "openai", inputPer1M: 1_100_000, outputPer1M: 4_400_000, cacheReadPer1M: 275_000, cacheWritePer1M: 0 },
};

export function lookupPrice(model: string | undefined): PriceEntry | null {
  return lookupPriceMatch(model)?.price ?? null;
}

export function lookupPriceMatch(model: string | undefined): { modelId: string; price: PriceEntry } | null {
  if (!model) return null;
  const id = model.toLowerCase();
  const exact = PRICING_CATALOG[id];
  if (exact) return { modelId: id, price: exact };
  const key = Object.keys(PRICING_CATALOG)
    .filter((candidate) => id.startsWith(`${candidate}-`))
    .sort((a, b) => b.length - a.length)[0];
  if (key) return { modelId: key, price: PRICING_CATALOG[key] as PriceEntry };
  return null;
}

export function priceUsageMicros(model: string | undefined, usage: Usage): number | null {
  const price = lookupPrice(model);
  if (!price) return null;
  return (
    priceComponent(usage.inputTokens, price.inputPer1M) +
    priceComponent(usage.outputTokens, price.outputPer1M) +
    priceComponent(usage.cacheReadTokens, price.cacheReadPer1M) +
    priceComponent(usage.cacheWriteTokens, price.cacheWritePer1M)
  );
}

export function priceComponent(tokens: number, microsPer1M: number): number {
  if (tokens <= 0 || microsPer1M <= 0) return 0;
  return Math.ceil((tokens * microsPer1M) / 1_000_000);
}
