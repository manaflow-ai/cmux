// What of a streaming reply's last block may draw now (plans/cmux-next/acp-streaming.md
// "Streaming-safe tail", from hq-48's prototype). Half-written Markdown would draw wrongly and
// then flip when the rest arrives: a fence opener reads `t`, `ty` before `TypeScript`, a table
// header draws as a paragraph of pipes until its separator row, a link or image shows its brackets,
// a bold or code run draws its markers until the closer, and a `-`, `1.` or `##` draws as text
// before it turns out to open a list item, a heading or a rule. So the tail holds back a fence
// opener until its newline, a table header until its separator row and each row until its newline,
// a link until its `)`, a last line that is still only a block marker (a list marker, `#`s, or a
// rule's `-`, `*`, `_`) until the character after it, and a `*`, `_` or backtick typed at the very
// end; an open `**`, `*`, `_` or backtick run is closed for now, so it is styled from its first
// character. Inside an open fence only a closing fence still being typed (or its indent) is held,
// with the newline before it, so the card is the height it closes at. Math draws only once it is whole: a display
// equation (`$$`, `\[`) is held back from its opener until its closer, and an inline `$…$`, `$$…$$`
// or `\(…\)` from its opening delimiter, so half an equation never draws as source and then turns
// into math. A table without edge pipes is not held: its header is a prose line until the next one.

import { fenceStep } from "./fenceRule";

/// Complete dollar candidates and explicit math on one line. This mask deliberately includes
/// candidates the renderer rejects (such as `$x$word`): rejected math must remain literal while
/// streaming rather than be mistaken for an unfinished equation.
const INLINE_MATH =
  /`[^`]*`|\\[\\$]|\$\$[^$\n]+?\$\$|(?<![\\$])\$(?=[^\s$])(?:\\.|[^$\\\n`])*?[^\s\\`]\$(?!\d)|\\\(.+?\\\)/g;
/// An opener with no closer yet: `$$`, `\(`, `$` before something that is not a digit or
/// space (`$5` is a price), or a backslash at the very end (`\(`, `\[` or `\$` arriving).
const OPEN_MATH = /\$\$|\\\(|(?<!\\)\$(?![({])(?=[^\s\d$]|$)|\\$/;

/// The index of the line that opens a display equation not yet closed (-1 when none), and
/// whether the last line closes one (it is the equation's, not inline math).
function openDisplay(lines: string[]): { open: number; closesLast: boolean } {
  let fence = 0;
  let open = -1;
  let closer: RegExp = /\$\$/;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!;
    if (open >= 0) {
      if (closer.test(line)) {
        open = -1;
        if (index === lines.length - 1) return { open, closesLast: true };
      }
      continue;
    }
    fence = fenceStep(fence, line);
    if (fence) continue;
    const dollars = line.match(/^\s*\$\$(.*)$/);
    if (dollars && !dollars[1]!.includes("$$")) [open, closer] = [index, /\$\$/];
    else if (/^\s*\\\[/.test(line) && !/\\\]\s*$/.test(line)) [open, closer] = [index, /\\\]\s*$/];
  }
  return { open, closesLast: false };
}

/// A last line that is still only a block marker: a list marker (`-`, `*`, `+`, `1.`, or digits
/// that may become one), a heading's `#`s, or a rule's `-`, `*`, `_` (also `- **` opening an item).
/// What it opens is known only from the next character that is not one of them.
const MARKER_LINE = /^\s*(?:[-*+]|\d{1,9}[.)]?|#{1,6})\s*$|^\s*[-*_][-*_\s]*$/;
/// A thematic break (Markdown.tsx), whose stars are not a bold or italic run.
const RULE_LINE = /^\s*([-*_])(\s*\1){2,}\s*$/gm;
/// Complete emphasis on a line, as Markdown.tsx's INLINE_RE matches it, and an opener with no
/// closer yet. An opener is closed for now only after a space, `(` or a quote, stricter than
/// INLINE_RE's "not after a word": `src/*.ts` and `/_next` open nothing that will close.
const ITALIC = {
  "*": { whole: /(?<![\w*])\*[^*\s][^*]*\*(?![\w*])/g, open: /(?<=^|[\s(["'])\*(?=[^*\s])[^*]*$/ },
  _: { whole: /(?<![\w_])_[^_\s][^_]*_(?![\w_])/g, open: /(?<=^|[\s(["'])_(?=[^_\s])[^_]*$/ },
} as const;

/// `line` with an italic run still open closed for now (`*maybe` -> `*maybe*`), so `2*3`,
/// `snake_case` and `file_name` never are.
function closedItalic(line: string): string {
  const masked = line
    .replace(/`[^`]*`|\\.|\*\*/g, (match) => " ".repeat(match.length))
    .replace(/\[[^\]]*\]\([^)]*\)/g, (match) => " ".repeat(match.length));
  for (const [marker, { whole, open }] of Object.entries(ITALIC)) {
    const rest = masked.replace(whole, (match) => " ".repeat(match.length));
    if (open.test(rest)) return `${line}${marker}`;
  }
  return line;
}

/// `line` up to an inline equation that has not closed yet.
function closedMath(line: string): string {
  const masked = line.replace(INLINE_MATH, (match) => " ".repeat(match.length));
  const open = masked.search(OPEN_MATH);
  return open < 0 ? line : line.slice(0, open);
}

export function safeTail(tail: string): string {
  const display = openDisplay(tail.split("\n"));
  const lines = display.open >= 0 ? tail.split("\n").slice(0, display.open).concat("") : tail.split("\n");
  let fence = 0;
  for (let index = 0; index < lines.length - 1; index += 1) fence = fenceStep(fence, lines[index]!);
  let last = lines.at(-1) ?? "";
  if (fence > 0 && new RegExp(`^\\s*(?:\`{1,${fence}}[^\`]*)?$`).test(last)) {
    // In a fence, a closer still being typed (or the indent before one) is held with the newline
    // before it: the open card draws the lines the closed one will, so it never shrinks a line.
    // A code line that starts with a backtick (a shell or Markdown sample) and has no second one
    // yet holds the same way until its line ends.
    lines.pop();
    last = lines.at(-1)!;
  } else if (/^\s*`{1,3}[^`]*$/.test(last)) last = "";
  else if (fence === 0) {
    if (!display.closesLast) last = closedMath(last);
    if (MARKER_LINE.test(last)) last = "";
    if (/^\s*\|/.test(last)) last = "";
    const complete = lines.slice(0, -1);
    const header = complete.length - 1;
    const isRow = (line: string | undefined) => line !== undefined && /^\s*\|/.test(line);
    if (header >= 0 && isRow(complete[header]) && !isRow(complete[header - 1])) lines[header] = "";
    else if (header > 0 && /^\s*\|?\s*:?-/.test(complete[header]!) && isRow(complete[header - 1])) {
      // A separator row still being typed holds its header back too.
      if (!/-\s*\|/.test(complete[header]!)) lines[header] = lines[header - 1] = "";
    }
    // A `[` is held only while it can still become a link (or an image): `[text`, `[text]` at
    // the end, `[text](url` before its `)`. `[^1] more` and `[x] text` can no longer.
    const open = last.lastIndexOf("[");
    if (open >= 0 && /^\[[^\]]*(?:\](?:\([^)]*)?)?$/.test(last.slice(open)))
      last = last.slice(0, open > 0 && last[open - 1] === "!" ? open - 1 : open);
  }
  lines[lines.length - 1] = last;
  let text = lines.join("\n");
  if (fence > 0) return text;
  const paragraph = (value: string) => value.slice(value.lastIndexOf("\n\n") + 1).replace(RULE_LINE, "");
  const odd = (pattern: RegExp, value: string) => (value.match(pattern)?.length ?? 0) % 2 === 1;
  if (odd(/\*\*/g, paragraph(text))) {
    const stripped = text.replace(/\*{1,2}\s*$/, "");
    text = odd(/\*\*/g, paragraph(stripped)) ? `${stripped}**` : stripped;
  }
  if (odd(/`/g, paragraph(text).replace(/\*\*/g, ""))) {
    const stripped = text.replace(/`\s*$/, "");
    text = odd(/`/g, paragraph(stripped)) ? `${stripped}\`` : stripped;
  }
  // A lone `*` or `_` at the very end opens bold, italic or a word (`2*3`, `snake_case`): its next
  // character tells which.
  text = text.replace(/(?<![*_\\])[*_]$/, "");
  const end = text.lastIndexOf("\n") + 1;
  return text.slice(0, end) + closedItalic(text.slice(end));
}
