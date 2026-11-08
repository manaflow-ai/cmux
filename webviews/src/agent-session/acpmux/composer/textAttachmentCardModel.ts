import { PASTE_LINE_BREAK, pasteLines } from "../conversation/promptCollapse";
import type { Translate } from "../i18n";

/// The most lines a card can show (the strip's 64 px card shows three, the prompt's 48 px two).
export const TEXT_CARD_LINES = 4;
/// The most characters of one line the card keeps; the card is narrower than this at 11 px.
export const TEXT_CARD_LINE_CHARS = 120;
/// The same for a card that wraps its lines (a paste's): enough of one paragraph to fill every
/// line the card shows, wrapped at its width.
export const TEXT_CARD_WRAP_CHARS = 480;

/// The first `lines` lines of `text` as the card draws them: leading blank lines skipped, each line
/// cut to `chars` and its trailing space dropped. Reads only as far as it needs, so a paste of a
/// megabyte costs the card no more than a short one.
export function textPreview(text: string, lines = TEXT_CARD_LINES, chars = TEXT_CARD_LINE_CHARS): string {
  const out: string[] = [];
  let at = 0;
  const breaks = new RegExp(PASTE_LINE_BREAK);
  while (at < text.length && out.length < lines) {
    breaks.lastIndex = at;
    const found = breaks.exec(text);
    const stop = found ? found.index : text.length;
    const line = text.slice(at, Math.min(stop, at + chars)).replace(/\s+$/, "");
    if (out.length || line.trim()) out.push(line);
    at = found ? stop + found[0].length : text.length;
  }
  return out.join("\n");
}

/// A paste's size as its label says it: its lines when it has more than one (one long paragraph is
/// "1 line" and says nothing), then its characters, in the reader's language ("42 lines · 1.8K
/// characters").
export function pastedSize(t: Translate, language: string, text: string): string {
  const lines = pasteLines(text);
  const chars = t("composer.pastedChars", {
    count: new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(text.length),
  });
  if (lines < 2) return chars;
  return `${t("transcript.pastedLines", { n: lines, count: new Intl.NumberFormat(language).format(lines) })} · ${chars}`;
}
