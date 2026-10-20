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
  return null;
}
