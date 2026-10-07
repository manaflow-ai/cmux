// Rule (f): what an action needs next is fetched ahead, so no network call sits on the input path.
// A bounded LRU of values by key. `prefetch` starts a fetch (deduplicated), `peek` reads a value
// synchronously in the input handler, `get` awaits one. Evicted and superseded fetches are aborted.

export interface PrefetchCacheOptions {
  /** Most entries kept (default 32). */
  limit?: number;
}

interface Entry<V> {
  value?: V;
  ready: boolean;
  promise: Promise<V>;
  controller: AbortController;
}

export class PrefetchCache<V> {
  private readonly entries = new Map<string, Entry<V>>();
  private readonly limit: number;

  constructor(options: PrefetchCacheOptions = {}) {
    this.limit = Math.max(1, options.limit ?? 32);
  }

  /** Starts fetching `key` unless it is cached or in flight. Never throws; a failure is forgotten. */
  prefetch(key: string, fetch: (signal: AbortSignal) => Promise<V>): Promise<V> {
    const known = this.entries.get(key);
    if (known) {
      this.touch(key, known);
      return known.promise;
    }
    const controller = new AbortController();
    const entry: Entry<V> = { ready: false, controller, promise: Promise.resolve() as Promise<V> };
    entry.promise = fetch(controller.signal).then(
      (value) => {
        if (this.entries.get(key) === entry) {
          entry.value = value;
          entry.ready = true;
        }
        return value;
      },
      (error: unknown) => {
        if (this.entries.get(key) === entry) this.entries.delete(key);
        throw error;
      },
    );
    entry.promise.catch(() => undefined);
    this.entries.set(key, entry);
    this.evict();
    return entry.promise;
  }

  /** The cached value, synchronously; undefined when it is not ready. For input handlers. */
  peek(key: string): V | undefined {
    const entry = this.entries.get(key);
    if (!entry?.ready) return undefined;
    this.touch(key, entry);
    return entry.value;
  }

  /** The value, fetching it when needed. */
  get(key: string, fetch: (signal: AbortSignal) => Promise<V>): Promise<V> {
    return this.prefetch(key, fetch);
  }

  /** Seeds a value (a result that arrived another way). */
  set(key: string, value: V): void {
    this.entries.get(key)?.controller.abort();
    this.entries.set(key, { value, ready: true, promise: Promise.resolve(value), controller: new AbortController() });
    this.evict();
  }

  /** Forgets `key` (or everything), aborting fetches in flight. */
  invalidate(key?: string): void {
    const keys = key === undefined ? Array.from(this.entries.keys()) : [key];
    for (const k of keys) {
      this.entries.get(k)?.controller.abort();
      this.entries.delete(k);
    }
  }

  get size(): number {
    return this.entries.size;
  }

  private touch(key: string, entry: Entry<V>): void {
    this.entries.delete(key);
    this.entries.set(key, entry);
  }

  private evict(): void {
    while (this.entries.size > this.limit) {
      const oldest = this.entries.keys().next().value as string;
      this.entries.get(oldest)?.controller.abort();
      this.entries.delete(oldest);
    }
  }
}
