// A small read cache over the inspector API for useSyncExternalStore: one entry per URL, fetched
// on first read, optionally refreshed on an interval while something is subscribed. No effects:
// the subscription itself starts and stops the refresh timer.

export type Entry<T> = { data?: T; error?: string; loading: boolean };

type Slot = {
  entry: Entry<unknown>;
  listeners: Set<() => void>;
  timer?: ReturnType<typeof setInterval>;
  every?: number;
};

export type Fetcher = (url: string) => Promise<unknown>;

export const defaultFetcher: Fetcher = async (url) => {
  const response = await fetch(url, { credentials: "same-origin", headers: { Accept: "application/json" } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((body as { error?: string }).error ?? `HTTP ${response.status}`);
  return body;
};

export class ApiStore {
  private slots = new Map<string, Slot>();
  constructor(private fetcher: Fetcher = defaultFetcher) {}

  private slot(url: string): Slot {
    let s = this.slots.get(url);
    if (!s) {
      s = { entry: { loading: true }, listeners: new Set() };
      this.slots.set(url, s);
      void this.load(url);
    }
    return s;
  }

  /** The current entry for `url` (starts the first fetch). */
  get<T>(url: string): Entry<T> {
    return this.slot(url).entry as Entry<T>;
  }

  /** Fetches `url` again; listeners hear the result. */
  async load(url: string): Promise<void> {
    const s = this.slots.get(url);
    if (!s) return;
    try {
      const data = await this.fetcher(url);
      s.entry = { data, loading: false };
    } catch (e) {
      s.entry = { ...s.entry, error: e instanceof Error ? e.message : String(e), loading: false };
    }
    for (const l of s.listeners) l();
  }

  /** Subscribes to `url`; `every` ms refreshes it while subscribed. Returns the unsubscribe. */
  subscribe(url: string, listener: () => void, every?: number): () => void {
    const s = this.slot(url);
    s.listeners.add(listener);
    if (every && !s.timer) {
      s.every = every;
      s.timer = setInterval(() => {
        if (typeof document === "undefined" || document.visibilityState !== "hidden") void this.load(url);
      }, every);
    }
    return () => {
      s.listeners.delete(listener);
      if (s.listeners.size === 0 && s.timer) {
        clearInterval(s.timer);
        s.timer = undefined;
      }
    };
  }
}
