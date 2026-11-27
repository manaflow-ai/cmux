// The fence rule Markdown.tsx parses by, for the streaming helpers (safeTail.ts,
// incrementalMarkdown.ts) that follow a reply's fences line by line: a fence opens on three or more
// backticks and an info string without backticks, and closes on a line of nothing but at least as
// many. A reply that quotes Markdown opens with four to show its own three, so a line of three
// inside it is code, and "```x``` y" opens nothing.

const OPENER = /^\s*(`{3,})([^\s`]*)[^`]*$/;

/** The fence after `line`: `open` is the length of the fence the line starts in (0 outside one),
 * and the result is the length of the fence it leaves open (0 outside one). */
export function fenceStep(open: number, line: string): number {
  if (open === 0) return OPENER.exec(line)?.[1]!.length ?? 0;
  return new RegExp(`^\\s*\`{${open},}\\s*$`).test(line) ? 0 : open;
}
