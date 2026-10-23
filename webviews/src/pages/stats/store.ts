// The Stats page's state owner: the chosen range and the summary for it. React reads it through
// `useSyncExternalStore`; a reply for a range the person already left is dropped.
import { isPageError, type PageClient } from "../shared/pageClient";
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

export class StatsStore {
  // Nothing is on its way until the first read, so picking the default range first still reads it.
  private snapshot: StatsSnapshot = { range: RANGES[RANGES.length - 1], loading: false };
  private listeners = new Set<() => void>();
  private request = 0;

  constructor(
    private readonly client: PageClient | null,
    /** The person's UTC offset in minutes, east positive. */
    private readonly offsetMinutes: () => number = () => -new Date().getTimezoneOffset(),
  ) {}

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
