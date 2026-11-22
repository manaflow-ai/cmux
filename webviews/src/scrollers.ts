// SCROLLBARS-FOLLOW-MACOS: every page follows the macOS "Show scroll bars" setting.
//
// Native page scrolling (`overflow: auto`) already does: WebKit draws overlay scrollers that show
// only while scrolling, or legacy ones for "Always". Pages never style the native scrollbar
// (`scrollbar-width`, `scrollbar-color`, `::-webkit-scrollbar` make it a custom one that stays
// visible) and never use `overflow: scroll`; scripts/cmux-next/check-scrollbars.sh enforces that.
//
// Libraries that draw their own scrollers (Monaco; the @pierre/diffs code rows and the
// @pierre/trees list show theirs on hover) follow the host's answer instead: the shared web theme
// (WebTheme.swift) sets `data-scrollers="overlay" | "legacy"` on <html>. Overlay: the scroller is
// hidden at rest and while the pointer only hovers, and shows while the element scrolls
// (`data-cmux-scrolling`, set by `installScrollingMarks` or `markScrolling`). Legacy: it shows
// whenever the content overflows.

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
 * Marks the element each wheel event scrolls (one passive capture listener per document; wheel
 * events cross shadow roots, scroll events do not). Idempotent.
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
}

/**
 * Monaco's scrollbar options for a style. Monaco reveals its slider while the pointer is over the
 * editor; `MONACO_SCROLLER_CSS` hides it then for overlay. Its overview ruler border and cursor
 * mark read as a scrollbar track at rest, so both are off.
 */
export function monacoScrollerOptions(style: ScrollerStyle): {
  scrollbar: { vertical: "auto" | "visible"; horizontal: "auto" | "visible"; useShadows: boolean };
  overviewRulerBorder: boolean;
  hideCursorInOverviewRuler: boolean;
} {
  const visibility = style === "legacy" ? "visible" : "auto";
  return {
    scrollbar: { vertical: visibility, horizontal: visibility, useShadows: false },
    overviewRulerBorder: false,
    hideCursorInOverviewRuler: true,
  };
}

/**
 * Overlay: Monaco's slider shows only while the editor scrolls (the page marks the editor's node
 * with `markScrolling` on every scroll change), while it is dragged, or while the pointer is on
 * the scrollbar itself, where AppKit reveals an overlay scroller too.
 */
export const MONACO_SCROLLER_CSS = `
html:not([data-scrollers="legacy"]) .monaco-editor:not([${SCROLLING_ATTRIBUTE}]) .monaco-scrollable-element > .scrollbar:not(:hover) > .slider:not(.active) {
  opacity: 0;
  transition: opacity 0.4s;
}
`;

/**
 * Appended to every @pierre/diffs `unsafeCSS`. The library's code rows have a custom horizontal
 * scrollbar whose thumb shows on hover; here it shows while the row scrolls, and at rest only for
 * "Always" (`--cmux-scroller-rest`, from `SCROLLER_ROOT_CSS`; custom properties cross the shadow
 * root).
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

/** The document rules behind the library rules above. */
export const SCROLLER_ROOT_CSS = `
html[data-scrollers="legacy"] {
  --cmux-scroller-rest: color-mix(in srgb, currentColor 30%, transparent);
}
`;

/** Installs the root rules, the Monaco rule and the wheel marks once per document. */
export function installScrollers(document: Document, timers: ScrollTimers = defaultTimers): void {
  if (!document.getElementById("cmux-scrollers")) {
    const style = document.createElement("style");
    style.id = "cmux-scrollers";
    style.textContent = SCROLLER_ROOT_CSS + MONACO_SCROLLER_CSS;
    (document.head ?? document.documentElement).appendChild(style);
  }
  installScrollingMarks(document, timers);
}
