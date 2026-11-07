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

const isHigh = (unit: number) => unit >= 0xd800 && unit <= 0xdbff;
const isLow = (unit: number) => unit >= 0xdc00 && unit <= 0xdfff;

/** Whether UTF-16 index `index` falls inside a surrogate pair (an emoji, an astral letter). */
function splitsPair(text: string, index: number): boolean {
  return index > 0 && index < text.length && isLow(text.charCodeAt(index)) && isHigh(text.charCodeAt(index - 1));
}

/** The UTF-16 length of the character starting at `index`: 2 for a surrogate pair, else 1. */
const unitsAt = (text: string, index: number) => (splitsPair(text, index + 1) ? 2 : 1);

/** The UTF-16 length of the character ending at `index`. */
const unitsBefore = (text: string, index: number) => (splitsPair(text, index - 1) ? 2 : 1);

/**
 * The caret index nearest `x` (px from the text's start, scroll included) in `text`, with
 * `measure(prefix)` the width of a prefix: a binary search, so a long URL costs log(n) measures.
 * Indices are UTF-16 (the input's selection), never inside a surrogate pair.
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
  if (splitsPair(text, low)) low--;
  if (low >= text.length) return text.length;
  // Past the middle of the next character: the caret goes after it.
  const next = low + unitsAt(text, low);
  const before = measure(text.slice(0, low));
  const after = measure(text.slice(0, next));
  return x - before > (after - before) / 2 ? next : low;
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
  let at = Math.min(Math.max(index, 0), text.length);
  if (splitsPair(text, at)) at--;
  let start = at;
  let end = at;
  while (start > 0 && WORD.test(text.slice(start - unitsBefore(text, start), start))) start -= unitsBefore(text, start);
  while (end < text.length && WORD.test(text.slice(end, end + unitsAt(text, end)))) end += unitsAt(text, end);
  return { location: start, length: end - start };
}
