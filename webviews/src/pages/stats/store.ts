// The Stats page's state owner: the chosen range and the summary for it. React reads it through
// `useSyncExternalStore`; a reply for a range the person already left is dropped.
import { isPageError, type PageClient } from "../shared/pageClient";
import { restoredPageInputs } from "../shared/pageState";
import { RANGES, StatsOps, type Range, type StatsSummary } from "./types";

export interface StatsSnapshot {
  range: Range;
  summary?: StatsSummary;
  loading: boolean;
  /**
   * Why the summary did not load: the app's own message when acpmux is not answering (the app
   * words it in the person's language), else none, and the page says it failed in its own words.
   */
  failed?: { message?: string };
  /** The page has no host to ask; the page says so in its own words. */
  unavailable?: boolean;
}

/** The page name its saved state carries (pageState.ts). */
export const STATS_PAGE = "stats";

/** What the page keeps across a discard: the range the person picked. */
export interface StatsInputs {
  range: Range;
}

/** The valid fields of the inputs a discarded document saved; the rest keep their defaults. */
export function restoredStatsInputs(state: unknown): Partial<StatsInputs> {
  const saved = (state as { range?: unknown } | null | undefined)?.range;
  const range = RANGES.find((known) => known === saved);
  return range === undefined ? {} : { range };
}

export class StatsStore {
  private snapshot: StatsSnapshot;
  private listeners = new Set<() => void>();
  private request = 0;

  constructor(
    private readonly client: PageClient | null,
    /** The person's UTC offset in minutes, east positive. */
    private readonly offsetMinutes: () => number = () => -new Date().getTimezoneOffset(),
  ) {
    // Nothing is on its way until the first read, so picking the default range first still reads it.
    this.snapshot = {
      range: RANGES[RANGES.length - 1],
      ...restoredStatsInputs(restoredPageInputs(client, STATS_PAGE)),
      loading: false,
    };
  }

  /** What the page keeps when it hides (pageState.ts `keep`); `restoredStatsInputs` reads it back. */
  pageInputs(): StatsInputs {
    return { range: this.snapshot.range };
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  start(): Promise<void> {
    return this.load(this.snapshot.range);
  }

  /** Reads the logs again, unless a read is already on its way (each one scans every log). */
  refresh(): Promise<void> {
    if (this.snapshot.loading) return Promise.resolve();
    return this.load(this.snapshot.range);
  }

  /** Asks for `range`, unless that range is already on its way. */
  setRange(range: Range): Promise<void> {
    if (range === this.snapshot.range && this.snapshot.loading) return Promise.resolve();
    return this.load(range);
  }

  private async load(range: Range): Promise<void> {
    if (!this.client) return this.set({ range, loading: false, unavailable: true });
    const id = ++this.request;
    // The last summary stays on screen while the next one loads.
    this.set({ ...this.snapshot, range, loading: true, failed: undefined });
    try {
      const summary = await this.client.call<StatsSummary>(StatsOps.summary, {
        days: range,
        tzOffsetMinutes: this.offsetMinutes(),
      });
      if (id === this.request) this.set({ range, summary, loading: false });
    } catch (error) {
      if (id !== this.request) return;
      // acpmux's own error text is for logs: it can be English, technical or name a path.
      const unavailable = isPageError(error) && error.code === "cmux.stats.unavailable";
      this.set({ range, loading: false, failed: { message: unavailable ? error.message : undefined } });
    }
  }

  private set(snapshot: StatsSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
