// A persistent sequence of rows: frozen chunks of `ROW_SEQ_CHUNK` rows under a spine. A new
// sequence that writes one row, or appends at the end, copies that one chunk and the spine
// (about n / 1,024 slots), never every row: the client's snapshot array (`OrderedRows.sorted`)
// copied all of them on each streamed chunk, 7.9 ms at 150k held rows (RFD 0191, hq).
//
// Published beside each snapshot's `rows` (`rowSeqOf`), not on the snapshot object: snapshots are
// spread and cloned in hundreds of places, and a field there would be copied or serialized with them.
// Readers move to it one at a time (RFD 0191 stages 3-5); until then `rows` stays the array it was.

/// Rows per chunk.
export const ROW_SEQ_CHUNK = 1024;

/// Chunks are typed readonly and never written once made. Object.freeze would also enforce that at
/// run time, but in JavaScriptCore a frozen array leaves the fast element path: a one-chunk write cost
/// 0.084 ms frozen against 0.0006 ms not, and a read of every row 20x more (bun, 150k rows). So only
/// tests freeze (`freezeRowSeqChunks`), where a stray write throws.
let freezing = false;

/// Tests: freeze every chunk and spine made from now on (returns the old setting).
export function freezeRowSeqChunks(on: boolean): boolean {
  const was = freezing;
  freezing = on;
  return was;
}

function sealed<T>(items: T[]): readonly T[] {
  return freezing ? Object.freeze(items) : items;
}

export class RowSeq<T> implements Iterable<T> {
  private constructor(
    /// Every chunk is full but the last, never written once made, and shared with the sequences it came from.
    readonly chunks: readonly (readonly T[])[],
    readonly length: number,
  ) {}

  static readonly EMPTY: RowSeq<never> = new RowSeq<never>([], 0);

  /// A sequence of `items` (copied: O(n), once).
  static from<T>(items: readonly T[]): RowSeq<T> {
    return (RowSeq.EMPTY as RowSeq<T>).withTail(0, items);
  }

  /// The row at `index` (undefined past the end).
  at(index: number): T | undefined {
    if (index < 0 || index >= this.length) return undefined;
    return this.chunks[Math.floor(index / ROW_SEQ_CHUNK)]![index % ROW_SEQ_CHUNK];
  }

  /// This sequence with `row` at `index` (0 <= index < length): one chunk and the spine copied.
  with(index: number, row: T): RowSeq<T> {
    if (index < 0 || index >= this.length) throw new RangeError(`RowSeq.with(${index}) of ${this.length}`);
    const at = Math.floor(index / ROW_SEQ_CHUNK);
    const chunk = this.chunks[at]!.slice();
    chunk[index % ROW_SEQ_CHUNK] = row;
    const chunks = this.chunks.slice();
    chunks[at] = sealed(chunk);
    return new RowSeq(sealed(chunks), this.length);
  }

  /// The sequence `source` (the whole new order), given that its rows before `from` are this one's,
  /// the same at the same places: the chunks wholly before `from` are kept, the rest made from
  /// `source`. An append (`from` = the old length) copies the last chunk and the new rows; a drop or
  /// move copies from its chunk on. `from` may be less than the true kept prefix, never more.
  withTail(from: number, source: readonly T[]): RowSeq<T> {
    const keep = Math.floor(Math.max(0, Math.min(from, this.length, source.length)) / ROW_SEQ_CHUNK);
    const chunks = this.chunks.slice(0, keep);
    for (let start = keep * ROW_SEQ_CHUNK; start < source.length; start += ROW_SEQ_CHUNK)
      chunks.push(sealed(source.slice(start, start + ROW_SEQ_CHUNK)));
    return new RowSeq(sealed(chunks), source.length);
  }

  *[Symbol.iterator](): Iterator<T> {
    for (const chunk of this.chunks) yield* chunk;
  }

  /// The rows as one array (O(n): what readers that have not moved to the sequence still pay).
  toArray(): T[] {
    const out: T[] = [];
    for (const chunk of this.chunks) for (const row of chunk) out.push(row);
    return out;
  }
}

/// How many leading rows of `next` are the same objects at the same places in `previous`: shared
/// chunks are skipped by identity, and rows walked only in chunks that are not shared, so a write
/// near the end costs O(n / 1,024 + 1,024).
export function rowSeqKeptPrefix<T>(previous: RowSeq<T>, next: RowSeq<T>): number {
  const limit = Math.min(previous.length, next.length);
  for (let chunk = 0, index = 0; index < limit; chunk += 1, index += ROW_SEQ_CHUNK) {
    const a = previous.chunks[chunk]!;
    const b = next.chunks[chunk]!;
    if (a === b) continue;
    const end = Math.min(ROW_SEQ_CHUNK, limit - index);
    for (let offset = 0; offset < end; offset += 1) if (a[offset] !== b[offset]) return index + offset;
  }
  return limit;
}

const published = new WeakMap<readonly unknown[], RowSeq<unknown>>();

/// Says `seq` holds the same rows as the snapshot array `rows` (`OrderedRows.sorted`).
export function publishRowSeq<T>(rows: readonly T[], seq: RowSeq<T>): void {
  published.set(rows, seq as RowSeq<unknown>);
}

/// The sequence published beside snapshot `rows`, if its maker kept one.
export function rowSeqOf<T>(rows: readonly T[]): RowSeq<T> | undefined {
  return published.get(rows) as RowSeq<T> | undefined;
}
