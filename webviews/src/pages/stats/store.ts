// The Stats page's state owner: the chosen range and the summary for it. React reads it through
// `useSyncExternalStore`; a reply for a range the person already left is dropped.
import { isPageError, type PageClient } from "../shared/pageClient";
import { RANGES, StatsOps, type Range, type StatsSummary } from "./types";

export interface StatsSnapshot {
  range: Range;
  summary?: StatsSummary;
  loading: boolean;
  /** Why the summary did not load, in plain words. */
  failed?: string;
  /** The page has no host to ask; the page says so in its own words. */
  unavailable?: boolean;
}

export class StatsStore {
  private snapshot: StatsSnapshot = { range: RANGES[RANGES.length - 1], loading: true };
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

  refresh(): Promise<void> {
    return this.load(this.snapshot.range);
  }

  setRange(range: Range): Promise<void> {
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
      this.set({ range, loading: false, failed: isPageError(error) ? error.message : String(error) });
    }
  }

  private set(snapshot: StatsSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
