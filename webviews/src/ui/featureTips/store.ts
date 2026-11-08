// Where feature tips keep their state (leo-workspace design/feature-tips.md, "State"): the app,
// through the page's host, for the life of the install. An agent page's own storage ends with the
// launch and pages share none, so the app keeps every record, the features the person used (any
// browser tab, by any path, is a use of the browser), and when a tip last showed. `claim` asks the
// app to show one tip: it says yes only to a tip that never showed, about a feature never used, at
// least 14 days after the last tip (Swift AgentPaneFeatureTipRecords).
import type { TipRecord, TipState } from "./policy";

export interface TipHost {
  /** The install's state; rejects on an app that keeps none. */
  read(): Promise<TipState>;
  write(id: string, record: TipRecord): Promise<unknown>;
  /** Asks to show tip `id` about `feature`: true at most once per tip per install. */
  claim(id: string, feature: string | undefined): Promise<boolean>;
}

/** The fewest days between two tips (Swift AgentPaneFeatureTipRecords.minimumDaysBetweenTips). */
export const TIP_INTERVAL_DAYS = 14;

/** A host kept in memory, as the app keeps it: tests and the gallery. */
export function memoryTipHost(initial: Record<string, string> = {}): TipHost & {
  records: Record<string, string>;
  used: Set<string>;
  /** When a tip last showed (ms), and the clock claims read. */
  lastShownAt: number | null;
  now: () => number;
} {
  const host = {
    records: { ...initial } as Record<string, string>,
    used: new Set<string>(),
    lastShownAt: null as number | null,
    now: () => Date.now(),
    read: async (): Promise<TipState> => ({ records: { ...host.records }, used: new Set(host.used) }),
    write: async (id: string, record: TipRecord) => {
      const kept = host.records[id];
      if (kept !== "closed" && kept !== "used") host.records[id] = record;
    },
    claim: async (id: string, feature: string | undefined) => {
      if (host.records[id] !== undefined || (feature !== undefined && host.used.has(feature))) return false;
      if (host.lastShownAt !== null && host.now() - host.lastShownAt < TIP_INTERVAL_DAYS * 86_400_000) return false;
      host.records[id] = "shown";
      host.lastShownAt = host.now();
      return true;
    },
  };
  return host;
}
