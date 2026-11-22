// Whether the element under the fingers keeps a horizontal gesture for itself, so a two-finger
// swipe there scrolls or edits instead of going Back / Forward. The same walk as the browser tabs'
// page probe (BrowserSwipeProbe.swift), run in the page itself, with no round trip:
// - every horizontal scroller from the element up to the root, through open shadow roots, that can
//   still scroll that way (right-to-left scrollers count from their right edge), and the document;
// - a horizontal scroller with `overscroll-behavior-x` other than `auto` (canvas apps, maps), at
//   either edge. A box whose content fits its width does not count, nor, unlike the browser
//   tabs' probe, does the root: every app page sets `overscroll-behavior: none` on
//   the root as its own anti-bounce rule (shared/desktop.css), so it says nothing about the gesture;
// - an editable element (a field, the composer, a content-editable, a textbox role);
// - text inside a selection that is not collapsed;
// - a page that took horizontal wheels itself (`preventDefault`) in the last 600 ms (a carousel).
import type { SwipeDirection } from "./gesture";

/** How long a page's own `preventDefault` of a horizontal wheel keeps swipes off. */
export const PREVENTED_WINDOW_MS = 600;

const EDITABLE = "input, textarea, select, [contenteditable]:not([contenteditable='false']), [role='textbox']";

export interface ProbeTimes {
  now: number;
  /** When a horizontal wheel last ended `defaultPrevented` by page code. */
  preventedAt: number;
}

function up(el: Element): Element | null {
  if (el.parentElement) return el.parentElement;
  // Out of an open shadow root: on to its host.
  return (el.getRootNode() as Node & { host?: Element }).host ?? null;
}

/** Whether a scroller at `position` of `max` has room toward the swipe's side. */
function hasRoom(direction: SwipeDirection, position: number, max: number): boolean {
  return direction === "back" ? position > 1 : position < max - 1;
}

function scrolls(el: Element, style: CSSStyleDeclaration, direction: SwipeDirection): boolean {
  const max = el.scrollWidth - el.clientWidth;
  if (max <= 1) return false;
  return hasRoom(direction, style.direction === "rtl" ? max + el.scrollLeft : el.scrollLeft, max);
}

function inSelection(target: Element, doc: Document): boolean {
  const selection = doc.getSelection();
  if (!selection || selection.isCollapsed) return false;
  for (let i = 0; i < selection.rangeCount; i += 1) {
    if (selection.getRangeAt(i).intersectsNode(target)) return true;
  }
  return false;
}

export function keepsSwipe(target: Element | null, direction: SwipeDirection, times: ProbeTimes): boolean {
  if (times.now - times.preventedAt < PREVENTED_WINDOW_MS) return true;
  if (!target) return false;
  const doc = target.ownerDocument;
  const view = doc.defaultView;
  if (!view) return false;
  if (target.closest(EDITABLE) || inSelection(target, doc)) return true;
  for (let el: Element | null = target; el && el !== doc.documentElement && el !== doc.body; el = up(el)) {
    if (el.matches(EDITABLE)) return true;
    const style = view.getComputedStyle(el);
    if (style.overflowX !== "auto" && style.overflowX !== "scroll") continue;
    // Only a box that scrolls sideways at all: a vertical list's `overscroll-behavior: contain`
    // (popovers, the Home dock) stops scroll chaining and says nothing about a horizontal swipe.
    if (el.scrollWidth - el.clientWidth <= 1) continue;
    const overscroll = style.getPropertyValue("overscroll-behavior-x");
    if (overscroll && overscroll !== "auto") return true;
    if (scrolls(el, style, direction)) return true;
  }
  const hidden = (el: Element | null) => !!el && ["hidden", "clip"].includes(view.getComputedStyle(el).overflowX);
  const root = doc.scrollingElement ?? doc.documentElement;
  if (hidden(doc.documentElement) || hidden(doc.body)) return false;
  return scrolls(root, view.getComputedStyle(root), direction);
}
