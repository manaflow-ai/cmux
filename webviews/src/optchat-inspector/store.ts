// A small read cache over the inspector API for useSyncExternalStore: one entry per URL, fetched
// on first read, optionally refreshed on an interval while something is subscribed. No effects:
// the subscription itself starts and stops the refresh timer.

export type Entry<T> = { data?: T; error?: string; loading: boolean };

type Slot = {
  entry: Entry<unknown>;
  listeners: Set<() => void>;
  timer?: ReturnType<typeof setInterval>;
  every?: number;
  /** When the last listener left (0 while subscribed): idle slots are evicted oldest first. */
  idleSince: number;
};

/** Idle answers kept for a quick return (a turn's prompt can be 100 KB or more). */
const KEEP_IDLE = 24;

export type Fetcher = (url: string) => Promise<unknown>;

/** The local inspector: same-origin HTTP on the brain host's loopback server (cookie session). */
export const httpFetcher: Fetcher = async (url) => {
  const response = await fetch(url, { credentials: "same-origin", headers: { Accept: "application/json" } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((body as { error?: string }).error ?? `HTTP ${response.status}`);
  return body;
};

/** A page-bridge call (the app's `cmuxPage` handler), as `PageClient.call` shapes it. */
export type BridgeCall = (op: string, params: unknown) => Promise<unknown>;

/**
 * A remote Chief's inspector: the app page (cmux-page://cmux.chief-inspector/) asks the app,
 * which relays `cmux.chief_inspector.get {path, query}` to the brain's daemon.
 */
export function bridgeFetcher(call: BridgeCall): Fetcher {
  return async (url) => {
    const parsed = new URL(url, "cmux-page://cmux.chief-inspector/");
    const query: Record<string, string> = {};
    parsed.searchParams.forEach((value, key) => {
      query[key] = value;
    });
    try {
      return await call("cmux.chief_inspector.get", { path: parsed.pathname, query });
    } catch (error) {
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  };
}

/** One code path, chosen by origin: the app page uses the bridge, the loopback page uses HTTP. */
export function fetcherFor(protocol: string, call: BridgeCall | null): Fetcher {
  return protocol === "cmux-page:" && call ? bridgeFetcher(call) : httpFetcher;
}

export const defaultFetcher: Fetcher = httpFetcher;

export class ApiStore {
  private slots = new Map<string, Slot>();
  constructor(private fetcher: Fetcher = defaultFetcher) {}

  private slot(url: string): Slot {
    let s = this.slots.get(url);
    if (!s) {
      s = { entry: { loading: true }, listeners: new Set(), idleSince: Date.now() };
      this.slots.set(url, s);
      this.evict();
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
    s.idleSince = 0;
    if (every && !s.timer) {
      s.every = every;
      s.timer = setInterval(() => {
        if (typeof document === "undefined" || document.visibilityState !== "hidden") void this.load(url);
      }, every);
    }
    return () => {
      s.listeners.delete(listener);
      if (s.listeners.size === 0) {
        if (s.timer) clearInterval(s.timer);
        s.timer = undefined;
        s.idleSince = Date.now();
        this.evict();
      }
    };
  }

  /** Drops the oldest idle answers beyond `KEEP_IDLE`. */
  private evict(): void {
    const idle = [...this.slots]
      .filter(([, s]) => s.listeners.size === 0)
      .sort((a, b) => a[1].idleSince - b[1].idleSince);
    for (const [url] of idle.slice(0, Math.max(0, idle.length - KEEP_IDLE))) this.slots.delete(url);
  }
}
