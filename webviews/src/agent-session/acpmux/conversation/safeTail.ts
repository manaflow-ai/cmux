// What of a streaming reply's last block may draw now (plans/cmux-next/acp-streaming.md
// "Streaming-safe tail", from hq-48's prototype). Half-written Markdown would draw wrongly and
// then flip when the rest arrives: a fence opener reads `t`, `ty` before `TypeScript`, a table
// header draws as a paragraph of pipes until its separator row, a link or image shows its brackets, and a
// bold or code run draws its markers until the closer. So the tail holds back a fence opener until
// its newline, a table header until its separator row and each row until its newline, a link
// until its `)`, and a marker typed at the very end; an open `**` or backtick run is closed for
// now, so it is styled from its first character. Nothing changes inside an open fence.
// Math draws only once it is whole: a display equation (`$$`, `\[`) is held back from its opener
// until its closer, and an inline `$…$`, `$$…$$` or `\(…\)` from its opening delimiter, so half
// an equation never draws as source and then turns into math.

const FENCE = /^\s*```/;
/// Complete inline math on one line (Markdown.tsx's INLINE_RE and normalizeMath's `\(…\)`).
const INLINE_MATH =
  /`[^`]*`|\\[\\$]|\$\$[^$\n]+?\$\$|(?<![\\$])\$(?=[^\s$])(?:\\.|[^$\\\n`])*?[^\s\\`]\$(?!\d)|\\\(.+?\\\)/g;
/// An opener with no closer yet: `$$`, `\(`, `$` before something that is not a digit or
/// space (`$5` is a price), or a backslash at the very end (`\(`, `\[` or `\$` arriving).
const OPEN_MATH = /\$\$|\\\(|(?<!\\)\$(?=[^\s\d$]|$)|\\$/;

/// The index of the line that opens a display equation not yet closed (-1 when none), and
/// whether the last line closes one (it is the equation's, not inline math).
function openDisplay(lines: string[]): { open: number; closesLast: boolean } {
  let fence = false;
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
    if (FENCE.test(line)) fence = !fence;
    if (fence) continue;
    const dollars = line.match(/^\s*\$\$(.*)$/);
    if (dollars && !dollars[1]!.includes("$$")) [open, closer] = [index, /\$\$/];
    else if (/^\s*\\\[/.test(line) && !/\\\]\s*$/.test(line)) [open, closer] = [index, /\\\]\s*$/];
  }
  return { open, closesLast: false };
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
  let fence = false;
  for (let index = 0; index < lines.length - 1; index += 1) if (FENCE.test(lines[index]!)) fence = !fence;
  let last = lines.at(-1) ?? "";
  if (/^\s*`{1,3}[^`]*$/.test(last)) last = "";
  else if (!fence) {
    if (!display.closesLast) last = closedMath(last);
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
  if (fence) return text;
  const paragraph = (value: string) => value.slice(value.lastIndexOf("\n\n") + 1);
  const odd = (pattern: RegExp, value: string) => (value.match(pattern)?.length ?? 0) % 2 === 1;
  if (odd(/\*\*/g, paragraph(text))) {
    const stripped = text.replace(/\*{1,2}\s*$/, "");
    text = odd(/\*\*/g, paragraph(stripped)) ? `${stripped}**` : stripped;
  }
  if (odd(/`/g, paragraph(text).replace(/\*\*/g, ""))) {
    const stripped = text.replace(/`\s*$/, "");
    text = odd(/`/g, paragraph(stripped)) ? `${stripped}\`` : stripped;
  }
  return text;
}
