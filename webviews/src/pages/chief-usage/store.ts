// The Chief Usage page's state owner: the chosen window and grouping, and the summary for them.
// React reads it through `useSyncExternalStore`. It reads on start, when the window or grouping
// changes and on Refresh; never on a timer. A reply for a choice the person already left is dropped.
import { isPageError, type PageClient } from "../shared/pageClient";
import { ChiefUsageOps, type UsageBy, type UsageQuery, type UsageSummary, type UsageWindow } from "./types";

/** How many of the most expensive units the page lists. */
export const TOP_COUNT = 10;

export interface ChiefUsageSnapshot {
  window: UsageWindow;
  by: UsageBy;
  summary?: UsageSummary;
  loading: boolean;
  /**
   * Why the summary did not load: the app's own message when it cannot run the tool (already in
   * the person's language), else none, and the page says it failed in its own words.
   */
  failed?: { message?: string };
  /** The page has no host to ask. */
  unavailable?: boolean;
}

export class ChiefUsageStore {
  private snapshot: ChiefUsageSnapshot;
  private listeners = new Set<() => void>();
  private request = 0;

  constructor(
    private readonly client: PageClient | null,
    initial: { window?: UsageWindow; by?: UsageBy } = {},
  ) {
    this.snapshot = { window: initial.window ?? "7d", by: initial.by ?? "chief", loading: true };
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  start(): Promise<void> {
    return this.load(this.snapshot.window, this.snapshot.by);
  }

  /** Reads again, unless a read is already on its way. */
  refresh(): Promise<void> {
    if (this.snapshot.loading) return Promise.resolve();
    return this.load(this.snapshot.window, this.snapshot.by);
  }

  /** Asks for `window`, unless that choice is already on its way. */
  setWindow(window: UsageWindow): Promise<void> {
    if (window === this.snapshot.window && this.snapshot.loading) return Promise.resolve();
    return this.load(window, this.snapshot.by);
  }

  /** Groups the breakdown by `by`, unless that choice is already on its way. */
  setBy(by: UsageBy): Promise<void> {
    if (by === this.snapshot.by && this.snapshot.loading) return Promise.resolve();
    return this.load(this.snapshot.window, by);
  }

  private async load(window: UsageWindow, by: UsageBy): Promise<void> {
    if (!this.client) return this.set({ window, by, loading: false, unavailable: true });
    const id = ++this.request;
    // The last summary stays on screen while the next one loads.
    this.set({ ...this.snapshot, window, by, loading: true, failed: undefined });
    try {
      const query: UsageQuery = { since: window, by, top: TOP_COUNT };
      const summary = await this.client.call<UsageSummary>(ChiefUsageOps.summary, query);
      if (id === this.request) this.set({ window, by, summary, loading: false });
    } catch (error) {
      if (id !== this.request) return;
      // The tool's own error text is for logs: it can be English, technical or name a path.
      const unavailable = isPageError(error) && error.code === "cmux.chief_usage.unavailable";
      this.set({
        ...this.snapshot,
        window,
        by,
        loading: false,
        failed: { message: unavailable ? error.message : undefined },
      });
    }
  }

  private set(snapshot: ChiefUsageSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
