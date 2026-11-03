// Incremental parsing of a streaming agent message. A delta only appends text, so every block
// before the last safe boundary is final: it is parsed once, keeps its object (so a memoized block
// never renders again) and its key. Only the tail after that boundary is parsed again.
import { type MdBlock, parseMarkdown } from "./Markdown";
import { fenceStep } from "./fenceRule";
import { safeTail } from "./safeTail";

export type KeyedBlock = { key: string; block: MdBlock };

const LIST_START = /^(\s*)([-*+]|\d+[.)])\s+/;
const DISPLAY_OPEN = /^\s*\\\[/;
const DISPLAY_CLOSE = /\\\]\s*$/;
/// A line opening a `$$` display that does not close on it (Markdown.tsx displayMath).
const DOLLARS_OPEN = /^\s*\$\$(?!.*\$\$)/;
const DOLLARS_CLOSE = /\$\$/;

/**
 * Parses a growing Markdown text the way `parseMarkdown` parses it whole. A boundary is the start
 * of a complete line that follows a blank line, outside a code fence and an open `\[` or `$$` display, and
 * starts a block on its own (no indent, no list marker that would continue the list above). The
 * parser never joins blocks across such a line, so the text before it parses the same alone.
 * A block's key is its index in the message: blocks only ever append, and the blocks before a
 * boundary never change, so a block keeps its key from the first frame it shows to its last.
 */
export class IncrementalMarkdown {
  private source = "";
  private streaming = false;
  private messageAt?: number;
  private closed: KeyedBlock[] = [];
  private closedEnd = 0;
  private tail: KeyedBlock[] = [];
  /// The fence lines before `closedEnd`, counted as `fenceLines` counts them. It can be odd: a
  /// fence line inside a `$$` display counts here but does not open a fence for the boundary.
  private closedFences = 0;
  /// The source has an odd number of fence lines: its last block is a fence still arriving.
  fenceOpen = false;
  /// The characters the last update parsed (for tests and the debug perf report).
  lastParsedLength = 0;

  /// `streaming`: the tail draws only what is safe to draw half-written (safeTail.ts).
  update(source: string, options: { streaming?: boolean; messageAt?: number } = {}): KeyedBlock[] {
    const streaming = options.streaming ?? false;
    const messageAt = options.messageAt;
    if (source === this.source && streaming === this.streaming && messageAt === this.messageAt)
      return [...this.closed, ...this.tail];
    this.streaming = streaming;
    if (messageAt !== this.messageAt || !source.startsWith(this.source.slice(0, this.closedEnd))) this.reset();
    this.messageAt = messageAt;
    this.source = source;
    this.lastParsedLength = 0;
    const boundary = lastBlockBoundary(source, this.closedEnd);
    if (boundary > this.closedEnd) {
      const closing = source.slice(this.closedEnd, boundary);
      this.closed.push(...this.parse(closing, this.closed.length));
      this.closedFences += fenceLines(closing);
      this.closedEnd = boundary;
    }
    const rest = source.slice(this.closedEnd);
    // A boundary starts a line with a non-space character, so no fence line spans it and the
    // count of the whole source is the closed count plus the tail's.
    this.fenceOpen = (this.closedFences + fenceLines(rest)) % 2 === 1;
    // `parse` already keeps each tail block's object when it draws the same.
    this.tail = this.parse(streaming ? safeTail(rest) : rest, this.closed.length);
    return [...this.closed, ...this.tail];
  }

  private reset(): void {
    this.source = "";
    this.messageAt = undefined;
    this.closed = [];
    this.closedEnd = 0;
    this.tail = [];
    this.closedFences = 0;
  }

  private parse(text: string, first: number): KeyedBlock[] {
    this.lastParsedLength += text.length;
    return parseMarkdown(text, { messageAt: this.messageAt }).map((block, index) => {
      const key = String(first + index);
      // A tail block that closes now keeps the object it had, so it does not render again.
      const open = this.tail.find((entry) => entry.key === key);
      return open && sameBlock(open.block, block) ? open : { key, block };
    });
  }
}

/// The last block boundary of `source` after `from` (itself a boundary, or 0), or `from` when
/// there is none: the start of a complete line after a blank line, outside a code fence and an
/// open `\[` or `$$` display, that starts a block on its own. Text before it parses the same alone, in
/// this renderer and in the estimator's lexer.
export function lastBlockBoundary(source: string, from: number): number {
  let boundary = from;
  let fenced = 0;
  let display = false;
  let closer = DISPLAY_CLOSE;
  // The closed end always follows a blank line.
  let previousBlank = true;
  let start = from;
  while (start < source.length) {
    const newline = source.indexOf("\n", start);
    if (newline < 0) break; // The last line is still streaming.
    const line = source.slice(start, newline).replace(/\r$/, "");
    if (start > from && previousBlank && fenced === 0 && !display && /^\S/.test(line) && !LIST_START.test(line))
      boundary = start;
    if (!display && fenceStep(fenced, line) !== fenced) fenced = fenceStep(fenced, line);
    else if (fenced === 0) {
      if (display) display = !closer.test(line);
      else if (DOLLARS_OPEN.test(line)) [display, closer] = [true, DOLLARS_CLOSE];
      else if (DISPLAY_OPEN.test(line))
        [display, closer] = [!DISPLAY_CLOSE.test(line.replace(DISPLAY_OPEN, "")), DISPLAY_CLOSE];
    }
    previousBlank = !line.trim();
    start = newline + 1;
  }
  return boundary;
}

const FENCE_LINES = /^\s*```/gm;
/// The fence lines of `text`, counted the way Markdown counts them for an open fence.
export function fenceLines(text: string): number {
  return text.match(FENCE_LINES)?.length ?? 0;
}

/// Whether two parsed blocks draw the same (blocks are plain data).
function sameBlock(a: MdBlock, b: MdBlock): boolean {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}
