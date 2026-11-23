import { type Translate } from "../i18n";
import { type SessionUsageStats, usageCost, usageTokens } from "../usageStats";

/// Rows the list shows before View all.
export const USAGE_SHOWN = 5;

/// The section's one-line value: this chat's 24h cost, else its 24h tokens.
export function usageMeta(t: Translate, stats: SessionUsageStats | undefined, locale?: string): string | undefined {
  if (!stats) return undefined;
  if (stats.costUsd24h !== undefined)
    return t("sessionInfo.usage.cost24hValue", { cost: usageCost(stats.costUsd24h, locale) });
  if (stats.tokens24h !== undefined)
    return t("sessionInfo.usage.tokens24hValue", { tokens: usageTokens(stats.tokens24h, locale) });
  return undefined;
}
