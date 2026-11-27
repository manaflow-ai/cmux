/// A memo keyed by object, as a WeakMap is, whose table stays bounded however many keys pass
/// through it.
///
/// A WeakMap's table grows to the most entries it held at once and keeps that size after the
/// collector frees them: a chat that grew to 100k rows kept a table sized for every row object
/// made between two collections (1 MB a memo, half of a hidden chat's growth from 4k to 20k
/// rows), though it holds a few thousand rows (Leo, 2026-11-14: "memory and cpu staying flat on
/// infinite chats"). This one writes into a young table and, every `limit` writes, retires it to
/// old and starts a new young one; a key read from old moves to young. So a key read since the
/// last retirement stays, one read in neither generation is computed again, and each table holds
/// `limit` writes at most.
///
/// Only for pure memos: a value computed again must equal the first (`compute` of the same key).
export class RowMemo<K extends object, V> {
  #young = new WeakMap<K, V>();
  #old = new WeakMap<K, V>();
  #writes = 0;
  readonly #limit: number;

  constructor(limit = ROW_MEMO_LIMIT) {
    this.#limit = limit;
  }

  get(key: K): V | undefined {
    const young = this.#young.get(key);
    if (young !== undefined || this.#young.has(key)) return young;
    if (!this.#old.has(key)) return undefined;
    const old = this.#old.get(key) as V;
    this.set(key, old);
    return old;
  }

  has(key: K): boolean {
    return this.#young.has(key) || this.#old.has(key);
  }

  set(key: K, value: V): this {
    this.#young.set(key, value);
    if (++this.#writes >= this.#limit) {
      this.#old = this.#young;
      this.#young = new WeakMap();
      this.#writes = 0;
    }
    return this;
  }

  /// The value for `key`, computed once while the key stays in either generation.
  read(key: K, compute: (key: K) => V): V {
    if (this.has(key)) return this.get(key) as V;
    const value = compute(key);
    this.set(key, value);
    return value;
  }
}

/// More than a chat holds at once (direct.ts HELD_RECORDS, 4000 records, makes fewer rows), so the
/// rows one pass reads all stay between two retirements.
export const ROW_MEMO_LIMIT = 8192;
