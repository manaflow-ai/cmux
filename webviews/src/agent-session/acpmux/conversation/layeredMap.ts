// An immutable map that a change copies only in part: each change is a layer over the last value,
// and a layer folds into the one under it while that one is no more than twice its size, so a
// lookup walks O(log n) layers and a change copies O(log n) entries amortized. React state that
// grows with the transcript (VirtualTranscript's drawn heights, one per row drawn) changes a row or
// two per streamed token; a `new Map(current)` per change copied every row's entry, and made each
// token's work grow with the chat (bench/transcript-replay.bench.ts long log, 5,000 rows).
//
// A value is never changed after it is made, so React may call an updater again on an older value
// (a rebased update) and get the same answer.

/// A layer's entry: a value, or `undefined` where the layer deletes the key.
type Layer<V> = ReadonlyMap<string, V | undefined>;

export class LayeredMap<V> {
  private constructor(
    private readonly own: Layer<V>,
    private readonly under: LayeredMap<V> | undefined,
    /// Keys with a value, over every layer.
    readonly size: number,
  ) {}

  static empty<V>(): LayeredMap<V> {
    return new LayeredMap<V>(new Map(), undefined, 0);
  }

  get(key: string): V | undefined {
    if (this.own.has(key)) return this.own.get(key);
    for (let at = this.under; at; at = at.under) if (at.own.has(key)) return at.own.get(key);
    return undefined;
  }

  has(key: string): boolean {
    return this.get(key) !== undefined;
  }

  /// Every key with a value, newest layer first (O(entries): for rare whole-map passes only).
  *keys(): IterableIterator<string> {
    const seen = new Set<string>();
    for (const own of this.layers())
      for (const [key, value] of own) {
        if (seen.has(key)) continue;
        seen.add(key);
        if (value !== undefined) yield key;
      }
  }

  /// Each layer's entries, newest first.
  private *layers(): IterableIterator<Layer<V>> {
    yield this.own;
    for (let at = this.under; at; at = at.under) yield at.own;
  }

  /// This map with only the keys `keep` keeps; itself when it keeps them all (O(entries)).
  retain(keep: (key: string) => boolean): LayeredMap<V> {
    const drop = new Map<string, undefined>();
    for (const key of this.keys()) if (!keep(key)) drop.set(key, undefined);
    return drop.size ? this.with(drop) : this;
  }

  /// This map with `changes` over it (`undefined` deletes a key); itself when nothing changes.
  with(changes: ReadonlyMap<string, V | undefined>): LayeredMap<V> {
    let size = this.size;
    const own = new Map<string, V | undefined>();
    for (const [key, value] of changes) {
      const was = this.get(key);
      if (was === value) continue;
      if (was === undefined) size += 1;
      else if (value === undefined) size -= 1;
      own.set(key, value);
    }
    if (!own.size) return this;
    // Fold the layers under it that are no more than twice its size into it, oldest first under
    // the newer, so the newest value of each key wins.
    let under = this.under === undefined && this.own.size === 0 ? undefined : (this as LayeredMap<V>);
    let merged: Map<string, V | undefined> = own;
    while (under && under.own.size <= 2 * merged.size) {
      const next = new Map(under.own);
      for (const [key, value] of merged) next.set(key, value);
      merged = next;
      under = under.under;
    }
    // A bottom layer has nothing to delete under it.
    if (!under) for (const [key, value] of merged) if (value === undefined) merged.delete(key);
    return new LayeredMap(merged, under, size);
  }
}
