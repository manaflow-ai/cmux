// What a session spends, as acpmux reads it from the harness's transcript (`usageStats` on every
// session summary, `ls --json` row and peer row). Leo, 2026-10-30: "that visibility into
// huge-blue guys was (and is?) pretty bad i feel like we can make more improvements to
// acpmux/cmux-next". Four deputies ran for hours with no autocompact cap at 290-330k of context
// and 67-90 subagents each, and nothing in the app showed it. Session Info, the session hover
// card and the Sessions by usage list read these numbers; acpmux recomputes them on each list
// read and at turn end, so the pane adds no timer and no per-token work for them.

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
  updatedAt: number;
};

const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
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
