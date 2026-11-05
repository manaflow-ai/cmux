// What a session spends, as acpmux reads it from the harness's transcript (`usageStats` on every
// session summary, `ls --json` row and peer row). Leo, 2026-10-30: "that visibility into
// huge-blue guys was (and is?) pretty bad i feel like we can make more improvements to
// acpmux/cmux-next". Four deputies ran for hours with no autocompact cap at 290-330k of context
// and 67-90 subagents each, and nothing in the app showed it. Session Info, the session hover
// card and the Sessions by usage list read these numbers; acpmux recomputes them on each list
// read and at turn end, so the pane adds no timer and no per-token work for them.

import type { Translate } from "./i18n";

/** acpmux's `usageStats` (ao-vis-data's contract). Absent while the harness has no readable
 *  transcript; a number acpmux could not read is absent here too. */
export type SessionUsageStats = {
  /** The harness executable as launched (`claude-sr2`, `claude`, `codex-acp`). */
  launcher?: string;
  /** Whether the session compacts on its own (acpmux `autocompact`): `capped`, `none` (no
   *  --autocompact or CLAUDE_CODE_AUTO_COMPACT_WINDOW), or `unknown` (also when acpmux sent none).
   *  Only `none` is a session to warn about. */
  autocompact: "capped" | "none" | "unknown";
  /** The autocompact window in tokens, when acpmux read it. */
  autocompactCap?: number;
  /** Input and cache tokens of the last model call: what each call carries now. */
  contextTokens?: number;
  contextWindow?: number;
  /** Each count is absent when acpmux did not send it: unknown, never a synthesized zero. */
  compactions24h?: number;
  subagentsLive?: number;
  subagents1h?: number;
  /** Subagents spawned in the last 24 hours. */
  subagents24h?: number;
  /** Input, output, cache read and cache write tokens of the last 24 hours. */
  tokens24h?: number;
  costUsd24h?: number;
  /** Model calls of the last 24 hours, subagents' included. */
  calls24h?: number;
  /** Of those calls' prompt tokens (input, cache reads and cache writes), the share the prompt
   *  cache served, 0 to 1. Leo, 2026-11-03, on the hour-long prompt cache: "holy shit that's such a
   *  big win that cmux-next/acpmux can get....": the share and the cost per call show the win. */
  cacheReadShare24h?: number;
  /** `costUsd24h` over the priced calls: what one call costs at list prices. */
  costPerCallUsd24h?: number;
  updatedAt: number;
};

const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
const share = (value: unknown) => {
  const n = count(value);
  return n !== undefined && n <= 1 ? n : undefined;
};
const label = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/** acpmux's `usageStats`, or undefined when it sent none or sent something else. */
export function usageStatsOf(value: unknown): SessionUsageStats | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  const updatedAt = count(raw.updatedAt);
  if (updatedAt === undefined) return undefined;
  const optional = <K extends string, V>(key: K, v: V | undefined) =>
    (v === undefined ? {} : { [key]: v }) as { [P in K]?: V };
  return {
    ...optional("launcher", label(raw.launcher)),
    autocompact: raw.autocompact === "capped" || raw.autocompact === "none" ? raw.autocompact : "unknown",
    // A cap of 0 is no window: acpmux never sends one.
    ...optional("autocompactCap", count(raw.autocompactCap) || undefined),
    ...optional("contextTokens", count(raw.contextTokens)),
    ...optional("contextWindow", count(raw.contextWindow) || undefined),
    ...optional("compactions24h", count(raw.compactions24h)),
    ...optional("subagentsLive", count(raw.subagentsLive)),
    ...optional("subagents1h", count(raw.subagents1h)),
    ...optional("subagents24h", count(raw.subagents24h)),
    ...optional("tokens24h", count(raw.tokens24h)),
    ...optional("costUsd24h", count(raw.costUsd24h)),
    ...optional("calls24h", count(raw.calls24h)),
    ...optional("cacheReadShare24h", share(raw.cacheReadShare24h)),
    ...optional("costPerCallUsd24h", count(raw.costPerCallUsd24h)),
    updatedAt,
  };
}

/** `usageStatsOf(value)`, or `previous` when that reads the same: a snapshot per token then hands
 *  Usage the same object, so it draws nothing again until acpmux's numbers change. */
export function sameUsageStats(value: unknown, previous: SessionUsageStats | undefined): SessionUsageStats | undefined {
  const next = usageStatsOf(value);
  if (!next || !previous) return next;
  const keys = new Set([...Object.keys(next), ...Object.keys(previous)]) as Set<keyof SessionUsageStats>;
  for (const key of keys) if (next[key] !== previous[key]) return next;
  return previous;
}

/** "$1,240" from 1240.4, "$12.40", "$0.08": whole dollars from $100, cents below. */
export function usageCost(usd: number, locale?: string): string {
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: usd >= 100 ? 0 : 2,
    minimumFractionDigits: usd >= 100 ? 0 : 2,
  }).format(usd);
}

/** "94.3%" from 0.9431: one decimal, so a 94.3% and a 98.1% chat read apart. */
export function usageShare(share: number, locale?: string): string {
  return new Intl.NumberFormat(locale, { style: "percent", minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(
    share,
  );
}

/** "$0.35", "$0.004": a call can cost under a cent, so small costs keep two significant digits. */
export function usageCallCost(usd: number, locale?: string): string {
  if (usd >= 0.01) return usageCost(usd, locale);
  return new Intl.NumberFormat(locale, { style: "currency", currency: "USD", maximumSignificantDigits: 2 }).format(usd);
}

/** How Usage draws the prompt cache's numbers: two rows (shipped), or one row with both. */
export type UsageCacheLayout = "rows" | "combined";

/** Usage's prompt cache rows for this chat (web and native panels): the share of prompt tokens
 *  the cache served and the cost of one call, each over the last 24 hours. A number acpmux did
 *  not send reads as the unknown mark. */
export function cacheUsageRows(
  t: Translate,
  stats: SessionUsageStats,
  locale?: string,
  layout: UsageCacheLayout = "rows",
): { id: string; name: string; value: string }[] {
  const shareText = stats.cacheReadShare24h === undefined ? UNKNOWN : usageShare(stats.cacheReadShare24h, locale);
  const costText = stats.costPerCallUsd24h === undefined ? UNKNOWN : usageCallCost(stats.costPerCallUsd24h, locale);
  if (layout === "combined")
    return [
      {
        id: "cache",
        name: t("sessionInfo.usage.promptCache24h"),
        value: t("sessionInfo.usage.promptCacheValue", { share: shareText, cost: costText }),
      },
    ];
  return [
    { id: "cache-read", name: t("sessionInfo.usage.cacheRead24h"), value: shareText },
    { id: "call-cost", name: t("sessionInfo.usage.costPerCall24h"), value: costText },
  ];
}

/** What an unknown number shows: never a synthesized 0 or $0.00. */
export const UNKNOWN = "—";

/** "312K", "1.2M": the compact token count the Context section uses. */
export function usageTokens(tokens: number, locale?: string): string {
  return new Intl.NumberFormat(locale, { notation: "compact", maximumFractionDigits: 1 }).format(tokens);
}

/** How the Sessions by usage list orders its rows. */
export type UsageSort = "cost" | "context";

/** The sessions with usage, highest first by `sort`; ties by the other measure, then by id so a
 *  refresh never reorders equal rows. Sessions without `usageStats` are left out. */
export function byUsage<T extends { sessionId: string; usageStats?: SessionUsageStats }>(
  sessions: readonly T[],
  sort: UsageSort,
): T[] {
  const cost = (entry: T) => entry.usageStats?.costUsd24h ?? -1;
  const context = (entry: T) => entry.usageStats?.contextTokens ?? -1;
  const [first, second] = sort === "cost" ? [cost, context] : [context, cost];
  return sessions
    .filter((entry) => entry.usageStats)
    .sort(
      (a, b) =>
        first(b) - first(a) ||
        second(b) - second(a) ||
        (a.sessionId < b.sessionId ? -1 : a.sessionId > b.sessionId ? 1 : 0),
    );
}

/** The context `usage` read against the window the session compacts at, as Claude Code's own
 *  /context reads it (Leo 2026-10-20, of a ring that read "213.1K of 1M tokens": "I usually have,
 *  like, 400K on my typical [Claude] sessions"; 2026-11-02, of "/ 1M" on a 400k chat: "whatever a
 *  user set their compact window to it should be that instead of always showing the defautl"). The
 *  smaller of the window /context itself names (`breakdown.maxTokens`, which already reads the
 *  person's autocompact setting) and acpmux's autocompact cap, each only when it is under the
 *  model's window. `usage` itself when neither is. */
export function compactingUsage<U extends { used: number; size: number }>(
  usage: U | undefined,
  stats: SessionUsageStats | undefined,
  breakdown?: { maxTokens?: unknown },
): U | undefined {
  if (!usage) return usage;
  const under = (n: unknown) =>
    typeof n === "number" && Number.isFinite(n) && n > 0 && (usage.size <= 0 || n < usage.size) ? n : undefined;
  const windows = [
    under(breakdown?.maxTokens),
    under(stats?.autocompact === "capped" ? stats.autocompactCap : undefined),
  ];
  const known = windows.filter((n): n is number => n !== undefined);
  return known.length === 0 ? usage : { ...usage, size: Math.min(...known) };
}
