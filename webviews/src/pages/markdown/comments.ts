// Comments in the viewer (viewer-comments-DESIGN.md "Comments in the viewer"): each comment the user
// left with Comment… shows as a marker in the left margin of the block that holds its first line;
// the marker opens a card with the quoted text, the comment and Delete. The host keeps the list with
// the file and sends it in the config (`comments`) and on every change (the `comments` command).
import type { QuoteSourceMap } from "./selectionQuote";

/** One comment, as the host's `ViewerComment`. */
export interface ViewerComment {
  id: string;
  startLine: number;
  endLine: number;
  quoted: string;
  comment: string;
}

/** The comments in `value` (the host's `{v: 1, comments: [...]}`), skipping malformed ones. */
export function parseComments(value: unknown): ViewerComment[] {
  return [];
}

/** The index of the top-level node whose source holds 1-based `line`, else the last block before it. */
export function topIndexForLine(map: QuoteSourceMap, line: number): number | null {
  return null;
}
