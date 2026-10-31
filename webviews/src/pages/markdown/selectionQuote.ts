// The source lines of a selection in the Markdown page (viewer-comments-DESIGN.md "Line ranges"):
// the page's source map says which source block holds the selection's first and last top-level
// node; inside each block the selection's first and last line text narrows the range to its lines.

/** A source map as `MarkdownEditor.snapshot()` returns it: blocks in document order. */
export interface QuoteSourceMap {
  text: string;
  blocks: readonly { start: number; end: number; nodes: readonly unknown[] }[];
}

/** A 1-based, inclusive line range. */
export interface QuoteLines {
  startLine: number;
  endLine: number;
}

/**
 * The lines of `map.text` that hold the selection: `firstTop` and `lastTop` are the indexes of the
 * top-level nodes at the selection's ends, `quoted` its text. Null when an index is out of range.
 */
export function quoteLines(map: QuoteSourceMap, firstTop: number, lastTop: number, quoted: string): QuoteLines | null {
  const first = blockAt(map, firstTop);
  const last = blockAt(map, lastTop);
  if (!first || !last) return null;
  const lines = quoted
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  // The first line's text inside the first block, the last line's inside the last block; text the
  // source writes differently (emphasis marks, an escaped character) keeps the block's own edge.
  const head = lines[0] ? map.text.slice(first.start, first.end).indexOf(lines[0]) : -1;
  const tailText = lines.at(-1);
  const tail = tailText ? map.text.slice(last.start, last.end).lastIndexOf(tailText) : -1;
  const startOffset = head >= 0 ? first.start + head : first.start;
  const endOffset = tail >= 0 ? last.start + tail : Math.max(last.start, last.end - 1);
  const startLine = lineAt(map.text, startOffset);
  return { startLine, endLine: Math.max(startLine, lineAt(map.text, endOffset)) };
}

/** The block holding top-level node `index`: blocks cover the document's nodes in order. */
function blockAt(map: QuoteSourceMap, index: number) {
  if (index < 0) return undefined;
  let seen = 0;
  for (const block of map.blocks) {
    seen += block.nodes.length;
    if (index < seen) return block;
  }
  return undefined;
}

/** The 1-based line of `offset` in `text`. */
function lineAt(text: string, offset: number): number {
  let line = 1;
  for (let index = 0; index < offset && index < text.length; index++) if (text.charCodeAt(index) === 10) line++;
  return line;
}
