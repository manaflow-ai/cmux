// Incremental parsing of a streaming agent message. A delta only appends text, so every block
// before the last safe boundary is final: it is parsed once, keeps its object (so a memoized block
// never renders again) and its key. Only the tail after that boundary is parsed again.
import { type MdBlock, parseMarkdown } from "./Markdown";

export type KeyedBlock = { key: string; block: MdBlock };

const LIST_START = /^(\s*)([-*+]|\d+[.)])\s+/;
const FENCE = /^\s*```/;
const DISPLAY_OPEN = /^\s*\\\[/;
const DISPLAY_CLOSE = /\\\]\s*$/;

/**
 * Parses a growing Markdown text the way `parseMarkdown` parses it whole. A boundary is the start
 * of a complete line that follows a blank line, outside a code fence and an open `\[` display, and
 * starts a block on its own (no indent, no list marker that would continue the list above). The
 * parser never joins blocks across such a line, so the text before it parses the same alone.
 * A block's key is its index in the message: blocks only ever append, and the blocks before a
 * boundary never change, so a block keeps its key from the first frame it shows to its last.
 */
export class IncrementalMarkdown {
  private source = "";
  private closed: KeyedBlock[] = [];
  private closedEnd = 0;
  private tail: KeyedBlock[] = [];
  /// The characters the last update parsed (for tests and the debug perf report).
  lastParsedLength = 0;

  update(source: string): KeyedBlock[] {
    if (source === this.source) return [...this.closed, ...this.tail];
    if (!source.startsWith(this.source.slice(0, this.closedEnd))) this.reset();
    this.source = source;
    this.lastParsedLength = 0;
    const boundary = this.lastBoundary(source);
    if (boundary > this.closedEnd) {
      this.closed.push(...this.parse(source.slice(this.closedEnd, boundary), this.closed.length));
      this.closedEnd = boundary;
    }
    const previous = new Map(this.tail.map((entry) => [entry.key, entry]));
    this.tail = this.parse(source.slice(this.closedEnd), this.closed.length).map((entry) => {
      const before = previous.get(entry.key);
      return before && sameBlock(before.block, entry.block) ? before : entry;
    });
    return [...this.closed, ...this.tail];
  }

  private reset(): void {
    this.source = "";
    this.closed = [];
    this.closedEnd = 0;
    this.tail = [];
  }

  private parse(text: string, first: number): KeyedBlock[] {
    this.lastParsedLength += text.length;
    return parseMarkdown(text).map((block, index) => {
      const key = String(first + index);
      // A tail block that closes now keeps the object it had, so it does not render again.
      const open = this.tail.find((entry) => entry.key === key);
      return open && sameBlock(open.block, block) ? open : { key, block };
    });
  }

  /// The last boundary after the closed text, or the closed end when there is none.
  private lastBoundary(source: string): number {
    let boundary = this.closedEnd;
    let fenced = false;
    let display = false;
    // The closed end always follows a blank line.
    let previousBlank = true;
    let start = this.closedEnd;
    while (start < source.length) {
      const newline = source.indexOf("\n", start);
      if (newline < 0) break; // The last line is still streaming.
      const line = source.slice(start, newline).replace(/\r$/, "");
      if (start > this.closedEnd && previousBlank && !fenced && !display && /^\S/.test(line) && !LIST_START.test(line))
        boundary = start;
      if (FENCE.test(line) && !display) fenced = !fenced;
      else if (!fenced) {
        if (display) display = !DISPLAY_CLOSE.test(line);
        else if (DISPLAY_OPEN.test(line)) display = !DISPLAY_CLOSE.test(line.replace(DISPLAY_OPEN, ""));
      }
      previousBlank = !line.trim();
      start = newline + 1;
    }
    return boundary;
  }
}

/// Whether two parsed blocks draw the same (blocks are plain data).
function sameBlock(a: MdBlock, b: MdBlock): boolean {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}
