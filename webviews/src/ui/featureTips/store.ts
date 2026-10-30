// Where feature tips keep their state (leo-workspace design/feature-tips.md, "State"): the app,
// through the page's host. An agent page's own storage ends with the launch, and pages do not share
// it (a WebKit chat page has a store of its own), so the app keeps both:
// - for good: each tip closed with its X, its feature used, or the launches it showed on;
// - for this launch: the one tip the launch shows. `claim` is answered on the app's main actor, one
//   page at a time, so two pages never both take it.
import type { TipRecord, TipRecords } from "./policy";

export interface TipHost {
  /** The records; rejects on an app that keeps none. */
  read(): Promise<TipRecords>;
  write(id: string, record: TipRecord): Promise<TipRecords | void>;
  /** Takes this launch's one tip for `id`: true for the first claim of the launch, false after. */
  claim(id: string): Promise<boolean>;
}

/** A host kept in memory, one launch: tests and the gallery. `relaunch` starts the next launch. */
export function memoryTipHost(initial: TipRecords = {}): TipHost & {
  records: Record<string, string>;
  relaunch(): void;
} {
  const records: Record<string, string> = { ...initial };
  let claimed: string | null = null;
  return {
    records,
    read: async () => ({ ...records }),
    write: async (id, record) => {
      records[id] = record;
      return { ...records };
    },
    claim: async (id) => {
      if (claimed !== null) return false;
      claimed = id;
      return true;
    },
    relaunch: () => {
      claimed = null;
    },
  };
}
