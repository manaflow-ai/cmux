import { appHref, safeHref } from "../replyHref";

// The cmux deeplinks in a text: a cmux app link (`cmux://workspace/ws_…`, `cmux-nightly://agent/…`,
// in any build's scheme) or a web deeplink (`https://cmux.com/deeplink/…`). The draft finds them
// (deeplinkTokens.ts) to draw a known one as its chip, and a sent prompt opens them
// (conversation/PromptText.tsx). No editor code here, so the transcript can read it without
// loading the editor.

export type Deeplink = { start: number; end: number; href: string };

// A link starts at a word boundary (not inside a path or another URL) and runs to the first space
// or bracket; trailing sentence punctuation stays text, as chips/paths.ts reads a URL.
const DEEPLINK =
  /(?<![\w/.:~@+-])(?:cmux(?:-[a-z0-9-]+)?:\/\/|https:\/\/(?:www\.)?cmux\.com(?:\/[a-z]{2}(?:-[A-Z]{2})?)?\/deeplink\/)[^\s<>()"'`[\]]*/g;

/// Where the run of link characters that holds `index` starts: the character after the last space or
/// bracket before it (the characters DEEPLINK ends a link at).
const RUN_END = /[\s<>()"'`[\]]/;
function runStart(text: string, index: number): number {
  let at = index;
  while (at > 0 && !RUN_END.test(text[at - 1]!)) at -= 1;
  return at;
}

/// The cmux deeplinks in `text`, each one a link the pane opens (`appHref` or `safeHref`). One inside
/// another URL (`https://example.com/?next=cmux://session/s1`) is that URL's, never a link of its own
/// (review of #38166, F2): the page draws the whole URL, as it did before the chips.
export function deeplinks(text: string): Deeplink[] {
  if (!text.includes("://")) return [];
  const out: Deeplink[] = [];
  for (const match of text.matchAll(DEEPLINK)) {
    const from = runStart(text, match.index!);
    if (from < match.index! && text.slice(from, match.index!).includes("://")) continue;
    const value = match[0].replace(/[.,;:!?*_]+$/, "");
    const href = value.startsWith("https:") ? safeHref(value) && value : appHref(value);
    if (href) out.push({ start: match.index!, end: match.index! + value.length, href });
  }
  return out;
}
