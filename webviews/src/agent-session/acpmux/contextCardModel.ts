import { useEffect, useState } from "react";
import type { Breakdown, BreakdownRow } from "./session-info/contextSectionModel";

/// One stretch of the stacked bar, as a share of the whole window (0-100).
export type ContextSegment = {
  kind: "setup" | "conversation" | "used";
  tokens: number;
  percent: number;
};

/// The bar's stretches: the agent's setup and the conversation when the setup is known (and
/// within what is used), else what is used as one. The rest of the track is free. Together they
/// never pass the whole track, even when a harness reports more used than its window.
export function contextSegments(used: number, size: number, setup?: number): ContextSegment[] {
  if (!(size > 0)) return [];
  const share = (tokens: number) => Math.max(0, (tokens / size) * 100);
  const parts: Array<Omit<ContextSegment, "percent">> =
    setup !== undefined && setup > 0 && setup <= used
      ? [
          { kind: "setup", tokens: setup },
          { kind: "conversation", tokens: used - setup },
        ]
      : [{ kind: "used", tokens: used }];
  let left = 100;
  return parts
    .filter((part) => part.tokens > 0)
    .map((part) => {
      const percent = Math.min(left, share(part.tokens));
      left -= percent;
      return { ...part, percent };
    });
}

/// `group`: one of the card's three headline groups, which the card names in the pane's language;
/// a row without one is the harness's own category, drawn under the name it reported.
type CompactGroup = "messages" | "tools" | "system";
type CompactBreakdownRow = { name: string; group?: CompactGroup; tokens: number; share: number; tone: number };

/**
 * Pick the three useful headline categories for the small composer card. Session Info keeps the
 * complete `/context` report; the card only needs enough signal to answer what is using the window.
 */
export function compactBreakdownRows(breakdown: Breakdown): CompactBreakdownRow[] {
  const used = breakdown.rows.filter((row) => row.kind === "used");
  const grouped: Array<{ group: CompactGroup; rows: BreakdownRow[] }> = [
    { group: "messages", rows: used.filter((row) => /message/i.test(row.name)) },
    { group: "tools", rows: used.filter((row) => /tool/i.test(row.name)) },
    { group: "system", rows: used.filter((row) => !/message|tool/i.test(row.name)) },
  ];
  const rows = grouped
    .filter((group) => group.rows.length > 0)
    .map((group, tone) => ({
      name: group.group,
      group: group.group,
      tokens: group.rows.reduce((sum, row) => sum + row.tokens, 0),
      share: group.rows.reduce((sum, row) => sum + (row.share ?? 0), 0),
      tone,
    }));
  if (rows.length > 0) return rows;
  return used.slice(0, 3).map((row, tone) => ({
    name: row.name,
    tokens: row.tokens,
    share: row.share ?? 0,
    tone,
  }));
}

/// Under this much left, the cache line says it is about to lapse.
export const CACHE_SOON_MS = 60_000;

/// "3:12", or "52:10" for an hour's cache: the time left, rounded up to the second.
export function cacheTimeLeft(ms: number): string {
  const seconds = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/// The time until `expiresAt` (unix ms), ticking each second while it is ahead. The tick stops at
/// the expiry, when `expiresAt` changes, and when the card unmounts. Undefined without an expiry.
export function useCacheTimeLeft(expiresAt: number | undefined, now: () => number = Date.now): number | undefined {
  const [at, setAt] = useState(now);
  useEffect(() => {
    if (expiresAt === undefined) return;
    setAt(now());
    if (expiresAt <= now()) return;
    const tick = window.setInterval(() => {
      const current = now();
      setAt(current);
      if (current >= expiresAt) window.clearInterval(tick);
    }, 1000);
    return () => window.clearInterval(tick);
  }, [expiresAt, now]);
  return expiresAt === undefined ? undefined : Math.max(0, expiresAt - at);
}
