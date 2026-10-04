// The save path of the markdown editor: a minimal-change write. A WYSIWYG editor that serializes
// its whole document rewrites the user's file (Milkdown's serializer left 2 of the 35 files of
// test/fixtures/markdown-roundtrip byte-identical with no edit; escaping, list spacing, table
// padding, front matter and reference definitions all change). So the editor keeps, for every
// top-level block, the exact source text it was parsed from, and a save writes that text back for
// every block the user did not change. Only edited or new blocks go through the serializer, and the
// gaps between kept blocks (blank lines, trailing newline) stay as they were.
//
// Parsing: the source is split into top-level blocks with remark's positions (the same remark
// Milkdown uses, before its transforms). Each block is transformed and parsed on its own, so the
// block -> ProseMirror nodes map is exact. Text no block covers (front matter, a reference
// definition, anything the parser has no node for) becomes a `cmux_raw` block holding it verbatim,
// so nothing in the file is invisible in the editor or lost on save.
import type { Node as ProseNode, Schema } from "@milkdown/kit/prose/model";

/** A remark processor as Milkdown's `remarkCtx` holds it. */
export interface RemarkLike {
  parse(text: string): MdastRoot;
  runSync(tree: MdastRoot, file?: string): MdastRoot;
}

export interface MdastNode {
  type: string;
  children?: MdastNode[];
  value?: string;
  position?: { start: { offset?: number }; end: { offset?: number } };
  [key: string]: unknown;
}

export interface MdastRoot extends MdastNode {
  type: "root";
  children: MdastNode[];
}

/** Builds ProseMirror nodes from a transformed mdast root (Milkdown's ParserState). */
export type BuildNodes = (root: MdastRoot) => readonly ProseNode[];

/** Serializes top-level nodes to markdown (Milkdown's serializer, on a doc of these nodes). */
export type SerializeNodes = (nodes: readonly ProseNode[]) => string;

/** The `cmux_raw` block kinds: front matter, a reference definition, an HTML block, other source. */
export type RawKind = "frontmatter" | "definition" | "html" | "source";

export const RAW_NODE = "cmux_raw";

/** One top-level block of the source: its text range and the nodes it parsed to. */
export interface SourceBlock {
  start: number;
  end: number;
  nodes: readonly ProseNode[];
}

/** A parsed source: the blocks in order and the text around them. */
export interface SourceMap {
  text: string;
  blocks: readonly SourceBlock[];
}

const FRONT_MATTER = /^(---|\+\+\+)[ \t]*\r?\n([\s\S]*?\r?\n)?\1[ \t]*(?:\r?\n|$)/;

/** The front matter at the start of `text` (YAML `---` or TOML `+++`), as its full source length. */
export function frontMatterLength(text: string): number {
  const match = FRONT_MATTER.exec(text.startsWith("﻿") ? text.slice(1) : text);
  if (!match) return 0;
  return match[0].length + (text.startsWith("﻿") ? 1 : 0);
}

/** The editable text of a front matter block (between the fences) and its fence. */
export function splitFrontMatter(source: string): { fence: string; body: string } {
  const text = source.replace(/^﻿/, "");
  const fence = text.startsWith("+++") ? "+++" : "---";
  const firstBreak = text.indexOf("\n");
  const close = text.lastIndexOf(fence);
  const body = firstBreak >= 0 && close > firstBreak ? text.slice(firstBreak + 1, close) : "";
  return { fence, body: body.replace(/\r?\n$/, "") };
}

function offsetOf(node: MdastNode, which: "start" | "end"): number | undefined {
  const offset = node.position?.[which]?.offset;
  return typeof offset === "number" ? offset : undefined;
}

function rawKindOf(source: string): RawKind {
  if (/^\[[^\]]+\]:\s/.test(source.trim())) return "definition";
  if (source.trim().startsWith("<")) return "html";
  return "source";
}

/**
 * Splits `text` into blocks: front matter, then remark's top-level nodes, with any uncovered
 * non-whitespace text as raw blocks. HTML blocks and definitions are raw blocks too (Milkdown has
 * no block node for either: it wraps HTML in a paragraph and inlines reference links).
 */
export function parseSourceMap(
  text: string,
  remark: RemarkLike,
  build: BuildNodes,
  raw: (kind: RawKind, value: string) => ProseNode,
): SourceMap {
  const blocks: SourceBlock[] = [];
  const fmLength = frontMatterLength(text);
  if (fmLength > 0) {
    const source = text.slice(0, fmLength).replace(/\r?\n$/, "");
    blocks.push({ start: 0, end: source.length, nodes: [raw("frontmatter", splitFrontMatter(source).body)] });
  }
  // The front matter becomes blank (same length, same line breaks) so positions stay absolute.
  const body = fmLength > 0 ? text.slice(0, fmLength).replace(/[^\r\n]/g, " ") + text.slice(fmLength) : text;
  const tree = remark.parse(body);
  const definitions = tree.children.filter((child) => child.type === "definition");
  let cursor = fmLength > 0 ? blocks[0].end : 0;

  const pushRawGap = (from: number, to: number) => {
    const gap = text.slice(from, to);
    const lead = gap.length - gap.trimStart().length;
    const trimmed = gap.trim();
    if (!trimmed) return;
    const start = from + lead;
    const end = start + trimmed.length;
    blocks.push({ start, end, nodes: [raw(rawKindOf(trimmed), trimmed)] });
  };

  for (const child of tree.children) {
    const start = offsetOf(child, "start");
    const end = offsetOf(child, "end");
    if (start === undefined || end === undefined || start < cursor) continue;
    pushRawGap(cursor, start);
    const source = text.slice(start, end);
    let nodes: readonly ProseNode[];
    if (child.type === "definition") {
      nodes = [raw("definition", source)];
    } else if (child.type === "html") {
      nodes = [raw("html", source)];
    } else {
      // Transformed alone. Reference links resolve here, keeping their reference (an edited
      // paragraph writes `[text][ref]` again, not the inline form).
      const root: MdastRoot = { type: "root", children: [resolveReferences(child, definitions)] };
      let built: readonly ProseNode[] = [];
      try {
        built = build(remark.runSync(root, body));
      } catch {
        built = [];
      }
      nodes = built.length > 0 ? built : [raw("source", source)];
    }
    blocks.push({ start, end, nodes });
    cursor = end;
  }
  pushRawGap(cursor, text.length);
  return { text, blocks };
}

/** What a resolved reference link or image keeps of its reference, on `data.cmuxReference`. */
export interface ReferenceInfo {
  identifier: string;
  label: string;
  referenceType: string;
}

/**
 * `node` with every `linkReference` and `imageReference` that has a definition turned into a link
 * or image, the reference kept on `data.cmuxReference`, so the editor shows the target and the
 * serializer can write the reference back.
 */
export function resolveReferences(node: MdastNode, definitions: readonly MdastNode[]): MdastNode {
  const byId = new Map<string, MdastNode>();
  for (const definition of definitions) {
    const id = String(definition.identifier ?? "");
    if (id && !byId.has(id)) byId.set(id, definition);
  }
  const visit = (current: MdastNode): MdastNode => {
    if (current.type === "linkReference" || current.type === "imageReference") {
      const definition = byId.get(String(current.identifier ?? ""));
      if (definition) {
        const reference: ReferenceInfo = {
          identifier: String(current.identifier ?? ""),
          label: String(current.label ?? current.identifier ?? ""),
          referenceType: String(current.referenceType ?? "full"),
        };
        const base = {
          url: definition.url,
          title: definition.title ?? null,
          position: current.position,
          data: { cmuxReference: reference },
        };
        if (current.type === "imageReference") return { type: "image", alt: current.alt, ...base };
        return { type: "link", ...base, children: (current.children ?? []).map(visit) };
      }
    }
    if (!current.children) return current;
    return { ...current, children: current.children.map(visit) };
  };
  return visit(node);
}

/** All nodes of a source map, in order: the document's top-level content. */
export function sourceMapNodes(map: SourceMap): ProseNode[] {
  return map.blocks.flatMap((block) => block.nodes);
}

/** Attributes the editor recomputes from content (heading anchors); never a user edit. */
const DERIVED_ATTRS = new Set(["id"]);

/** Two nodes are the same block when type, marks, attrs (but derived ones) and content match. */
export function sameBlock(a: ProseNode, b: ProseNode): boolean {
  if (a === b) return true;
  if (a.type !== b.type || a.isText !== b.isText) return false;
  if (a.isText) return a.text === b.text && sameMarks(a, b);
  if (!sameMarks(a, b)) return false;
  for (const key of new Set([...Object.keys(a.attrs), ...Object.keys(b.attrs)])) {
    if (DERIVED_ATTRS.has(key)) continue;
    if (JSON.stringify(a.attrs[key]) !== JSON.stringify(b.attrs[key])) return false;
  }
  if (a.childCount !== b.childCount) return false;
  for (let index = 0; index < a.childCount; index++) {
    if (!sameBlock(a.child(index), b.child(index))) return false;
  }
  return true;
}

function sameMarks(a: ProseNode, b: ProseNode): boolean {
  if (a.marks.length !== b.marks.length) return false;
  return a.marks.every((mark, index) => mark.eq(b.marks[index]));
}

/**
 * Matches baseline nodes to current nodes in order (longest common subsequence by `sameBlock`,
 * after the common prefix and suffix). Returns, for each current node, the baseline index it
 * matches, or -1.
 */
export function alignNodes(baseline: readonly ProseNode[], current: readonly ProseNode[]): number[] {
  const match = Array.from({ length: current.length }, () => -1);
  let prefix = 0;
  while (prefix < baseline.length && prefix < current.length && sameBlock(baseline[prefix], current[prefix])) {
    match[prefix] = prefix;
    prefix++;
  }
  let suffix = 0;
  while (
    suffix < baseline.length - prefix &&
    suffix < current.length - prefix &&
    sameBlock(baseline[baseline.length - 1 - suffix], current[current.length - 1 - suffix])
  ) {
    match[current.length - 1 - suffix] = baseline.length - 1 - suffix;
    suffix++;
  }
  const b = baseline.slice(prefix, baseline.length - suffix);
  const c = current.slice(prefix, current.length - suffix);
  if (b.length === 0 || c.length === 0) return match;
  // LCS table over the middle. Middles are small (the edits since the last save).
  const rows = b.length + 1;
  const cols = c.length + 1;
  const table = new Uint32Array(rows * cols);
  for (let i = b.length - 1; i >= 0; i--) {
    for (let j = c.length - 1; j >= 0; j--) {
      table[i * cols + j] = sameBlock(b[i], c[j])
        ? table[(i + 1) * cols + j + 1] + 1
        : Math.max(table[(i + 1) * cols + j], table[i * cols + j + 1]);
    }
  }
  let i = 0;
  let j = 0;
  while (i < b.length && j < c.length) {
    if (sameBlock(b[i], c[j]) && table[i * cols + j] === table[(i + 1) * cols + j + 1] + 1) {
      match[prefix + j] = prefix + i;
      i++;
      j++;
    } else if (table[(i + 1) * cols + j] >= table[i * cols + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return match;
}

const hasBlankLine = (gap: string) => /\n[ \t]*\r?\n/.test(gap);
/** A separator next to a re-serialized block: the original gap when it is a blank line, else one. */
const blockGap = (gap: string | undefined) => (gap !== undefined && hasBlankLine(gap) ? gap : "\n\n");

/**
 * The markdown for `current` (the editor's top-level nodes): the original source of every block
 * that is unchanged, `serialize` for the rest. With no edit its text is `map.text` exactly. The
 * result is also the source map of that text, the baseline for the next save.
 */
export function serializeWithSourceMap(
  map: SourceMap,
  current: readonly ProseNode[],
  serialize: SerializeNodes,
): SourceMap {
  const baseline: ProseNode[] = [];
  const blockOf: number[] = [];
  map.blocks.forEach((block, index) => {
    for (const node of block.nodes) {
      baseline.push(node);
      blockOf.push(index);
    }
  });
  const match = alignNodes(baseline, current);
  // A block is intact when all its nodes appear, in order and adjacent, in the current document.
  const firstNode: number[] = [];
  let offset = 0;
  for (const block of map.blocks) {
    firstNode.push(offset);
    offset += block.nodes.length;
  }
  const intactAt = new Map<number, number>();
  map.blocks.forEach((block, index) => {
    const first = firstNode[index];
    const at = match.indexOf(first);
    if (at < 0) return;
    for (let k = 1; k < block.nodes.length; k++) if (match[at + k] !== first + k) return;
    intactAt.set(at, index);
  });

  const gapBefore = (index: number) =>
    map.text.slice(index === 0 ? 0 : map.blocks[index - 1].end, map.blocks[index]?.start ?? map.text.length);
  const tail = map.blocks.length ? map.text.slice(map.blocks[map.blocks.length - 1].end) : map.text;

  type Piece = { kind: "block"; index: number } | { kind: "run"; text: string; after: number; nodes: ProseNode[] };
  const pieces: Piece[] = [];
  let lastBlock = -1;
  for (let j = 0; j < current.length;) {
    const index = intactAt.get(j);
    if (index !== undefined) {
      pieces.push({ kind: "block", index });
      lastBlock = index;
      j += map.blocks[index].nodes.length;
      continue;
    }
    const run: ProseNode[] = [];
    while (j < current.length && !intactAt.has(j)) run.push(current[j++]);
    const text = serialize(run).replace(/\s+$/, "");
    if (text) pieces.push({ kind: "run", text, after: lastBlock, nodes: run });
  }

  if (pieces.length === 0) return { text: map.blocks.length === 0 ? map.text : "", blocks: [] };
  // The result is the next baseline: kept blocks keep their nodes, a serialized run is one block.
  const blocks: SourceBlock[] = [];
  // Leading text before the first block is whitespace or a byte order mark, and the tail after the
  // last block is whitespace (any other text is a raw block), so both are kept as they were.
  let out = map.blocks.length ? map.text.slice(0, map.blocks[0].start) : "";
  pieces.forEach((piece, position) => {
    const previous = pieces[position - 1];
    if (piece.kind === "block") {
      const gap = gapBefore(piece.index);
      if (previous?.kind === "block" && previous.index === piece.index - 1) out += gap;
      else if (previous) out += blockGap(gap);
      const block = map.blocks[piece.index];
      const start = out.length;
      out += map.text.slice(block.start, block.end);
      blocks.push({ start, end: out.length, nodes: block.nodes });
    } else {
      if (previous) out += blockGap(map.blocks[piece.after + 1] ? gapBefore(piece.after + 1) : undefined);
      const start = out.length;
      out += piece.text;
      blocks.push({ start, end: out.length, nodes: piece.nodes });
    }
  });
  return { text: out + tail, blocks };
}

/** The raw node a schema defines for `cmux_raw`, holding `value` verbatim. */
export function rawNode(schema: Schema, kind: RawKind, value: string): ProseNode {
  const type = schema.nodes[RAW_NODE];
  return type.create({ kind }, value ? schema.text(value) : null);
}
