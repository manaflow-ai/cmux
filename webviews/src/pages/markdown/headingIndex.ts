// Indexes of what a document's top-level blocks hold (its headings, its anchor links), carried from
// each document to the next by the edit between them. What a block holds is read once per block
// node (a WeakMap), so an edit reads only the blocks it changed; the rest keep their entries, moved
// by the edit's size. Each entry has a key (a heading's id from its text) and an id its group of
// keys gives it (`-#2`, `-1` for a repeat): an edit gives ids again only to the groups whose keys it
// added or removed, and the groups related to them. A keystroke in a heading of a 10,000-line file
// walked every heading of it to give the ids again; now it reads that heading's block.
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { blocksAround, type BlockRange } from "./redecorate";

/** The whole top-level blocks that differ between `a` and `b` (in each), or null when they are equal. */
export function changedSpan(a: ProseNode, b: ProseNode): { before: BlockRange; after: BlockRange } | null {
  const start = a.content.findDiffStart(b.content);
  if (start === null) return null;
  let { a: endA, b: endB } = a.content.findDiffEnd(b.content)!;
  // A change in repeated text matches its end before its start (prosemirror-view's readDOMChange).
  const adjust = Math.max(0, start - Math.min(endA, endB));
  endA += adjust;
  endB += adjust;
  return { before: blocksAround(a, start, endA), after: blocksAround(b, start, endB) };
}

/** One thing a top-level block holds: `offset` from the block's start, its key and what it is. */
export type Found<T> = { offset: number; key: string; value: T };

/** One thing a document holds: where, its key, what it is, and the id its group gave it. */
export type Entry<T> = { pos: number; key: string; value: T; id: string };

export interface IndexScheme<T> {
  /** What a top-level block holds, in order. Read once per block node. */
  find(block: ProseNode): Found<T>[];
  /** The ids of entries with these keys, in document order (default: each its key). */
  ids?(keys: readonly string[]): string[];
  /**
   * The key whose ids this one's can meet (GitHub's: "a" repeated is "a-1", which is also the text
   * "a-1"), or null. Keys meet only their parent and children: those groups get ids together.
   */
  parent?(key: string): string | null;
}

/** What an edit changed in an index. */
export type IndexChange<T> = {
  /** The entries given ids again, in document order (the groups the edit touched and those related). */
  regrouped: readonly Entry<T>[];
  /** Ids the document had before and has no more, or has now and had not. */
  changedIds: ReadonlySet<string>;
};

type Snapshot<T> = {
  entries: Entry<T>[];
  groups: Map<string, Entry<T>[]>;
  /** The keys present, by `parent`. */
  children: Map<string, Set<string>>;
  /** Each id's entry, when the scheme's ids are unique (GitHub's are). */
  byId: Map<string, Entry<T>>;
};

/** The first index of `entries` (sorted by pos) at or after `pos`. */
function firstAt<T>(entries: readonly Entry<T>[], pos: number): number {
  let low = 0;
  let high = entries.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (entries[middle]!.pos < pos) low = middle + 1;
    else high = middle;
  }
  return low;
}

/**
 * An index per document. A document's index is carried to the next by `step` (it is the next
 * one's then; the one before is built again if asked for), so one view's edits update one index.
 */
export class BlockIndex<T> {
  private readonly perBlock = new WeakMap<ProseNode, readonly Found<T>[]>();
  private readonly perDoc = new WeakMap<ProseNode, Snapshot<T>>();

  constructor(private readonly scheme: IndexScheme<T>) {}

  /** Every entry of `doc`, in order. */
  entries(doc: ProseNode): readonly Entry<T>[] {
    return this.of(doc).entries;
  }

  /** The entries of `doc` with `key`, in order. */
  group(doc: ProseNode, key: string): readonly Entry<T>[] {
    return this.of(doc).groups.get(key) ?? [];
  }

  /** The entry of `doc` with `id` (for a scheme whose ids are unique). */
  byId(doc: ProseNode, id: string): Entry<T> | undefined {
    return this.of(doc).byId.get(id);
  }

  /**
   * Carries the index of `before` to `after`, an edit of it, reading only the blocks the edit
   * changed. Null when `before` had no index (or `after` had one already): `after`'s is built whole,
   * and any entry may have changed.
   */
  step(before: ProseNode, after: ProseNode): IndexChange<T> | null {
    if (before === after) return { regrouped: [], changedIds: new Set() };
    const snapshot = this.perDoc.get(before);
    if (!snapshot || this.perDoc.has(after)) {
      this.of(after);
      return null;
    }
    // Updated in place: it is `after`'s now.
    this.perDoc.delete(before);
    this.perDoc.set(after, snapshot);
    const span = changedSpan(before, after);
    if (!span) return { regrouped: [], changedIds: new Set() };
    const { entries } = snapshot;
    const low = firstAt(entries, span.before.from);
    const high = firstAt(entries, span.before.to);
    const delta = span.after.to - span.before.to;
    for (let index = high; index < entries.length; index++) entries[index]!.pos += delta;
    const added = this.read(after, span.after.from, span.after.to);
    const removed = entries.slice(low, high);
    // A spread of a whole document's entries (a reload) would overflow the call stack.
    if (added.length < 10_000) entries.splice(low, high - low, ...added);
    else snapshot.entries = [...entries.slice(0, low), ...added, ...entries.slice(high)];
    const touched = new Set<string>();
    for (const entry of removed) touched.add(entry.key);
    for (const entry of added) touched.add(entry.key);
    const gone = new Set(removed);
    for (const key of touched) {
      const kept = (snapshot.groups.get(key) ?? []).filter((entry) => !gone.has(entry));
      const group = [...kept, ...added.filter((entry) => entry.key === key)].sort((a, b) => a.pos - b.pos);
      this.setGroup(snapshot, key, group);
    }
    return this.regroup(snapshot, touched, removed, new Set(added));
  }

  private of(doc: ProseNode): Snapshot<T> {
    let snapshot = this.perDoc.get(doc);
    if (!snapshot) {
      snapshot = {
        entries: this.read(doc, 0, doc.content.size),
        groups: new Map(),
        children: new Map(),
        byId: new Map(),
      };
      for (const entry of snapshot.entries) {
        const group = snapshot.groups.get(entry.key);
        if (group) group.push(entry);
        else this.setGroup(snapshot, entry.key, [entry]);
      }
      this.regroup(snapshot, snapshot.groups.keys(), [], new Set(snapshot.entries));
      this.perDoc.set(doc, snapshot);
    }
    return snapshot;
  }

  /** The entries of the whole top-level blocks `from`..`to` of `doc`. */
  private read(doc: ProseNode, from: number, to: number): Entry<T>[] {
    const out: Entry<T>[] = [];
    let pos = from;
    for (let index = doc.resolve(from).index(0); pos < to && index < doc.childCount; index++) {
      const block = doc.child(index);
      let found = this.perBlock.get(block);
      if (!found) {
        found = this.scheme.find(block);
        this.perBlock.set(block, found);
      }
      for (const { offset, key, value } of found) out.push({ pos: pos + offset, key, value, id: key });
      pos += block.nodeSize;
    }
    return out;
  }

  private setGroup(snapshot: Snapshot<T>, key: string, group: Entry<T>[]): void {
    const had = snapshot.groups.has(key);
    if (group.length) snapshot.groups.set(key, group);
    else snapshot.groups.delete(key);
    const parent = this.scheme.parent?.(key) ?? null;
    if (parent === null || had === group.length > 0) return;
    let children = snapshot.children.get(parent);
    if (!children) snapshot.children.set(parent, (children = new Set()));
    if (group.length) children.add(key);
    else {
      children.delete(key);
      if (!children.size) snapshot.children.delete(parent);
    }
  }

  /** Gives ids again to the groups of `touched` and those related to them. */
  private regroup(
    snapshot: Snapshot<T>,
    touched: Iterable<string>,
    removed: readonly Entry<T>[],
    added: ReadonlySet<Entry<T>>,
  ): IndexChange<T> {
    const { ids, parent } = this.scheme;
    if (!ids) return { regrouped: [], changedIds: new Set() };
    const keys = new Set<string>();
    const queue = [...touched];
    while (queue.length) {
      const key = queue.pop()!;
      if (keys.has(key)) continue;
      keys.add(key);
      if (!parent) continue;
      const up = parent(key);
      if (up !== null && snapshot.groups.has(up)) queue.push(up);
      for (const child of snapshot.children.get(key) ?? []) queue.push(child);
    }
    const regrouped: Entry<T>[] = [];
    for (const key of keys) regrouped.push(...(snapshot.groups.get(key) ?? []));
    regrouped.sort((a, b) => a.pos - b.pos);
    const old = new Set(removed.map((entry) => entry.id));
    for (const entry of regrouped) if (!added.has(entry)) old.add(entry.id);
    for (const id of old) snapshot.byId.delete(id);
    const given = ids(regrouped.map((entry) => entry.key));
    const changedIds = new Set<string>();
    regrouped.forEach((entry, index) => {
      entry.id = given[index]!;
      if (!snapshot.byId.has(entry.id)) snapshot.byId.set(entry.id, entry);
      if (!old.delete(entry.id)) changedIds.add(entry.id);
    });
    for (const id of old) changedIds.add(id);
    return { regrouped, changedIds };
  }
}

/**
 * The headings a top-level block holds (`block` itself, or in a quote or list), each keyed by `key`
 * (null: no entry). Paragraphs and code blocks are not walked into.
 */
export function headingsIn(
  block: ProseNode,
  isHeading: (node: ProseNode) => boolean,
  key: (heading: ProseNode) => string | null,
): Found<ProseNode>[] {
  const out: Found<ProseNode>[] = [];
  const visit = (node: ProseNode, offset: number) => {
    if (!isHeading(node)) return !node.isTextblock;
    const found = key(node);
    if (found !== null) out.push({ offset, key: found, value: node });
    return false;
  };
  if (visit(block, 0)) block.descendants((node, pos) => visit(node, pos + 1));
  return out;
}
