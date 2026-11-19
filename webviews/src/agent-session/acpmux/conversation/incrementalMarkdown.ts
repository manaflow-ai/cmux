// Incremental parsing of a streaming agent message. A delta only appends text, so every block
// before the last safe boundary is final: it is parsed once, keeps its object (so a memoized block
// never renders again) and its key. The text after that boundary (the open region) is parsed in
// pieces too: a long fence, list, table or paragraph is split at points inside it where the text
// before parses the same whatever follows, so each delta parses only what came after the last one.
import { type MdBlock, type ParseInfo, parseMarkdown } from "./markdownModel";
import { fenceStep } from "./fenceRule";
import { INLINE_MATH, ITALIC, RULE_LINE, safeTail, type TailBefore } from "./safeTail";

export type KeyedBlock = { key: string; block: MdBlock };

/// A finished message's parse, by its text: a row that mounts again (scrolled back into view, a
/// fling passing over it, a chat reopened) reads the blocks it drew last time instead of parsing
/// its whole text again on the frame that shows it. Least recently used out past the caps (entries,
/// and characters of text held, so a few huge replies cannot pin megabytes).
type WholeParse = {
  closed: KeyedBlock[];
  closedEnd: number;
  tail: KeyedBlock[];
  closedFences: number;
  fenceOpen: boolean;
};
const WHOLE_PARSES_CAP = 2048;
const WHOLE_PARSES_CHARS = 2_000_000;
const wholeParses = new Map<string, WholeParse>();
let wholeChars = 0;
const wholeKey = (source: string, messageAt: number | undefined) => `${messageAt ?? ""}\u0000${source}`;

const LIST_START = /^(\s*)([-*+]|\d+[.)])\s+/;
const DISPLAY_OPEN = /^\s*\\\[/;
const DISPLAY_CLOSE = /\\\]\s*$/;
/// A line opening a `$$` display that does not close on it (Markdown.tsx displayMath).
const DOLLARS_OPEN = /^\s*\$\$(?!.*\$\$)/;
const DOLLARS_CLOSE = /\$\$/;

/// The rules the split points follow, as markdownModel.tsx and safeTail.ts read the same lines.
const LIST_ITEM = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const RULE = /^\s*([-*_])(\s*\1){2,}\s*$/;
const ROW = /^\s*\|/;
/// A display `\[` normalizeMath (mathDelimiters.ts) joins up to its closing line.
const BRACKET_OPEN = /^(\s*)\\\[(.*)$/;
const BRACKET_CLOSE = /\\\]\s*$/;
/// A link (or image) still being typed, as safeTail holds one back. Every prefix of such text is
/// one too, so text that is not one never becomes one by growing.
const LINK_TYPING = /^\[[^\]]*(?:\](?:\([^)]*)?)?$/;
/// Within this many characters of a paragraph split there is no digit: every time the parser marks
/// (timeHoverModel.ts decorateTimes) has digits, and reads at most 32 characters around itself.
const TIME_REACH = 48;
const LETTER = /\p{L}/u;
const indentOf = (line: string) => line.match(/^\s*/)![0].replace(/\t/g, "    ").length;
const blank = (line: string) => !line.trim();

/**
 * How the open region continues after a split point, for the text after it to parse alone:
 * `fresh`, a new block starts there; `fence`, inside a fence (the text after is parsed under its
 * opener); `list`, at an item of a list; `table`, at a row of a table (parsed under its header and
 * delimiter row); `paragraph`, inside a paragraph's line.
 */
type Kind =
  | { type: "fresh" }
  | { type: "fence"; opener: string; fence: number }
  | { type: "list"; indent: number; ordered: boolean }
  | { type: "table"; header: string; delimiter: string }
  | { type: "paragraph" };
const FRESH: Kind = { type: "fresh" };

/** The open region split in two: `head`, the text before `at`, parsed (its last block may go on
 * after `at`), and the text after it, parsed again on each update. */
type Split = {
  at: number;
  /// The region line `at` is on (it starts that line unless `mid`).
  line: number;
  /// `at` is inside a line: the text after it continues the head's last line.
  mid: boolean;
  head: MdBlock[];
  kind: Kind;
  before: TailBefore;
  version: number;
};

/**
 * Parses a growing Markdown text the way `parseMarkdown` parses it whole. A boundary is the start
 * of a complete line that follows a blank line, outside a code fence and an open `\[` or `$$` display, and
 * starts a block on its own (no indent, no list marker that would continue the list above). The
 * parser never joins blocks across such a line, so the text before it parses the same alone.
 * A block's key is its index in the message: blocks only ever append, and the blocks before a
 * boundary never change, so a block keeps its key from the first frame it shows to its last.
 *
 * The text after the last boundary is split again where its last block can be continued alone
 * (`Kind`), so a reply that never reaches a boundary (one long paragraph, fence or list) costs
 * each update what it appended, not what it holds. Each split is checked against the lines on
 * both sides; where none holds, that text is parsed whole as before.
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

  // The open region's complete lines, scanned once each: where each starts, and before each the
  // state of every reader that follows fences and displays line by line: the boundary scan
  // (`lastBlockBoundary`, which safeTail's openDisplay follows the same way), normalizeMath, and
  // safeTail's own fence count. A split needs them all to agree with how the text after it starts.
  private scanAt = 0;
  private searchedTo = 0;
  private lineAt: number[] = [];
  private boundaryFence: number[] = [0];
  private boundaryDisplay: boolean[] = [false];
  private mathFence: number[] = [0];
  private mathPending: boolean[] = [false];
  private tailFence: number[] = [0];
  private fences: number[] = [0];
  private displayCloser = DISPLAY_CLOSE;
  private previousBlank = true;
  private boundaryAt = 0;
  private boundaryLine = 0;
  /// A `\r` in the region: the parser breaks lines there too, so no split is made in it.
  private carriage = false;
  private split: Split = emptySplit(0);
  private splits = 0;
  /// After a split could not be made, wait for this much source before looking again.
  private retryAt = 0;
  private lastMerge?: { version: number; first: MdBlock; merged: MdBlock };

  /// `streaming`: the tail draws only what is safe to draw half-written (safeTail.ts).
  update(source: string, options: { streaming?: boolean; messageAt?: number } = {}): KeyedBlock[] {
    const streaming = options.streaming ?? false;
    const messageAt = options.messageAt;
    if (source === this.source && streaming === this.streaming && messageAt === this.messageAt)
      return [...this.closed, ...this.tail];
    // A parser that has drawn nothing yet, given a finished text it parsed before: the same blocks.
    const fresh = this.source === "" && this.closedEnd === 0 && !streaming && source !== "";
    if (fresh) {
      const key = wholeKey(source, messageAt);
      const known = wholeParses.get(key);
      if (known) {
        wholeParses.delete(key);
        wholeParses.set(key, known);
        this.streaming = false;
        this.messageAt = messageAt;
        this.source = source;
        this.lastParsedLength = 0;
        this.closed = [...known.closed];
        this.closedEnd = known.closedEnd;
        this.tail = known.tail;
        this.closedFences = known.closedFences;
        this.fenceOpen = known.fenceOpen;
        this.resetRegion();
        return [...this.closed, ...this.tail];
      }
    }
    this.streaming = streaming;
    if (messageAt !== this.messageAt) this.reset();
    else if (!source.startsWith(this.source.slice(0, this.scanAt))) {
      if (source.startsWith(this.source.slice(0, this.closedEnd))) this.resetRegion();
      else this.reset();
    }
    this.messageAt = messageAt;
    this.source = source;
    this.lastParsedLength = 0;
    this.scan();
    if (this.boundaryAt > this.closedEnd) {
      const closing = source.slice(this.closedEnd, this.boundaryAt);
      this.closed.push(...this.parse(closing, this.closed.length));
      this.closedFences += this.fences[this.boundaryLine]!;
      this.closedEnd = this.boundaryAt;
      this.resetRegion();
      this.scan();
    }
    // A boundary starts a line, so the fence lines of the whole source are the closed count plus
    // the region's complete lines and its last one.
    this.fenceOpen =
      (this.closedFences + this.fences[this.lineAt.length]! + (FENCE_LINE.test(source.slice(this.scanAt)) ? 1 : 0)) %
        2 ===
      1;
    if (!this.carriage) this.advance();
    const { blocks, merged } = this.tailBlocks();
    this.tail = this.keyed(blocks, this.closed.length, merged);
    if (fresh) {
      const key = wholeKey(source, messageAt);
      wholeParses.set(key, {
        closed: [...this.closed],
        closedEnd: this.closedEnd,
        tail: this.tail,
        closedFences: this.closedFences,
        fenceOpen: this.fenceOpen,
      });
      wholeChars += key.length;
      while (wholeParses.size > WHOLE_PARSES_CAP || (wholeChars > WHOLE_PARSES_CHARS && wholeParses.size > 1)) {
        const oldest = wholeParses.keys().next().value!;
        wholeParses.delete(oldest);
        wholeChars -= oldest.length;
      }
    }
    return [...this.closed, ...this.tail];
  }

  private reset(): void {
    this.source = "";
    this.messageAt = undefined;
    this.closed = [];
    this.closedEnd = 0;
    this.tail = [];
    this.closedFences = 0;
    this.resetRegion();
  }

  /// Forgets the open region's lines and split: it is scanned again from `closedEnd`.
  private resetRegion(): void {
    this.scanAt = this.closedEnd;
    this.searchedTo = 0;
    this.lineAt = [];
    this.boundaryFence = [0];
    this.boundaryDisplay = [false];
    this.mathFence = [0];
    this.mathPending = [false];
    this.tailFence = [0];
    this.fences = [0];
    this.displayCloser = DISPLAY_CLOSE;
    this.previousBlank = true;
    this.boundaryAt = this.closedEnd;
    this.boundaryLine = 0;
    this.carriage = false;
    this.split = emptySplit(this.closedEnd);
    this.retryAt = 0;
    this.lastMerge = undefined;
  }

  /// Reads the region's new complete lines: the last block boundary (as `lastBlockBoundary`
  /// finds it) and each line's reader states.
  private scan(): void {
    const source = this.source;
    // The last line was searched for its newline up to the old end already.
    const searched = Math.max(this.scanAt, Math.min(this.searchedTo, source.length));
    this.searchedTo = source.length;
    for (let newline = source.indexOf("\n", searched); newline >= 0; newline = source.indexOf("\n", this.scanAt)) {
      const k = this.lineAt.length;
      const raw = source.slice(this.scanAt, newline);
      const line = raw.replace(/\r$/, "");
      if (raw.includes("\r")) this.carriage = true;
      let fenced = this.boundaryFence[k]!;
      let display = this.boundaryDisplay[k]!;
      if (k > 0 && this.previousBlank && fenced === 0 && !display && /^\S/.test(line) && !LIST_START.test(line)) {
        this.boundaryAt = this.scanAt;
        this.boundaryLine = k;
      }
      if (!display && fenceStep(fenced, line) !== fenced) fenced = fenceStep(fenced, line);
      else if (fenced === 0) {
        if (display) display = !this.displayCloser.test(line);
        else if (DOLLARS_OPEN.test(line)) [display, this.displayCloser] = [true, DOLLARS_CLOSE];
        else if (DISPLAY_OPEN.test(line))
          [display, this.displayCloser] = [!DISPLAY_CLOSE.test(line.replace(DISPLAY_OPEN, "")), DISPLAY_CLOSE];
      }
      // normalizeMath: a `\[` outside a fence joins the lines up to its `\]`, which follow no fence.
      let mathFence = this.mathFence[k]!;
      let pending = this.mathPending[k]!;
      if (pending) pending = !BRACKET_CLOSE.test(line);
      else {
        mathFence = fenceStep(mathFence, line);
        const open = mathFence ? null : BRACKET_OPEN.exec(line);
        if (open && !BRACKET_CLOSE.test(open[2]!)) pending = true;
      }
      this.lineAt.push(this.scanAt);
      this.boundaryFence.push(fenced);
      this.boundaryDisplay.push(display);
      this.mathFence.push(mathFence);
      this.mathPending.push(pending);
      this.tailFence.push(fenceStep(this.tailFence[k]!, line));
      this.fences.push(this.fences[k]! + fenceLines(raw));
      this.previousBlank = !line.trim();
      this.scanAt = newline + 1;
    }
  }

  private lineStart(k: number): number {
    return k < this.lineAt.length ? this.lineAt[k]! : this.scanAt;
  }

  /// Region line `k` (the last, still arriving line at `lineAt.length`); "" before the region.
  private lineText(k: number): string {
    if (k < 0) return "";
    if (k >= this.lineAt.length) return this.source.slice(this.scanAt);
    return this.source.slice(this.lineAt[k], this.lineStart(k + 1) - 1);
  }

  /// The region line holding source offset `at`.
  private lineOf(at: number): number {
    if (at >= this.scanAt) return this.lineAt.length;
    let low = 0;
    let high = this.lineAt.length - 1;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (this.lineAt[middle]! <= at) low = middle;
      else high = middle - 1;
    }
    return low;
  }

  /// Moves the split as far on as the region allows: the latest line, or point inside a line,
  /// where the text before it parses the same whatever follows.
  private advance(): void {
    const length = this.source.length;
    if (length < this.retryAt) return;
    const split = this.split;
    const tries: [at: number, line: number, mid: boolean][] = [];
    const line = this.lineCandidate();
    if (line > split.line) tries.push([this.lineAt[line]!, line, false]);
    const mid = this.midCandidate();
    if (mid > split.at) tries.push([mid, this.lineOf(mid), true]);
    tries.sort((a, b) => b[0] - a[0]);
    for (const [at, k, inside] of tries) {
      if (this.commit(at, k, inside)) {
        this.retryAt = 0;
        return;
      }
    }
    // Nothing to split at yet (an unsupported block, or text that can still change what came
    // before it): look again once the text after the split has doubled, so the looking costs
    // no more than the parsing it saves.
    this.retryAt = length + Math.max(TIME_REACH, length - split.at);
  }

  /// The latest line a split could start on: two complete lines after it (safeTail reads the last
  /// two lines it is given), where the region's readers agree and the line can continue a block.
  private lineCandidate(): number {
    const split = this.split;
    for (let s = this.lineAt.length - 2; s > split.line; s--) {
      if (this.boundaryDisplay[s] || this.boundaryDisplay[s + 1] || this.boundaryDisplay[s + 2] || this.mathPending[s])
        continue;
      const fence = this.boundaryFence[s]!;
      if (this.mathFence[s] !== fence || this.tailFence[s] !== fence) continue;
      const above = this.lineText(s - 1);
      if (!seamSafe(above)) continue;
      if (fence > 0) {
        if (this.boundaryFence[s + 1] === fence) return s;
        continue;
      }
      const line = this.lineText(s);
      if (
        (LIST_ITEM.test(line) && !RULE.test(line) && !line.includes("|")) ||
        (line.includes("|") && line.trim() && !blank(above)) ||
        (s > 0 && this.boundaryFence[s - 1]! > 0) ||
        /^#{1,6}\s/.test(above) ||
        RULE.test(above)
      )
        return s;
    }
    return -1;
  }

  /// The latest point inside a line a split could be made at: in a fence, after a character that
  /// is not a space, backtick or rule mark; in prose, after a letter, with no digit within
  /// TIME_REACH on either side and no path running across it.
  private midCandidate(): number {
    const source = this.source;
    const split = this.split;
    const length = source.length;
    if (this.boundaryFence[this.lineAt.length]! > 0) {
      const low = Math.max(split.at, this.scanAt) + 1;
      for (let at = length - 1; at >= low && at > length - 64; at--) if (!/[\s`*_-]/.test(source[at - 1]!)) return at;
      return -1;
    }
    // A digit rules out every point within TIME_REACH of it: skip past each one found.
    const low = Math.max(split.at + 1, TIME_REACH, length - 4 * TIME_REACH);
    for (let at = length - TIME_REACH; at >= low; at--) {
      const digit = source.slice(at - TIME_REACH, at + TIME_REACH).search(/\d(?!.*\d)/s);
      if (digit >= 0) {
        at = at - TIME_REACH + digit - TIME_REACH + 1;
        continue;
      }
      if (proseSplit(source, at)) return at;
    }
    return -1;
  }

  /// Parses the text between the split and `at` onto the head and moves the split to `at`, if the
  /// text after `at` can be parsed alone (`kindAt`).
  private commit(at: number, line: number, mid: boolean): boolean {
    const split = this.split;
    const source = this.source;
    const prefix = this.prefixOf(split);
    // A split at a line's start leaves the newline before it to the text after it.
    const segment = source.slice(split.at, mid ? at : at - 1);
    const info: ParseInfo = { lastStart: -1, pendingDisplay: false };
    const blocks = this.parseText(prefix + segment, info);
    if (info.pendingDisplay) return false;
    let head: MdBlock[];
    let continuing = false;
    if (split.kind.type === "fresh") head = [...split.head, ...blocks];
    else {
      const first = blocks[0];
      if (!first) [head, continuing] = [split.head, true];
      else {
        const joined = join(split, first, this.markOf(split));
        if (!joined) return false;
        head = [...split.head.slice(0, -1), joined, ...blocks.slice(1)];
        continuing = blocks.length === 1;
      }
    }
    const last = head.at(-1);
    if (!last) return false;
    // The region line the last block starts on, or undefined when it began before this segment.
    const ctxLines = contextLines(split.kind);
    const anchor = continuing ? undefined : split.line + info.lastStart - ctxLines;
    if (anchor !== undefined && anchor < split.line) return false;
    const kind = mid ? this.midKind(at, line, last, anchor) : this.lineKind(line, last, anchor);
    if (!kind) return false;
    this.split = {
      at,
      line,
      mid,
      head,
      kind,
      before: this.carry(split, at, kind),
      version: ++this.splits,
    };
    return true;
  }

  /// How the text from line `s` on goes on from the head ending in `last` (which starts on region
  /// line `anchor`), or undefined when it might not parse the same alone.
  private lineKind(s: number, last: MdBlock, anchor: number | undefined): Kind | undefined {
    const previous = this.split.kind;
    if (s > this.lineAt.length - 2) return;
    if (this.boundaryDisplay[s] || this.boundaryDisplay[s + 1] || this.boundaryDisplay[s + 2] || this.mathPending[s])
      return;
    const above = this.lineText(s - 1);
    if (!seamSafe(above)) return;
    const fence = this.boundaryFence[s]!;
    if (this.mathFence[s] !== fence || this.tailFence[s] !== fence) return;
    const line = this.lineText(s);
    switch (last.type) {
      case "code": {
        if (!last.open) return fence === 0 && !blank(above) ? FRESH : undefined;
        const opener =
          anchor === undefined ? (previous.type === "fence" ? previous.opener : undefined) : this.lineText(anchor);
        if (opener === undefined) return;
        const n = fenceStep(0, opener);
        // The head holds a body line, and line `s` does not close the fence.
        if (!n || fence !== n || this.boundaryFence[s + 1] !== n) return;
        if (anchor !== undefined && anchor >= s - 1) return;
        return { type: "fence", opener, fence: n };
      }
      case "heading":
      case "hr":
      case "math":
        return fence === 0 && !blank(above) ? FRESH : undefined;
      case "list": {
        if (fence !== 0) return;
        const indent =
          anchor === undefined
            ? previous.type === "list"
              ? previous.indent
              : undefined
            : indentOf(this.lineText(anchor));
        if (indent === undefined) return;
        const kind: Kind = { type: "list", indent, ordered: last.ordered };
        // An item of the list, after at most one blank line (two end it).
        if (!continues(kind, line) || (blank(above) && blank(this.lineText(s - 2)))) return;
        return kind;
      }
      case "table": {
        if (fence !== 0 || blank(above) || blank(line) || !line.includes("|")) return;
        const [header, delimiter] =
          anchor === undefined
            ? previous.type === "table"
              ? [previous.header, previous.delimiter]
              : []
            : [this.lineText(anchor), this.lineText(anchor + 1)];
        if (header === undefined || delimiter === undefined || /^\s*(?:\$\$|\\\[)/.test(header)) return;
        return { type: "table", header, delimiter };
      }
    }
    return;
  }

  /// How the text from source offset `at` (inside region line `k`) goes on from the head ending in
  /// `last`, or undefined when it might not parse the same alone.
  private midKind(at: number, k: number, last: MdBlock, anchor: number | undefined): Kind | undefined {
    const previous = this.split.kind;
    const source = this.source;
    if (at >= source.length || this.boundaryDisplay[k] || this.mathPending[k]) return;
    const fence = this.boundaryFence[k]!;
    if (this.mathFence[k] !== fence || this.tailFence[k] !== fence) return;
    const start = this.lineStart(k);
    // The line up to the split; a split earlier on this line already checked the text before it,
    // so only what follows it is read again (a reply of one long line costs what it appends).
    const checked =
      this.split.mid && this.split.line === k && this.split.kind.type !== "fresh" ? this.split.at - 1 : start;
    const part = source.slice(start, at);
    const fresh = source.slice(checked, at);
    const mark = source[at - 1]!;
    if (fresh.includes("\r")) return;
    if (last.type === "code" && last.open) {
      const opener =
        anchor === undefined ? (previous.type === "fence" ? previous.opener : undefined) : this.lineText(anchor);
      if (opener === undefined) return;
      const n = fenceStep(0, opener);
      if (!n || fence !== n || (anchor !== undefined && anchor >= k)) return;
      // The line can be neither a closer nor one being typed, and the head's last line holds a
      // character no rule line has.
      if (/[\s`*_-]/.test(mark) || /^\s*`/.test(part)) return;
      return { type: "fence", opener, fence: n };
    }
    if (last.type !== "paragraph" || fence !== 0 || !proseSplit(source, at)) return;
    // Nothing that starts the line makes it a fence, a display, a table row or the delimiter row
    // being typed, and neither line above is a row safeTail could hold back with it.
    // Nor does it hold a `$`, `\\` or `|`: safeTail reads the last line's math whole, and a table
    // header's cells are counted from its line's start.
    if (
      /^\s*(?:`|\$\$|\\\[|\||:?-)/.test(part) ||
      /[$\\|]/.test(fresh) ||
      ROW.test(this.lineText(k - 1)) ||
      ROW.test(this.lineText(k - 2))
    )
      return;
    // From the paragraph's start, or the split it goes on from (with the character before it).
    const from = anchor === undefined ? this.split.at - (this.split.mid ? 1 : 0) : this.lineStart(anchor);
    if (!inlineClosed(source.slice(from, at))) return;
    return { type: "paragraph" };
  }

  /// safeTail's state at `at`: the fence, and the `**` and backtick parity of the paragraph text
  /// before it (from its last blank line), updated by the text between the split and `at`.
  private carry(split: Split, at: number, kind: Kind): TailBefore {
    const source = this.source;
    const fence = kind.type === "fence" ? kind.fence : 0;
    const segment = source.slice(split.at, at);
    const empty = split.at === this.closedEnd;
    // One character of what came before, so a blank line or rule line across the split reads as one.
    const text = empty ? segment : source[split.at - 1] + segment;
    const gap = text.lastIndexOf("\n\n");
    if (empty || gap >= 0) {
      const paragraph = text.slice(gap + 1);
      return { fence, stars: stars(paragraph), ticks: ticks(paragraph) };
    }
    return { fence, stars: split.before.stars ^ stars(text), ticks: split.before.ticks ^ ticks(text) };
  }

  /// What the text after a split is parsed under: the fence's opener or the table's header and
  /// delimiter row, and inside a line the character before the split (`markOf`).
  private prefixOf(split: Split): string {
    return contextOf(split.kind) + this.markOf(split);
  }

  private markOf(split: Split): string {
    return split.mid ? this.source[split.at - 1]! : "";
  }

  /// The region's blocks: the head's, with the text after the split parsed and joined on.
  private tailBlocks(): { blocks: MdBlock[]; merged?: MdBlock } {
    const split = this.split;
    const mark = this.markOf(split);
    const rest = mark + this.source.slice(split.at);
    const text = this.streaming ? safeTail(rest, split.before) : rest;
    const newline = text.indexOf("\n");
    if (text.startsWith(mark) && accepts(split.kind, newline < 0 ? text : text.slice(0, newline))) {
      const live = this.parseText(contextOf(split.kind) + text);
      if (split.kind.type === "fresh") return { blocks: [...split.head, ...live] };
      const first = live[0];
      if (first) {
        const reuse = this.lastMerge;
        const merged =
          reuse && reuse.version === split.version && sameBlock(reuse.first, first)
            ? reuse.merged
            : join(split, first, mark);
        if (merged) {
          this.lastMerge = { version: split.version, first, merged };
          return { blocks: [...split.head.slice(0, -1), merged, ...live.slice(1)], merged };
        }
      }
    }
    // The text after the split no longer starts the way the split needs (safeTail held part of
    // it back): the region parses whole.
    const region = this.source.slice(this.closedEnd);
    return { blocks: this.parseText(this.streaming ? safeTail(region) : region) };
  }

  private parseText(text: string, info?: ParseInfo): MdBlock[] {
    this.lastParsedLength += text.length;
    return parseMarkdown(text, { messageAt: this.messageAt, ...(info ? { info } : {}) });
  }

  private parse(text: string, first: number): KeyedBlock[] {
    const open = new Map(this.tail.map((entry) => [entry.key, entry]));
    return this.parseText(text).map((block, index) => {
      const key = String(first + index);
      // A tail block that closes now keeps the object it had, so it does not render again.
      const entry = open.get(key);
      return entry && sameBlock(entry.block, block) ? entry : { key, block };
    });
  }

  /// Keys the region's blocks, each keeping the entry it had while it draws the same. `merged`, a
  /// long block joined anew, is not compared (that would read all of it on every update).
  private keyed(blocks: MdBlock[], first: number, merged?: MdBlock): KeyedBlock[] {
    const open = new Map(this.tail.map((entry) => [entry.key, entry]));
    return blocks.map((block, index) => {
      const key = String(first + index);
      const entry = open.get(key);
      if (entry && (entry.block === block || (block !== merged && sameBlock(entry.block, block)))) return entry;
      return { key, block };
    });
  }
}

function emptySplit(at: number): Split {
  return { at, line: 0, mid: false, head: [], kind: FRESH, before: { fence: 0, stars: 0, ticks: 0 }, version: 0 };
}

function contextOf(kind: Kind): string {
  if (kind.type === "fence") return `${kind.opener}\n`;
  if (kind.type === "table") return `${kind.header}\n${kind.delimiter}\n`;
  return "";
}

function contextLines(kind: Kind): number {
  return kind.type === "fence" ? 1 : kind.type === "table" ? 2 : 0;
}

/// A line of the list an item of `kind` continues: at its indent, numbered as it is, and not a
/// rule or a table row the parser would read first.
function continues(kind: Kind & { type: "list" }, line: string): boolean {
  const item = LIST_ITEM.exec(line);
  return (
    !!item &&
    indentOf(line) === kind.indent &&
    /\d/.test(item[2]!) === kind.ordered &&
    !RULE.test(line) &&
    !line.includes("|")
  );
}

/// Whether the text after a split, as safeTail left it, still starts the way its kind needs.
function accepts(kind: Kind, line: string): boolean {
  switch (kind.type) {
    case "fence":
      return fenceStep(kind.fence, line) === kind.fence;
    case "list":
      return continues(kind, line);
    case "table":
      return line.includes("|") && !blank(line);
    default:
      return true;
  }
}

/// The head's last block `split.head.at(-1)` with `next`, the first block of the text after the
/// split, joined on as the parser reads them together; undefined when `next` does not continue it.
/// Inside a line `next` starts with `mark`, the character before the split, which the head has.
function join(split: Split, next: MdBlock, mark: string): MdBlock | undefined {
  const last = split.head.at(-1);
  const mid = split.mid;
  if (!last) return;
  if (last.type === "code" && next.type === "code" && last.open && last.lang === next.lang) {
    if (mid && !next.code.startsWith(mark)) return;
    const code = mid ? last.code + next.code.slice(1) : `${last.code}\n${next.code}`;
    return { type: "code", lang: last.lang, code, ...(next.open ? { open: true as const } : {}) };
  }
  if (last.type === "paragraph" && next.type === "paragraph" && mid && next.text.startsWith(mark))
    return { type: "paragraph", text: last.text + next.text.slice(1) };
  if (last.type === "list" && next.type === "list" && !mid && last.ordered === next.ordered)
    return { type: "list", ordered: last.ordered, start: last.start, items: last.items.concat(next.items) };
  if (last.type === "table" && next.type === "table" && !mid)
    return { type: "table", align: last.align, header: last.header, rows: last.rows.concat(next.rows) };
  return;
}

/// A line that ends the head at a split at the next line's start: blank, or holding a character
/// no rule line has, so safeTail's rule lines never run across the split.
function seamSafe(line: string): boolean {
  return line === "" || /[^\s*_-]/.test(line);
}

/// Whether prose can be split at `at`: after a letter, with no digit within TIME_REACH on either
/// side, and the run of non-space characters across it short and with no `/` (a path or URL).
function proseSplit(source: string, at: number): boolean {
  if (at < TIME_REACH || at + TIME_REACH > source.length || !LETTER.test(source[at - 1]!)) return false;
  const around = source.slice(at - TIME_REACH, at + TIME_REACH);
  if (/\d|\r/.test(around)) return false;
  const before = around.slice(0, TIME_REACH);
  const after = around.slice(TIME_REACH);
  const start = before.search(/\s\S*$/);
  const end = after.search(/\s/);
  if (start < 0 || end < 0) return false;
  return !(before.slice(start) + after.slice(0, end)).includes("/");
}

const spaces = (match: string) => " ".repeat(match.length);

/// Whether a paragraph's text up to a split leaves nothing open that text after it could still
/// change: every code span (as decorateTimes and safeTail pair backticks), math run, italic run and
/// link destination closes in it, and no `[` can still become a link or take a later `](`.
export function inlineClosed(text: string): boolean {
  for (let tick = text.indexOf("`"); tick >= 0;) {
    let run = tick;
    while (text[run] === "`") run++;
    const close = text.indexOf(text.slice(tick, run), run);
    if (close < 0) return false;
    tick = text.indexOf("`", close + run - tick);
  }
  for (const line of text.split("\n")) {
    if (/[`$\\]/.test(line.replace(INLINE_MATH, spaces))) return false;
    let masked = line.replace(/`[^`]*`|\\.|\*\*/g, spaces).replace(/\[[^\]]*\]\([^)]*\)/g, spaces);
    for (const { whole } of Object.values(ITALIC)) masked = masked.replace(whole, spaces);
    if (/`|(?<![\w*])\*(?=[^*\s])|(?<![\w_])_(?=[^_\s])/.test(masked)) return false;
  }
  const open = text.lastIndexOf("[");
  if (open >= 0 && !text.includes("]", open)) return false;
  const lastLine = text.slice(text.lastIndexOf("\n") + 1);
  const typing = lastLine.lastIndexOf("[");
  if (typing >= 0 && LINK_TYPING.test(lastLine.slice(typing))) return false;
  for (let marker = text.indexOf("]("); marker >= 0; marker = text.indexOf("](", marker + 2)) {
    if (text.lastIndexOf("[", marker) < 0) return false;
    let depth = 0;
    let at = marker + 2;
    for (; at < text.length; at++) {
      if (text[at] === "(") depth++;
      else if (text[at] === ")" && depth-- === 0) break;
    }
    if (at >= text.length) return false;
  }
  return true;
}

const stars = (text: string) => (text.replace(RULE_LINE, "").match(/\*\*/g)?.length ?? 0) & 1;
const ticks = (text: string) => (text.match(/`/g)?.length ?? 0) & 1;

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
/// The last line, which has no newline, is a fence line (anchored: it reads only its start).
const FENCE_LINE = /^\s*```/;
/// The fence lines of `text`, counted the way Markdown counts them for an open fence.
export function fenceLines(text: string): number {
  return text.match(FENCE_LINES)?.length ?? 0;
}

/// Whether two parsed blocks draw the same (blocks are plain data).
function sameBlock(a: MdBlock, b: MdBlock): boolean {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}
