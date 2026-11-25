/**
 * Where a memory lives. Synchronous on purpose: Durable Object SQLite is
 * synchronous, and one memory has one writer (the object), so the reference's
 * file lock is not needed.
 */

export interface Entry {
  readonly n: number;
  readonly date: string;
  readonly text: string;
}

export type Knob = "WAKE_LINES" | "ENTRY_CHARS" | "PART_CHARS" | "PART_LINES";

export interface MemoryStorage {
  /** Number of entries (T). */
  length(): number;
  /** Entries [lo, hi), in order. */
  entries(lo: number, hi: number): Array<Entry>;
  /** Every entry, oldest first, streamed. */
  scan(): Iterable<Entry>;
  /** Appends in order and returns the first id used. */
  append(items: ReadonlyArray<{ readonly date: string; readonly text: string }>): number;
  /** Size of the dense prefix of built blocks at this level. */
  built(size: number): number;
  /** Summary of block k at this level, or undefined. Only meaningful for k < built(size). */
  node(size: number, k: number): string | undefined;
  /** Writes block k at this level and makes the prefix k + 1 long. Callers pass k === built(size). */
  putNode(size: number, k: number, text: string): void;
  /** Shrinks the level's prefix to k (rows past it are dead until rebuilt). */
  truncate(size: number, k: number): void;
  /** Knobs this memory sets for itself; the rest follow the defaults. */
  overrides(): Partial<Record<Knob, number>>;
  setOverrides(over: Partial<Record<Knob, number>>): void;
}

/** In-memory storage for tests and the conformance replay. */
export class ArrayStorage implements MemoryStorage {
  private readonly log: Array<Entry> = [];
  private readonly levels = new Map<number, Array<string>>();
  private over: Partial<Record<Knob, number>> = {};

  length() {
    return this.log.length;
  }

  entries(lo: number, hi: number) {
    return this.log.slice(lo, hi);
  }

  scan() {
    return this.log;
  }

  append(items: ReadonlyArray<{ readonly date: string; readonly text: string }>) {
    const base = this.log.length;
    items.forEach((e, i) => this.log.push({ n: base + i, date: e.date, text: e.text }));
    return base;
  }

  built(size: number) {
    return this.levels.get(size)?.length ?? 0;
  }

  node(size: number, k: number) {
    return this.levels.get(size)?.[k];
  }

  putNode(size: number, k: number, text: string) {
    const level = this.levels.get(size) ?? [];
    if (k !== level.length) throw new Error(`level ${size} has ${level.length} blocks, cannot write block ${k}`);
    level.push(text);
    this.levels.set(size, level);
  }

  truncate(size: number, k: number) {
    const level = this.levels.get(size);
    if (level && level.length > k) level.length = k;
  }

  overrides() {
    return { ...this.over };
  }

  setOverrides(over: Partial<Record<Knob, number>>) {
    this.over = { ...over };
  }
}
