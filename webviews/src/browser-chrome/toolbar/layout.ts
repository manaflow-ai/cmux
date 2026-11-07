// What the toolbar page tells the host about where its controls are (`layout`), and the field's
// pointer geometry (the character and the word under a press). Pure, with measuring injected.
import type { TextRange } from "../omnibox/types";
import type { WireRect } from "./wire";

export type LayoutReport = {
  rects: Record<string, WireRect>;
  showsForward: boolean;
  visiblePinned: number;
  collapse: number;
};

/** A rect in whole-ish CSS px (quarter px), so subpixel jitter sends nothing. */
export function wireRect(x: number, y: number, width: number, height: number): WireRect {
  const q = (value: number) => Math.round(value * 4) / 4;
  return [q(x), q(y), q(width), q(height)];
}

function rectsEqual(a: Record<string, WireRect>, b: Record<string, WireRect>): boolean {
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => {
    const other = b[key];
    const rect = a[key];
    return other !== undefined && rect.every((value, index) => value === other[index]);
  });
}

/** Whether `next` differs from what the host last got (null: nothing sent yet). */
export function layoutChanged(previous: LayoutReport | null, next: LayoutReport): boolean {
  return (
    previous === null ||
    previous.showsForward !== next.showsForward ||
    previous.visiblePinned !== next.visiblePinned ||
    previous.collapse !== next.collapse ||
    !rectsEqual(previous.rects, next.rects)
  );
}

/**
 * The caret index nearest `x` (px from the text's start, scroll included) in `text`, with
 * `measure(prefix)` the width of a prefix: a binary search, so a long URL costs log(n) measures.
 */
export function indexAtX(text: string, x: number, measure: (prefix: string) => number): number {
  if (x <= 0 || text === "") return 0;
  let low = 0;
  let high = text.length;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (measure(text.slice(0, mid)) <= x) low = mid;
    else high = mid - 1;
  }
  if (low >= text.length) return text.length;
  // Past the middle of the next character: the caret goes after it.
  const before = measure(text.slice(0, low));
  const after = measure(text.slice(0, low + 1));
  return x - before > (after - before) / 2 ? low + 1 : low;
}

/** A word's characters: letters, digits, marks and `_`; dots, slashes and the rest separate words. */
const WORD = /[\p{L}\p{N}\p{M}_]/u;

/**
 * The word at caret `index` (NSTextView's word selection), where a URL's dots and slashes separate
 * words as in Chromium's omnibox: the run of word characters around it (one before the caret
 * counts), else the empty range at the caret; null for empty text.
 */
export function wordRangeAt(text: string, index: number): TextRange | null {
  if (text === "") return null;
  const at = Math.min(Math.max(index, 0), text.length);
  let start = at;
  let end = at;
  while (start > 0 && WORD.test(text[start - 1])) start--;
  while (end < text.length && WORD.test(text[end])) end++;
  return { location: start, length: end - start };
}
