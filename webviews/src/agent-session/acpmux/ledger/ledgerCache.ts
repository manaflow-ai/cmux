import type { LedgerGroup, LedgerRange, LedgerReply } from "./ledgerModel";

/// Tokens in: uncached input plus cache writes, never cache reads.
export type LedgerView = { range: LedgerRange; group: LedgerGroup; reply?: LedgerReply };

/// What Costs last showed, kept by History (newtab/HistoryScreen.tsx) while another tab shows.
export type LedgerCache = { view(): LedgerView | undefined; keep(view: LedgerView): void };

export function createLedgerCache(): LedgerCache {
  let view: LedgerView | undefined;
  return {
    view: () => view,
    keep: (next) => {
      view = next;
    },
  };
}
