// Milkdown writes a blank line (an empty paragraph) as a `<br />` line in its markdown. Before the
// composer copied plain text, that markdown was what Copy put on the clipboard, so a prompt with a
// blank line pasted back (and sent) held a literal `<br />` line (Leo 2026-10-21). Wherever such
// text comes back (a paste, a sent prompt's bubble and its Copy), a line that is only a `<br>` tag
// is a blank line. A `<br>` inside a line (source code, a sentence) stays as written.

/** `text` with Return-Newline as a newline, each line that is only a `<br>` tag as a blank line, and Milkdown's placeholder (a
 * `<br />` line between blank lines) as the one blank line it stood for. */
export function withoutBreakTags(text: string): string {
  const lines = text.replace(/\r\n?/g, "\n");
  if (!/<br/i.test(lines)) return lines;
  return lines
    .replace(/\n\n<br\s*\/?>(?=\n\n)/gi, "")
    .replace(/^<br\s*\/?>\n\n/i, "\n")
    .replace(/\n\n<br\s*\/?>\n?$/i, "\n")
    .replace(/^<br\s*\/?>$/gim, "");
}
