// SCROLLBARS-THIN (was SCROLLBARS-FOLLOW-MACOS): every scrollbar in cmux is thin and shows only
// while its element scrolls, whatever the macOS "Show scroll bars" setting (Leo 2026-10-12: "never a
// permanent gray track").
//
// Native page scrolling (`overflow: auto`) draws WebKit's overlay scrollers for "Automatically" and
// "When scrolling", which already look that way. For "Always" WebKit draws a legacy bar with a gray
// track; the host tells the page (the shared web theme, WebTheme.swift, sets
// `data-scrollers="overlay" | "legacy"` on <html>) and `SCROLLER_ROOT_CSS` below draws a thin themed
// thumb instead, on no track, shown while the element scrolls (`data-cmux-scrolling`, set by
// `installScrollingMarks` or `markScrolling`) or while it is dragged. That rule is the only
// scrollbar styling: pages never style the scrollbar themselves (`scrollbar-width`,
// `scrollbar-color`, `::-webkit-scrollbar`) and never use `overflow: scroll`;
// scripts/cmux-next/check-scrollbars.sh enforces that.
//
// Libraries that draw their own scrollers (Monaco; the @pierre/diffs code rows and the
// @pierre/trees list show theirs on hover) follow the same rule: hidden at rest and while the
// pointer only hovers, shown while the element scrolls.

export type ScrollerStyle = "overlay" | "legacy";

/** The attribute a scrolling element carries until `SCROLLING_HIDE_MS` after its last scroll. */
export const SCROLLING_ATTRIBUTE = "data-cmux-scrolling";
/** How long a scroller stays after the last scroll step (AppKit's overlay fade starts about here). */
export const SCROLLING_HIDE_MS = 800;

/** The host's answer; a page without a host (tests, the dev server) gets overlay. */
export function scrollerStyle(root: Element | null = globalThis.document?.documentElement ?? null): ScrollerStyle {
  return root?.getAttribute("data-scrollers") === "legacy" ? "legacy" : "overlay";
}

/** Calls `onChange` when the host changes the style. Returns the stop function. */
export function onScrollerStyleChange(onChange: (style: ScrollerStyle) => void, root: Element): () => void {
  const view = root.ownerDocument.defaultView;
  if (!view?.MutationObserver) return () => {};
  let last = scrollerStyle(root);
  const observer = new view.MutationObserver(() => {
    const next = scrollerStyle(root);
    if (next === last) return;
    last = next;
    onChange(next);
  });
  observer.observe(root, { attributes: true, attributeFilter: ["data-scrollers"] });
  return () => observer.disconnect();
}

export interface ScrollTimers {
  set(callback: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

const defaultTimers: ScrollTimers = {
  set: (callback, ms) => setTimeout(callback, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

const pending = new WeakMap<Element, unknown>();

/** Marks `element` as scrolling now; the mark clears `SCROLLING_HIDE_MS` after the last call. */
export function markScrolling(element: Element, timers: ScrollTimers = defaultTimers): void {
  const previous = pending.get(element);
  if (previous !== undefined) timers.clear(previous);
  element.setAttribute(SCROLLING_ATTRIBUTE, "");
  pending.set(
    element,
    timers.set(() => {
      pending.delete(element);
      element.removeAttribute(SCROLLING_ATTRIBUTE);
    }, SCROLLING_HIDE_MS),
  );
}

function scrolls(element: Element, dx: number, dy: number): boolean {
  const vertical = dy !== 0 && element.scrollHeight > element.clientHeight;
  const horizontal = dx !== 0 && element.scrollWidth > element.clientWidth;
  if (!vertical && !horizontal) return false;
  const view = element.ownerDocument.defaultView;
  const style = view?.getComputedStyle(element);
  if (!style) return false;
  const can = (value: string) => value === "auto" || value === "scroll" || value === "overlay";
  return (vertical && can(style.overflowY)) || (horizontal && can(style.overflowX));
}

/**
 * The element a wheel event scrolls: the first element on its composed path (shadow roots
 * included, so library code rows count) that overflows on the wheel's axis.
 */
export function wheelTarget(event: Pick<WheelEvent, "composedPath" | "deltaX" | "deltaY">): Element | null {
  for (const node of event.composedPath()) {
    const element = node as Element;
    if (typeof element.getAttribute !== "function" || typeof element.scrollHeight !== "number") continue;
    if (scrolls(element, event.deltaX, event.deltaY)) return element;
  }
  return null;
}

const installed = new WeakSet<Document>();

/**
 * Marks the element each wheel event scrolls, and every element that scrolls however it does
 * (keys, a click on the track, find, code), the page's own scroller as <html> (passive capture
 * listeners, one each per document: scroll events do not bubble and do not cross shadow roots,
 * wheel events do). Idempotent.
 */
export function installScrollingMarks(document: Document, timers: ScrollTimers = defaultTimers): void {
  if (installed.has(document)) return;
  installed.add(document);
  document.addEventListener(
    "wheel",
    (event) => {
      const target = wheelTarget(event as WheelEvent);
      if (target) markScrolling(target, timers);
    },
    { capture: true, passive: true },
  );
  document.addEventListener(
    "scroll",
    (event) => {
      const target = event.target;
      if (target === document) markScrolling(document.documentElement, timers);
      else if (target && "setAttribute" in target) markScrolling(target as Element, timers);
    },
    { capture: true, passive: true },
  );
}

/**
 * Monaco's scrollbar options for a style. Monaco reveals its slider while the pointer is over the
 * editor; `MONACO_SCROLLER_CSS` hides it then for overlay. Its overview ruler border and cursor
 * mark read as a scrollbar track at rest, so both are off.
 */
export function monacoScrollerOptions(_style: ScrollerStyle): {
  scrollbar: { vertical: "auto" | "visible"; horizontal: "auto" | "visible"; useShadows: boolean };
  overviewRulerBorder: boolean;
  hideCursorInOverviewRuler: boolean;
} {
  // "Always" too: no bar at rest (SCROLLBARS-THIN).
  return {
    scrollbar: { vertical: "auto", horizontal: "auto", useShadows: false },
    overviewRulerBorder: false,
    hideCursorInOverviewRuler: true,
  };
}

/**
 * Monaco's slider shows only while the editor scrolls (the page marks the editor's node
 * with `markScrolling` on every scroll change), while it is dragged, or while the pointer is on
 * the scrollbar itself, where AppKit reveals an overlay scroller too.
 */
export const MONACO_SCROLLER_CSS = `
.monaco-editor:not([${SCROLLING_ATTRIBUTE}]) .monaco-scrollable-element > .scrollbar:not(:hover) > .slider:not(.active) {
  opacity: 0;
  transition: opacity var(--cmux-motion-large);
}
`;

/**
 * Appended to every @pierre/diffs `unsafeCSS`. The library's code rows have a custom horizontal
 * scrollbar whose thumb shows on hover; here it shows only while the row scrolls
 * (`--cmux-scroller-rest` is unset: nothing at rest).
 */
export const PIERRE_DIFFS_SCROLLER_CSS = `
[data-code]::-webkit-scrollbar-thumb,
:is([data-diff], [data-file]):hover [data-code]::-webkit-scrollbar-thumb {
  background-color: var(--cmux-scroller-rest, transparent);
}
[data-code][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  background-color: var(--diffs-bg-context);
}
`;

/** Appended to every @pierre/trees `unsafeCSS`: the same rule for the tree's list. */
export const PIERRE_TREES_SCROLLER_CSS = `
[data-file-tree-virtualized-scroll='true'],
[data-file-tree-virtualized-scroll='true']:hover {
  --trees-scrollbar-thumb-current: var(--cmux-scroller-rest, transparent);
}
[data-file-tree-virtualized-scroll='true'][${SCROLLING_ATTRIBUTE}] {
  --trees-scrollbar-thumb-current: var(--trees-scrollbar-thumb);
}
`;

/**
 * The one scrollbar style, for "Always" (WebKit draws overlay scrollers otherwise): a thin thumb in
 * the theme's text color (`--cmux-scroller-thumb`), on no track, hidden at rest and shown while the
 * element scrolls, while its thumb is dragged or under the pointer (where AppKit reveals an overlay
 * scroller too).
 */
export const SCROLLER_ROOT_CSS = `
:root {
  --cmux-scroller-size: 8px;
  --cmux-scroller-thumb: color-mix(in srgb, currentColor 38%, transparent);
}
html[data-scrollers="legacy"] ::-webkit-scrollbar {
  width: var(--cmux-scroller-size);
  height: var(--cmux-scroller-size);
  background: transparent;
}
html[data-scrollers="legacy"] ::-webkit-scrollbar-track,
html[data-scrollers="legacy"] ::-webkit-scrollbar-corner {
  background: transparent;
}
html[data-scrollers="legacy"] ::-webkit-scrollbar-thumb {
  border: 2px solid transparent;
  border-radius: var(--cmux-scroller-size);
  background: transparent padding-box;
}
html[data-scrollers="legacy"] [${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${SCROLLING_ATTRIBUTE}] > body::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"] ::-webkit-scrollbar-thumb:hover,
html[data-scrollers="legacy"] ::-webkit-scrollbar-thumb:active {
  background-color: var(--cmux-scroller-thumb);
}
`;

/** The attribute of a scrollable card (hover cards, the update card's popover): the shared
    super-thin card scroller and the edge fades below. Add it to the card's scroll container and
    call `installScrollEdges` on it. */
export const CARD_SCROLL_ATTRIBUTE = "data-cmux-card-scroll";
/** On a card scroller while content lies above its top edge or below its bottom edge. */
export const MORE_ABOVE_ATTRIBUTE = "data-cmux-more-above";
export const MORE_BELOW_ATTRIBUTE = "data-cmux-more-below";

/** Which edges of a scroller have content past them (a half pixel of slack for zoomed pages). */
export function scrollEdges(box: { scrollTop: number; clientHeight: number; scrollHeight: number }): {
  above: boolean;
  below: boolean;
} {
  return { above: box.scrollTop > 0.5, below: box.scrollTop + box.clientHeight < box.scrollHeight - 0.5 };
}

/**
 * Keeps `MORE_ABOVE_ATTRIBUTE` and `MORE_BELOW_ATTRIBUTE` on `element` current: now, on every
 * scroll and whenever it or its content changes size. The fades they turn on have no transition:
 * they show and hide at once, so Reduce Motion and the Motion setting have nothing to still.
 * Returns the stop function.
 */
export function installScrollEdges(element: HTMLElement): () => void {
  const update = () => {
    const edges = scrollEdges(element);
    element.toggleAttribute(MORE_ABOVE_ATTRIBUTE, edges.above);
    element.toggleAttribute(MORE_BELOW_ATTRIBUTE, edges.below);
  };
  update();
  element.addEventListener("scroll", update, { passive: true });
  const Observer = element.ownerDocument.defaultView?.ResizeObserver;
  const observer = Observer ? new Observer(update) : null;
  if (observer) {
    observer.observe(element);
    for (const child of element.children) observer.observe(child);
  }
  return () => {
    element.removeEventListener("scroll", update);
    observer?.disconnect();
  };
}

/**
 * The card scroller (every scrollable card, 2026-10-20): a 3 px thumb on no track, hidden at rest
 * and shown while the card scrolls or its thumb is under the pointer, whatever the macOS setting
 * (the native twin is CardScroller.swift). An edge with more content past it fades out over
 * `--cmux-card-fade`; the scroller's own column never fades.
 */
export const CARD_SCROLLER_CSS = `
[${CARD_SCROLL_ATTRIBUTE}] {
  --cmux-card-fade: 28px;
  --cmux-card-scroller: 7px;
  overflow-y: auto;
  overscroll-behavior: contain;
}
[${CARD_SCROLL_ATTRIBUTE}]::-webkit-scrollbar { width: var(--cmux-card-scroller); height: var(--cmux-card-scroller); background: transparent; }
[${CARD_SCROLL_ATTRIBUTE}]::-webkit-scrollbar-track,
[${CARD_SCROLL_ATTRIBUTE}]::-webkit-scrollbar-corner { background: transparent; }
[${CARD_SCROLL_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  border: 2px solid transparent;
  border-radius: var(--cmux-card-scroller);
  background: transparent padding-box;
}
[${CARD_SCROLL_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb,
[${CARD_SCROLL_ATTRIBUTE}]::-webkit-scrollbar-thumb:hover,
[${CARD_SCROLL_ATTRIBUTE}]::-webkit-scrollbar-thumb:active {
  background-color: var(--cmux-scroller-thumb);
}
[${CARD_SCROLL_ATTRIBUTE}][${MORE_BELOW_ATTRIBUTE}] {
  --cmux-card-mask: linear-gradient(to bottom, #000 calc(100% - var(--cmux-card-fade)), transparent);
}
[${CARD_SCROLL_ATTRIBUTE}][${MORE_ABOVE_ATTRIBUTE}] {
  --cmux-card-mask: linear-gradient(to bottom, transparent, #000 var(--cmux-card-fade));
}
[${CARD_SCROLL_ATTRIBUTE}][${MORE_ABOVE_ATTRIBUTE}][${MORE_BELOW_ATTRIBUTE}] {
  --cmux-card-mask: linear-gradient(to bottom, transparent, #000 var(--cmux-card-fade), #000 calc(100% - var(--cmux-card-fade)), transparent);
}
[${CARD_SCROLL_ATTRIBUTE}]:is([${MORE_ABOVE_ATTRIBUTE}], [${MORE_BELOW_ATTRIBUTE}]) {
  -webkit-mask: var(--cmux-card-mask) left top / calc(100% - var(--cmux-card-scroller)) 100% no-repeat,
    linear-gradient(#000, #000) right top / var(--cmux-card-scroller) 100% no-repeat;
  mask: var(--cmux-card-mask) left top / calc(100% - var(--cmux-card-scroller)) 100% no-repeat,
    linear-gradient(#000, #000) right top / var(--cmux-card-scroller) 100% no-repeat;
}
`;

/** Installs the root rules, the card scroller, the Monaco rule and the wheel marks once per document. */
export function installScrollers(document: Document, timers: ScrollTimers = defaultTimers): void {
  if (!document.getElementById("cmux-scrollers")) {
    const style = document.createElement("style");
    style.id = "cmux-scrollers";
    style.textContent = SCROLLER_ROOT_CSS + CARD_SCROLLER_CSS + MONACO_SCROLLER_CSS;
    (document.head ?? document.documentElement).appendChild(style);
  }
  installScrollingMarks(document, timers);
}
