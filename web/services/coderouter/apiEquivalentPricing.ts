export const CODEROUTER_API_RATE_CARD_VERSION = "2026-08-08";

type ApiRate = {
  readonly inputUsdPerMillion: number;
  readonly cachedInputUsdPerMillion: number;
  readonly outputUsdPerMillion: number;
  readonly longContext?: {
    readonly inputTokensAbove: number;
    readonly inputMultiplier: number;
    readonly outputMultiplier: number;
  };
};

export type AggregateModelUsage = {
  readonly model: string;
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
};

export type ApiEquivalentEstimate = {
  readonly usd: number;
  readonly pricedTokens: number;
  readonly unpricedTokens: number;
};

// Public first-party API list prices as of the version date above. Matching is
// intentionally conservative: unknown models are reported as unpriced instead
// of silently receiving a plausible but incorrect dollar value.
// Sources:
// - https://developers.openai.com/api/docs/models
// - https://openai.com/index/introducing-gpt-5-2/
// - https://platform.claude.com/docs/en/about-claude/pricing
const RATES: readonly {
  readonly matches: (model: string) => boolean;
  readonly rate: ApiRate;
}[] = [
  rate(/^gpt-5\.6-sol(?:-|$)|^gpt-5\.6$/, 5, 0.5, 30, {
    inputTokensAbove: 272_000,
    inputMultiplier: 2,
    outputMultiplier: 1.5,
  }),
  rate(/^gpt-5\.6-terra(?:-|$)/, 2.5, 0.25, 15, {
    inputTokensAbove: 272_000,
    inputMultiplier: 2,
    outputMultiplier: 1.5,
  }),
  rate(/^gpt-5\.6-luna(?:-|$)/, 1, 0.1, 6, {
    inputTokensAbove: 272_000,
    inputMultiplier: 2,
    outputMultiplier: 1.5,
  }),
  rate(/^gpt-5\.(?:3-codex|2(?:-codex)?)(?:-|$)/, 1.75, 0.175, 14),
  rate(/^gpt-5(?:\.1)?-codex(?:-|$)/, 1.25, 0.125, 10),
  rate(/^claude-sonnet-5(?:-|$)/, 2, 0.2, 10),
  rate(/^claude-(?:opus-4\.[5-8]|opus-4-5|opus-4-6|opus-4-7|opus-4-8)(?:-|$)/, 5, 0.5, 25),
  rate(/^claude-sonnet-4(?:[.-][456])?(?:-|$)/, 3, 0.3, 15, {
    inputTokensAbove: 200_000,
    inputMultiplier: 2,
    outputMultiplier: 1.5,
  }),
  rate(/^claude-haiku-4[.-]5(?:-|$)/, 1, 0.1, 5),
];

export function estimateApiEquivalent(
  usage: AggregateModelUsage,
): ApiEquivalentEstimate {
  const normalizedModel = usage.model.trim().toLowerCase();
  const matched = RATES.find((candidate) =>
    candidate.matches(normalizedModel)
  );
  if (!matched) {
    return {
      usd: 0,
      pricedTokens: 0,
      unpricedTokens: usage.totalTokens,
    };
  }

  const cachedInputTokens = Math.min(
    usage.inputTokens,
    usage.cachedInputTokens,
  );
  const uncachedInputTokens = Math.max(
    0,
    usage.inputTokens - cachedInputTokens,
  );
  const longContext = matched.rate.longContext;
  const usesLongContext = longContext
    ? usage.inputTokens > longContext.inputTokensAbove
    : false;
  const inputMultiplier = usesLongContext
    ? longContext!.inputMultiplier
    : 1;
  const outputMultiplier = usesLongContext
    ? longContext!.outputMultiplier
    : 1;
  const usd =
    (
      uncachedInputTokens *
        matched.rate.inputUsdPerMillion *
        inputMultiplier +
      cachedInputTokens *
        matched.rate.cachedInputUsdPerMillion *
        inputMultiplier +
      usage.outputTokens *
        matched.rate.outputUsdPerMillion *
        outputMultiplier
    ) / 1_000_000;
  return {
    usd,
    pricedTokens: usage.totalTokens,
    unpricedTokens: 0,
  };
}

function rate(
  pattern: RegExp,
  inputUsdPerMillion: number,
  cachedInputUsdPerMillion: number,
  outputUsdPerMillion: number,
  longContext?: ApiRate["longContext"],
) {
  return {
    matches: (model: string) => pattern.test(model),
    rate: {
      inputUsdPerMillion,
      cachedInputUsdPerMillion,
      outputUsdPerMillion,
      ...(longContext ? { longContext } : {}),
    },
  };
}
