/**
 * `text.slice(0, end)` that never ends inside a surrogate pair: when `end` falls between an emoji's
 * two UTF-16 units the cut moves back before it, so the clipped text never carries a lone high
 * surrogate (drawn as a replacement box, or copied as one). Callers add their own ellipsis.
 */
export function sliceWhole(text: string, end: number): string {
  const cut = Math.min(Math.max(end, 0), text.length);
  const last = text.charCodeAt(cut - 1);
  const next = text.charCodeAt(cut);
  const splits = last >= 0xd800 && last <= 0xdbff && next >= 0xdc00 && next <= 0xdfff;
  return text.slice(0, splits ? cut - 1 : cut);
}

/** `text.slice(-count)` that never starts on a surrogate pair's second unit. */
export function sliceWholeEnd(text: string, count: number): string {
  const start = Math.max(text.length - Math.max(count, 0), 0);
  const first = text.charCodeAt(start);
  const before = text.charCodeAt(start - 1);
  const splits = first >= 0xdc00 && first <= 0xdfff && before >= 0xd800 && before <= 0xdbff;
  return text.slice(splits ? start + 1 : start);
}
