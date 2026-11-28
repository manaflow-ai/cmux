/// One background turn's span of the log: an event at `order` with `from < order < to` is the turn's (`to` undefined: no
/// end heard yet, so every later event is).
export type BackgroundSpan = { id: string; from: number; to?: number };

/// The background turn an event at `order` belongs to, by a walk of every span: the newest-heard span holding it wins.
/// What `OrderedRows` asked per row write before `BackgroundSpans`, kept as its oracle (test/ordered-rows-background-spans.test.ts).
export function backgroundAtLinear(spans: readonly BackgroundSpan[], order: number): string | undefined {
  for (let at = spans.length - 1; at >= 0; at -= 1) {
    const span = spans[at]!;
    if (span.from < order && (span.to === undefined || order < span.to)) return span.id;
  }
  return undefined;
}

type Entry = { span: BackgroundSpan; rank: number };

/// The background spans of one chat, in the order they were heard, with an index that answers `at(order)` (asked on
/// every row write of a chat that has any) in O(log spans + the spans holding `order`) instead of a walk of all of them:
/// 1.6 us a write at 1k spans, 17 us at 10k, before. The closed spans sit sorted by `from` with a running maximum of
/// their ends, so a lookup binary-searches the last span starting before `order` and walks back only while some span
/// at or before it still ends past `order`. Open spans (no end yet) are few: a prompt ends every one before it.
/// A span's end only ever moves earlier once set (`close`), so the running maximum stays an upper bound and is never
/// redone for it; a span heard out of order (an older page) is inserted at its place.
export class BackgroundSpans {
  /// In the order heard (`rank` is the index here at insertion, kept through `retain`'s filter).
  private heard: Entry[] = [];
  private nextRank = 0;
  private open: Entry[] = [];
  private closed: Entry[] = [];
  /// maxTo[i]: the latest end among closed[0..i].
  private maxTo: number[] = [];
  private readonly byId = new Map<string, Entry>();

  get size(): number {
    return this.heard.length;
  }

  /// The spans in the order they were heard.
  spans(): BackgroundSpan[] {
    return this.heard.map((entry) => entry.span);
  }

  get(id: string): BackgroundSpan | undefined {
    return this.byId.get(id)?.span;
  }

  /// A span heard; one with an `id` already held is ignored (its started record heard again).
  add(span: BackgroundSpan): void {
    if (this.byId.has(span.id)) return;
    const entry = { span, rank: this.nextRank++ };
    this.heard.push(entry);
    this.byId.set(span.id, entry);
    if (span.to === undefined) this.open.push(entry);
    else this.insertClosed(entry);
  }

  /// The span `id` ends at `seq`, or earlier if it already ended earlier.
  close(id: string, seq: number): void {
    const entry = this.byId.get(id);
    if (!entry) return;
    const { span } = entry;
    if (span.to !== undefined) {
      span.to = Math.min(span.to, seq);
      return;
    }
    span.to = seq;
    this.open.splice(this.open.indexOf(entry), 1);
    this.insertClosed(entry);
  }

  /// The ids of the spans still open that start before `seq`, in the order heard.
  openBefore(seq: number): string[] {
    return this.open.filter((entry) => entry.span.from < seq).map((entry) => entry.span.id);
  }

  /// The background turn an event at `order` belongs to: the newest-heard span holding it (as `backgroundAtLinear`).
  at(order: number): string | undefined {
    let best: Entry | undefined;
    for (const entry of this.open) if (entry.span.from < order && (!best || entry.rank > best.rank)) best = entry;
    // The last closed span starting before `order`.
    let low = 0;
    let high = this.closed.length;
    while (low < high) {
      const mid = (low + high) >>> 1;
      if (this.closed[mid]!.span.from < order) low = mid + 1;
      else high = mid;
    }
    for (let i = low - 1; i >= 0 && this.maxTo[i]! > order; i -= 1) {
      const entry = this.closed[i]!;
      if (order < entry.span.to! && (!best || entry.rank > best.rank)) best = entry;
    }
    return best?.span.id;
  }

  /// Keeps the spans `keep` says to (in the order heard) and indexes them again.
  retain(keep: (span: BackgroundSpan) => boolean): void {
    const kept = this.heard.filter((entry) => keep(entry.span));
    if (kept.length === this.heard.length) return;
    this.heard = kept;
    this.byId.clear();
    for (const entry of kept) this.byId.set(entry.span.id, entry);
    this.open = kept.filter((entry) => entry.span.to === undefined);
    this.closed = kept.filter((entry) => entry.span.to !== undefined).sort((a, b) => a.span.from - b.span.from);
    this.maxTo = [];
    this.runningMaxFrom(0);
  }

  clear(): void {
    this.heard = [];
    this.open = [];
    this.closed = [];
    this.maxTo = [];
    this.byId.clear();
  }

  private insertClosed(entry: Entry): void {
    const from = entry.span.from;
    const last = this.closed.length - 1;
    if (last < 0 || this.closed[last]!.span.from <= from) {
      this.closed.push(entry);
      this.maxTo.push(Math.max(last < 0 ? -Infinity : this.maxTo[last]!, entry.span.to!));
      return;
    }
    // Out of order (an older page's span): after every span starting at or before it.
    let low = 0;
    let high = this.closed.length;
    while (low < high) {
      const mid = (low + high) >>> 1;
      if (this.closed[mid]!.span.from <= from) low = mid + 1;
      else high = mid;
    }
    this.closed.splice(low, 0, entry);
    this.maxTo.length = low;
    this.runningMaxFrom(low);
  }

  private runningMaxFrom(start: number): void {
    let max = start > 0 ? this.maxTo[start - 1]! : -Infinity;
    for (let i = start; i < this.closed.length; i++) {
      max = Math.max(max, this.closed[i]!.span.to!);
      this.maxTo[i] = max;
    }
  }
}
