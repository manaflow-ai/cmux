import type { AcpmuxRow } from "../model";

/// The longest gist a row carries, in characters.
export const ROW_GIST_MAX = 120;
/// How much of a row's text is read for its gist: a long single-line message costs no more.
const SCAN = 1_000;

/// A transcript row's first line of text, as the row's `aria-description`: an AX client (VoiceOver, an
/// agent driving the app through the accessibility tree) finds a message by its words, not only by
/// its speaker. Markdown's block markers (a heading's `#`, a quote's `>`, a list's bullet, a code
/// fence line) are left out; at most ROW_GIST_MAX characters. Nothing is drawn from it.
export function rowGist(row: Pick<AcpmuxRow, "text">): string | undefined {
  const text = row.text;
  if (!text) return undefined;
  for (const raw of text.slice(0, SCAN).split("\n")) {
    if (/^\s*(```|~~~)/.test(raw)) continue;
    const line = raw
      .replace(/^\s*(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?)/, "")
      .replace(/\s+/g, " ")
      .trim();
    if (!line) continue;
    return line.length > ROW_GIST_MAX ? `${line.slice(0, ROW_GIST_MAX - 1).trimEnd()}…` : line;
  }
  return undefined;
}
