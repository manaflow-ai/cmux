// A table of state kept by row object, whose entries matter only for the rows on hand: a row replaced
// by a new object (a streamed reply's next delta, a page's rows rebuilt) leaves an entry no read takes.
// V8 frees those entries' values on GC, but a WeakMap's backing table keeps its peak capacity, so a
// chat's table grows by every row object it ever held and never shrinks: tens of MB in a 100k-row
// chat (Leo, 2026-11-14: "memory and cpu staying flat on infinite chats").
//
// `compacted` gives a fresh table of only the live rows' entries once more than twice as many writes
// as live rows went in since the table was made, so the table stays within a few times the rows on
// hand. Rebuilding costs O(live rows) once per O(live rows) writes: constant per write.

/// Writes past twice the live rows a table takes before `compacted` rebuilds it.
export const LIVE_ROW_TABLE_SLACK = 1_024;

export class LiveRowTable<K extends object, V> extends WeakMap<K, V> {
  #writes = 0;

  override set(key: K, value: V): this {
    this.#writes += 1;
    return super.set(key, value);
  }

  /// This table while it took no more than `2 * size + slack` writes, else a new one holding only
  /// `live`'s entries (`size` of them at most).
  compacted(size: number, live: () => Iterable<K>, slack = LIVE_ROW_TABLE_SLACK): LiveRowTable<K, V> {
    if (this.#writes <= 2 * size + slack) return this;
    const next = new LiveRowTable<K, V>();
    for (const key of live()) {
      const value = this.get(key);
      if (value !== undefined || this.has(key)) next.set(key, value as V);
    }
    return next;
  }
}
