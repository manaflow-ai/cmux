// Limits on what a reply can make the pane highlight (code cards, CodeBlock.tsx). Grammar regexes
// can backtrack badly on hostile input, and highlighting is the costliest thing a reply asks of
// the pane, so a fence over these limits draws as plain monospace text, and a line is tokenized
// only up to MAX_TOKENIZED_LINE characters (the rest of it draws unhighlighted).

/// The longest fence, in characters, that is highlighted.
export const MAX_HIGHLIGHT_CHARS = 200_000;
/// The most lines a highlighted fence may have.
export const MAX_HIGHLIGHT_LINES = 2_000;
/// The longest line Shiki tokenizes (Pierre's `tokenizeMaxLineLength`).
export const MAX_TOKENIZED_LINE = 2_000;

/// Whether `code` is small enough to highlight.
export function highlightsCode(code: string): boolean {
  if (code.length > MAX_HIGHLIGHT_CHARS) return false;
  let lines = 1;
  for (let at = code.indexOf("\n"); at >= 0; at = code.indexOf("\n", at + 1)) {
    if (++lines > MAX_HIGHLIGHT_LINES) return false;
  }
  return true;
}
