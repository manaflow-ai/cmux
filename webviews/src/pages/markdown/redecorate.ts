// The decoration plugins redraw only the top-level blocks a change touched. A reload of a file
// appended to replaces its last blocks; redrawing every block of a 1 MB file on each took 250 ms
// (bench/markdown-viewer-stress.bench.ts, reload-1m), most of it building the decoration set again.
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import type { Transaction } from "@milkdown/kit/prose/state";
import { type Decoration, DecorationSet } from "@milkdown/kit/prose/view";

/** A range of whole top-level blocks of a document: from the start of one to the end of another. */
export type BlockRange = { from: number; to: number };

/**
 * The most top-level blocks one set is built over. prosemirror-view's `DecorationSet.create` and
 * `add` check each decoration given against each top-level node of the document they are given
 * (`takeSpansForNode`), so one call over a 1 MB file was quadratic; a call per chunk, over only
 * the chunk's blocks (`chunkOf`), is linear.
 */
const CHUNK_BLOCKS = 64;

/** The whole top-level blocks of `doc` that `from`..`to` touches. */
export function blocksAround(doc: ProseNode, from: number, to: number): BlockRange {
  const size = doc.content.size;
  const start = doc.resolve(Math.max(0, Math.min(from, size)));
  const end = doc.resolve(Math.max(0, Math.min(to, size)));
  return {
    from: start.depth ? start.before(1) : start.pos,
    to: end.depth ? end.after(1) : end.pos,
  };
}

/**
 * The meta of a transaction that puts one slice of a long file in (MarkdownEditor.loadInSlices):
 * "part" for each before the last, which draws nothing, and "last", which draws the whole document.
 * prosemirror-view finds a top-level node's decorations with a scan from the first decorated node
 * (`forChild`), so each slice's view update costs the square of the decorated blocks: a 1 MB file
 * drawn slice by slice loaded in 7.8 s, drawn once at the end in 5.5 s.
 */
export const SLICE_META = "cmuxMarkdownSlice";

/** The top-level blocks of `tr.doc` that `tr`'s steps changed, in order and merged. */
export function changedBlocks(tr: Transaction): BlockRange[] {
  const slice = tr.getMeta(SLICE_META) as "part" | "last" | undefined;
  if (slice === "part") return [];
  if (slice === "last") return [{ from: 0, to: tr.doc.content.size }];
  const ranges: BlockRange[] = [];
  tr.mapping.maps.forEach((map, index) => {
    const rest = tr.mapping.slice(index + 1);
    map.forEach((_oldFrom, _oldTo, from, to) => {
      ranges.push(blocksAround(tr.doc, rest.map(from, -1), rest.map(to, 1)));
    });
  });
  return mergeRanges(ranges);
}

/** `ranges` sorted, with the ones that overlap or touch made one. */
export function mergeRanges(ranges: readonly BlockRange[]): BlockRange[] {
  const sorted = [...ranges].sort((a, b) => a.from - b.from);
  const merged: BlockRange[] = [];
  for (const range of sorted) {
    const last = merged[merged.length - 1];
    if (last && range.from <= last.to) last.to = Math.max(last.to, range.to);
    else merged.push({ ...range });
  }
  return merged;
}

/**
 * `doc` as `DecorationSet.create` and `add` see it: only its top-level blocks `first` to before
 * `end`, the first at `offset`. Every other property is the document's own, so a set built over it
 * is a set of `doc`, given decorations only in those blocks.
 */
function chunkOf(doc: ProseNode, first: number, end: number, offset: number): ProseNode {
  const chunk = Object.create(doc) as ProseNode;
  chunk.forEach = (visit) => {
    let at = offset;
    for (let index = first; index < end; index++) {
      const child = doc.child(index);
      visit(child, at, index);
      at += child.nodeSize;
    }
  };
  return chunk;
}

/** `set` with the decorations `decorate` draws for the whole blocks `from`..`to` of `doc` added, a chunk at a time (a few blocks a change). */
function addDrawn(
  set: DecorationSet,
  doc: ProseNode,
  from: number,
  to: number,
  decorate: (from: number, to: number) => Decoration[],
): DecorationSet {
  let index = doc.resolve(from).index(0);
  let start = from;
  while (start < to && index < doc.childCount) {
    const first = index;
    let end = start;
    while (end < to && index < doc.childCount && index - first < CHUNK_BLOCKS) end += doc.child(index++).nodeSize;
    const drawn = decorate(start, end);
    if (drawn.length) set = set.add(chunkOf(doc, first, index, start), drawn);
    start = end;
  }
  return set;
}

/** A set's own decorations and its children (start, end, set; three entries each): prosemirror-view's own fields. */
type SetParts = { local: readonly Decoration[]; children: readonly unknown[] };
/** prosemirror-view's constructor (internal): a set from its own decorations and its children. */
const SetOf = DecorationSet as unknown as new (local: Decoration[], children: unknown[]) => DecorationSet;

/**
 * The decorations `decorate` draws for all of `doc`. Each chunk's set is built over only its
 * blocks, and the chunks' parts are joined into one set: `add` copies the set's children each
 * time, so adding chunk by chunk to a 10 MB file's set was quadratic too (a 5.5 s task).
 */
export function decorateAll(doc: ProseNode, decorate: (from: number, to: number) => Decoration[]): DecorationSet {
  const local: Decoration[] = [];
  const children: unknown[] = [];
  let start = 0;
  for (let index = 0; index < doc.childCount;) {
    const first = index;
    let end = start;
    while (index < doc.childCount && index - first < CHUNK_BLOCKS) end += doc.child(index++).nodeSize;
    const drawn = decorate(start, end);
    if (drawn.length) {
      // Built over the chunk, a set's positions are the document's: its parts join in order.
      const parts = DecorationSet.create(chunkOf(doc, first, index, start), drawn) as unknown as SetParts;
      local.push(...parts.local);
      children.push(...parts.children);
    }
    start = end;
  }
  return local.length || children.length ? new SetOf(local, children) : DecorationSet.empty;
}

/**
 * `previous` mapped through `tr`, with the decorations of the blocks in `ranges` drawn again by
 * `decorate` (which draws the blocks between two positions). When the ranges are most of the
 * document, all of it is drawn again: `remove` also checks each decoration against each block.
 */
export function redecorate(
  previous: DecorationSet,
  tr: Transaction,
  ranges: readonly BlockRange[],
  decorate: (from: number, to: number) => Decoration[],
): DecorationSet {
  const doc = tr.doc;
  let covered = 0;
  for (const range of ranges) covered += range.to - range.from;
  if (covered * 2 > doc.content.size) return decorateAll(doc, decorate);
  let set = previous.map(tr.mapping, doc);
  for (const { from, to } of ranges) {
    // A block's decorations start in it; the next block's may start where this one ends.
    const stale = set.find(from, to).filter((decoration) => decoration.from >= from && decoration.from < to);
    set = addDrawn(set.remove(stale), doc, from, to, decorate);
  }
  return set;
}
