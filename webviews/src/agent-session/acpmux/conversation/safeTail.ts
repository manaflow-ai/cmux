// What of a streaming reply's last block may draw now (plans/cmux-next/acp-streaming.md
// "Streaming-safe tail", from hq-48's prototype). Half-written Markdown would draw wrongly and
// then flip when the rest arrives: a fence opener reads `t`, `ty` before `TypeScript`, a table
// header draws as a paragraph of pipes until its separator row, a link shows its brackets, and a
// bold or code run draws its markers until the closer. So the tail holds back a fence opener until
// its newline, a table header until its separator row and each row until its newline, a link
// until its `)`, and a marker typed at the very end; an open `**` or backtick run is closed for
// now, so it is styled from its first character. Nothing changes inside an open fence.

const FENCE = /^\s*```/;

export function safeTail(tail: string): string {
  const lines = tail.split("\n");
  let fence = false;
  for (let index = 0; index < lines.length - 1; index += 1) if (FENCE.test(lines[index]!)) fence = !fence;
  let last = lines.at(-1) ?? "";
  if (/^\s*`{1,3}[^`]*$/.test(last)) last = "";
  else if (!fence) {
    if (/^\s*\|/.test(last)) last = "";
    const complete = lines.slice(0, -1);
    const header = complete.length - 1;
    const isRow = (line: string | undefined) => line !== undefined && /^\s*\|/.test(line);
    if (header >= 0 && isRow(complete[header]) && !isRow(complete[header - 1])) lines[header] = "";
    else if (header > 0 && /^\s*\|?\s*:?-/.test(complete[header]!) && isRow(complete[header - 1])) {
      // A separator row still being typed holds its header back too.
      if (!/-\s*\|/.test(complete[header]!)) lines[header] = lines[header - 1] = "";
    }
    const open = last.lastIndexOf("[");
    if (open >= 0 && !/\]\([^)]*\)/.test(last.slice(open))) last = last.slice(0, open);
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
