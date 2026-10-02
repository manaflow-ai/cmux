// OptMem-style memory: one append-only log of short lines, plus a cache of
// summaries over aligned ranges (#lo-hi). The log is the truth; summaries can
// always be rebuilt.
//
// Reused nearly verbatim from branch feat-mux (PR 16279),
// mux/packages/brain/src/memory.ts, which is pure and sound. Change: the
// CachedMemoryStore (a Durable Object cache in front of a primary) is dropped;
// the local host has one store (FileMemoryStore).

/** Longest log line, in UTF-8 bytes (OptMem's record size). */
export const MAX_LINE_BYTES = 280;

/** Where a mux's memory lives: DO SQLite, a git repo on a VM, a local repo. */
export interface MemoryStore {
  length(): Promise<number>;
  /** Appends lines; returns the new length. */
  append(lines: string[]): Promise<number>;
  /** Lines [start, end). */
  read(start: number, end: number): Promise<string[]>;
  /** Lines matching a regular expression, newest first. */
  recall(pattern: string, limit: number): Promise<{ index: number; line: string }[]>;
  getNodes(ranges: Range[]): Promise<Map<string, string>>;
  putNode(range: Range, summary: string): Promise<void>;
  deleteNode(range: Range): Promise<void>;
}

/** Inclusive range of log indices covered by a summary. Always aligned: size 2^k, lo % size === 0. */
export interface Range {
  lo: number;
  hi: number;
}

export const key = (r: Range) => `${r.lo}-${r.hi}`;
const size = (r: Range) => r.hi - r.lo + 1;
const level = (r: Range) => Math.log2(size(r));
const children = (r: Range): [Range, Range] => {
  const half = size(r) / 2;
  return [
    { lo: r.lo, hi: r.lo + half - 1 },
    { lo: r.lo + half, hi: r.hi },
  ];
};

/** Splits text into log lines of at most MAX_LINE_BYTES, on word boundaries where possible. */
export function toLines(text: string): string[] {
  const encoder = new TextEncoder();
  const flat = text.replace(/\s+/g, " ").trim();
  if (!flat) return [];
  const lines: string[] = [];
  let rest = flat;
  while (encoder.encode(rest).length > MAX_LINE_BYTES) {
    let cut = Math.min(rest.length, MAX_LINE_BYTES);
    // Leave room for the 3-byte "…" continuation mark.
    while (encoder.encode(rest.slice(0, cut)).length > MAX_LINE_BYTES - 3) cut--;
    const space = rest.lastIndexOf(" ", cut);
    if (space > cut / 2) cut = space;
    lines.push(`${rest.slice(0, cut).trimEnd()}…`);
    rest = rest.slice(cut).trimStart();
  }
  if (rest) lines.push(rest);
  return lines;
}

/** Older blocks first: the binary decomposition of [0, length). */
export function decompose(length: number): Range[] {
  const blocks: Range[] = [];
  let lo = 0;
  for (let bit = 2 ** Math.floor(Math.log2(Math.max(length, 1))); bit >= 1; bit /= 2) {
    if (length - lo >= bit) {
      blocks.push({ lo, hi: lo + bit - 1 });
      lo += bit;
    }
  }
  return blocks;
}

/**
 * The ranges wake shows: start from the decomposition, then split the newest
 * multi-line block while the view stays within `budget` entries.
 */
export function wakeCover(length: number, budget: number): Range[] {
  const cover = decompose(length);
  for (;;) {
    let index = -1;
    for (let i = cover.length - 1; i >= 0; i--) {
      if (size(cover[i]) > 1) {
        index = i;
        break;
      }
    }
    if (index < 0 || cover.length + 1 > budget) return cover;
    cover.splice(index, 1, ...children(cover[index]));
  }
}

export interface WakeView {
  text: string;
  /** Multi-line ranges in the cover with no summary yet: compaction work. */
  missing: Range[];
}

/**
 * Renders what the mux remembers within `budget` lines. A range without a
 * summary yet is shown through its children (down to raw lines), so nothing
 * is hidden while compaction catches up.
 */
export async function wake(store: MemoryStore, budget = 96): Promise<WakeView> {
  const length = await store.length();
  if (length === 0) return { text: "", missing: [] };
  const cover = wakeCover(length, budget);
  const multi = cover.filter((r) => size(r) > 1);
  const nodes = await store.getNodes(expandAll(multi));
  const missing = multi.filter((r) => !nodes.has(key(r)));
  const out: string[] = [];
  const render = async (r: Range): Promise<void> => {
    if (size(r) === 1) {
      const [line] = await store.read(r.lo, r.lo + 1);
      out.push(`#${r.lo} ${line}`);
      return;
    }
    const summary = nodes.get(key(r));
    if (summary) out.push(`#${key(r)} ${summary}`);
    else for (const child of children(r)) await render(child);
  };
  for (const r of cover) await render(r);
  return { text: out.join("\n"), missing };
}

/** Every aligned sub-range of the given ranges, for one batched node lookup. */
function expandAll(ranges: Range[]): Range[] {
  const all: Range[] = [];
  const visit = (r: Range) => {
    if (size(r) < 2) return;
    all.push(r);
    for (const c of children(r)) visit(c);
  };
  ranges.forEach(visit);
  return all;
}

/** What a summary is made of: its two child summaries, or the raw lines at the bottom. */
export async function zoom(store: MemoryStore, r: Range): Promise<string[]> {
  if (size(r) <= 2 || !Number.isInteger(level(r)) || r.lo % size(r) !== 0)
    return store.read(r.lo, r.hi + 1);
  const parts = children(r);
  const nodes = await store.getNodes(parts);
  const out: string[] = [];
  for (const part of parts) {
    const summary = nodes.get(key(part));
    if (summary) out.push(`#${key(part)} ${summary}`);
    else
      out.push(
        ...(await store.read(part.lo, part.hi + 1)).map((line, i) => `#${part.lo + i} ${line}`),
      );
  }
  return out;
}

export type Summarize = (input: { left: string; right: string; level: number }) => Promise<string>;

/**
 * Builds summaries for `targets`, children first. Each summary merges its two
 * children (raw lines at level 1). Returns how many summaries it wrote, at most
 * `limit` per call so one call stays short.
 */
export async function compact(
  store: MemoryStore,
  targets: Range[],
  summarize: Summarize,
  limit = 16,
): Promise<number> {
  let written = 0;
  const known = await store.getNodes(expandAll(targets));
  const build = async (r: Range): Promise<string | undefined> => {
    if (size(r) === 1) return (await store.read(r.lo, r.lo + 1))[0];
    const existing = known.get(key(r));
    if (existing) return existing;
    if (written >= limit) return undefined;
    const [a, b] = children(r);
    const left = await build(a);
    const right = await build(b);
    if (left === undefined || right === undefined || written >= limit) return undefined;
    const summary = clip(await summarize({ left, right, level: level(r) }));
    await store.putNode(r, summary);
    known.set(key(r), summary);
    written++;
    return summary;
  };
  for (const target of targets) await build(target);
  return written;
}

function clip(text: string): string {
  const [line = ""] = toLines(text);
  return line;
}

export const SUMMARY_INSTRUCTIONS = [
  "You compress an agent's memory. Merge the two entries into ONE line of at most 280 characters.",
  "Keep names, numbers, dates, paths, decisions, preferences, open tasks and outcomes; drop chatter.",
  "Write it as a dense note, no preamble.",
].join(" ");

/** In-memory store for tests and the local harness. */
export class ArrayMemoryStore implements MemoryStore {
  lines: string[] = [];
  nodes = new Map<string, string>();

  async length() {
    return this.lines.length;
  }
  async append(lines: string[]) {
    this.lines.push(...lines);
    return this.lines.length;
  }
  async read(start: number, end: number) {
    return this.lines.slice(start, end);
  }
  async recall(pattern: string, limit: number) {
    const re = new RegExp(pattern, "i");
    const hits: { index: number; line: string }[] = [];
    for (let i = this.lines.length - 1; i >= 0 && hits.length < limit; i--) {
      if (re.test(this.lines[i])) hits.push({ index: i, line: this.lines[i] });
    }
    return hits;
  }
  async getNodes(ranges: Range[]) {
    const found = new Map<string, string>();
    for (const r of ranges) {
      const value = this.nodes.get(key(r));
      if (value !== undefined) found.set(key(r), value);
    }
    return found;
  }
  async putNode(range: Range, summary: string) {
    this.nodes.set(key(range), summary);
  }
  async deleteNode(range: Range) {
    this.nodes.delete(key(range));
  }
}
