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
// One exception: a minimal scroller (`MINIMAL_SCROLLER_ATTRIBUTE`, the agent chat's composer) keeps
// its thin thumb the whole time its content overflows (Leo 2026-10-21), unless the scrollbar fade
// is on (`SCROLLER_FADE_ATTRIBUTE`; the agent pane turns it on by default since Lawrence
// 2026-10-23, msg 11494: "auto-fades away").
//
// Every scroller drawn here also widens and darkens its thumb while the pointer is near its
// trailing edge (`NEAR_ATTRIBUTE`, `installScrollerProximity`), as a macOS overlay scroller does,
// so it is easy to grab.
//
// Libraries that draw their own scrollers (Monaco; the @pierre/diffs code rows and the
// @pierre/trees list show theirs on hover) follow the same rule: hidden at rest and while the
// pointer only hovers, shown while the element scrolls.

export type ScrollerStyle = "overlay" | "legacy";

/** The attribute a scrolling element carries until `SCROLLING_HIDE_MS` after its last scroll. */
export const SCROLLING_ATTRIBUTE = "data-cmux-scrolling";
/** How long a scroller stays after the last scroll step (AppKit's overlay fade starts about here). */
export const SCROLLING_HIDE_MS = 800;

/**
 * On a scroller whose thin thumb stays drawn the whole time its content overflows, whatever the
 * macOS setting: the agent chat's transcript (Leo 2026-10-21: "SCROLLBAR IT SHOULD FUCKING SHOW").
 * The rules come after the legacy ones in `SCROLLER_ROOT_CSS`, and their `:root` prefix outranks
 * them. The thumb never shows, hides and shows again as rows arrive or the view follows them. Its
 * lane is always there (`overflow-y: scroll`, on no track; no thumb is drawn while the content
 * fits), so the content never reflows as it starts to overflow. Its ink is
 * `--cmux-shown-scroller-ink`: under `SCROLLER_FADE_ATTRIBUTE` it is none at rest and full while
 * the element scrolls, and `followShownScrollerFade` fades it between the two.
 */
export const SHOWN_SCROLLER_ATTRIBUTE = "data-cmux-shown-scroller";
/** On `<html>` when shown scrollers fade out at rest instead (opt-in: Debug Settings
    `agentPane.debug.scrollerFade`, the agent theme's `scrollerFade`). */
export const SCROLLER_FADE_ATTRIBUTE = "data-cmux-scroller-fade";
/** A shown scroller's full ink, in percent of the text color (`--cmux-scroller-thumb`'s). */
const SHOWN_INK = 38;
/// A fade out runs a third longer than its duration property (the host's, after ui.animationSpeed,
/// Reduce Motion and animations off, so 0 stays 0): the pane's 180 ms move is 240 ms, the motion
/// scale's longest step, so the thumb is seen to fade (Leo 2026-10-29).
const FADE_OUT_STRETCH = 4 / 3;

/** A duration custom property's value in ms (`120ms`, `0.18s`); 0 when it is unset or not one. */
function durationMs(element: Element, property: string): number {
  const value = element.ownerDocument.defaultView?.getComputedStyle(element).getPropertyValue(property).trim() ?? "";
  const match = /^(\d*\.?\d+)(ms|s)$/.exec(value);
  if (!match) return 0;
  return Number(match[1]) * (match[2] === "s" ? 1000 : 1);
}

/**
 * Under `SCROLLER_FADE_ATTRIBUTE`, fades `element`'s shown thumb in when it starts scrolling and out
 * once it stops (`SCROLLING_ATTRIBUTE`), over `--cmux-scroller-fade-in` and `--cmux-scroller-fade-out`
 * (0 or unset: at once). The ink steps once per frame from script: WebKit restyles a scrollbar's
 * parts only when its element's style is resolved again, never on a CSS transition's steps, so a
 * transition there showed the thumb and hid it with nothing between. Between fades the stylesheet's
 * ink applies. Returns the stop function.
 */
export function followShownScrollerFade(element: HTMLElement): () => void {
  const view = element.ownerDocument.defaultView;
  // A view that draws no frames (a test page made without them) runs no fade.
  if (!view?.MutationObserver || typeof view.requestAnimationFrame !== "function") return () => {};
  const root = element.ownerDocument.documentElement;
  /// The ink the stylesheet gives `element` now (none at rest under the fade, else full).
  const resting = () =>
    root.hasAttribute(SCROLLER_FADE_ATTRIBUTE) && !element.hasAttribute(SCROLLING_ATTRIBUTE) ? 0 : SHOWN_INK;
  /// The ink drawn now; a fade starts from it.
  let ink = resting();
  let target = ink;
  let frame = 0;
  const settle = () => {
    view.cancelAnimationFrame(frame);
    ink = target = resting();
    element.style.removeProperty("--cmux-shown-scroller-ink");
  };
  const fade = () => {
    const to = resting();
    // Every scroll step marks the element again: a fade already headed there runs on.
    if (to === target) return;
    if (!root.hasAttribute(SCROLLER_FADE_ATTRIBUTE)) return settle();
    target = to;
    const from = ink;
    const ms =
      to > from
        ? durationMs(element, "--cmux-scroller-fade-in")
        : durationMs(element, "--cmux-scroller-fade-out") * FADE_OUT_STRETCH;
    view.cancelAnimationFrame(frame);
    if (ms <= 0) return settle();
    const start = view.performance.now();
    const step = (now: number) => {
      const t = Math.min(1, Math.max(0, (now - start) / ms));
      if (t >= 1) return settle();
      // A fade in eases out, as the pane's other fades (--agent-ease-out). A fade out eases in and
      // out: eased out, three quarters of the ink went in the first half and the thumb read as
      // vanishing at once (Leo 2026-10-29: "the scroll thumb should fade instead of disappearing
      // instantly").
      const eased = to > from ? 1 - (1 - t) * (1 - t) : t * t * (3 - 2 * t);
      ink = from + (to - from) * eased;
      element.style.setProperty("--cmux-shown-scroller-ink", `${ink.toFixed(2)}%`);
      frame = view.requestAnimationFrame(step);
    };
    step(start);
  };
  const scrollingMarks = new view.MutationObserver(fade);
  scrollingMarks.observe(element, { attributes: true, attributeFilter: [SCROLLING_ATTRIBUTE] });
  const fadeSetting = new view.MutationObserver(fade);
  fadeSetting.observe(root, { attributes: true, attributeFilter: [SCROLLER_FADE_ATTRIBUTE] });
  return () => {
    scrollingMarks.disconnect();
    fadeSetting.disconnect();
    settle();
  };
}

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

/** When the user last turned a wheel, pressed a key or a button in each document (ms, `now()`). */
const lastUserInput = new WeakMap<Document, number>();

/**
 * Whether a scroll event on `element` is the user's: always, except on a scroller whose thumb is
 * shown or fades by script (`SHOWN_SCROLLER_ATTRIBUTE`, `MINIMAL_SCROLLER_ATTRIBUTE`), where a
 * scroll with no wheel, key or button in the last `SCROLLING_HIDE_MS` is the page following new rows
 * or the caret, which must not flash the thumb (Leo 2026-10-21: it never flashes as rows arrive).
 */
export function isUserScroll(element: Element, lastInput: number | undefined, now: number): boolean {
  if (!element.hasAttribute(SHOWN_SCROLLER_ATTRIBUTE) && !element.hasAttribute(MINIMAL_SCROLLER_ATTRIBUTE)) return true;
  return lastInput !== undefined && now - lastInput <= SCROLLING_HIDE_MS;
}

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
  const now = () => document.defaultView?.performance.now() ?? Date.now();
  const input = () => lastUserInput.set(document, now());
  for (const type of ["wheel", "keydown", "pointerdown"])
    document.addEventListener(type, input, { capture: true, passive: true });
  document.addEventListener(
    "scroll",
    (event) => {
      const target = event.target;
      if (target === document) markScrolling(document.documentElement, timers);
      else if (
        target &&
        "setAttribute" in target &&
        isUserScroll(target as Element, lastUserInput.get(document), now())
      )
        markScrolling(target as Element, timers);
    },
    { capture: true, passive: true },
  );
}

/** On a scroller while the pointer is within `NEAR_PX` of its trailing edge: its thumb shows and
    widens, as a macOS overlay scroller does (Lawrence 2026-10-23, msg 11494: "grows bigger on
    near-hover so it's easier to grab"). */
export const NEAR_ATTRIBUTE = "data-cmux-scroller-near";
/** How close to a scroller's trailing edge the pointer counts as near (ThinScroller.nearDistance). */
export const NEAR_PX = 20;

/** Whether a point at `x`, `y` is near the bottom edge of a box with `rect`'s bounds (a sideways
    scroller's bar). */
export function nearBottomEdge(
  rect: { left: number; right: number; top: number; bottom: number },
  x: number,
  y: number,
): boolean {
  return y <= rect.bottom && y >= Math.max(rect.top, rect.bottom - NEAR_PX) && x >= rect.left && x <= rect.right;
}

/** Whether a point at `x`, `y` is near the trailing edge of a box with `rect`'s bounds. */
export function nearTrailingEdge(
  rect: { left: number; right: number; top: number; bottom: number },
  x: number,
  y: number,
): boolean {
  return x <= rect.right && x >= Math.max(rect.left, rect.right - NEAR_PX) && y >= rect.top && y <= rect.bottom;
}

function overflows(element: Element, axis: "x" | "y"): boolean {
  const past =
    axis === "y" ? element.scrollHeight > element.clientHeight : element.scrollWidth > element.clientWidth + 0.5;
  if (!past) return false;
  const style = element.ownerDocument.defaultView?.getComputedStyle(element);
  if (!style) return false;
  const value = axis === "y" ? style.overflowY : style.overflowX;
  const root = element === element.ownerDocument.documentElement;
  return root ? value !== "hidden" && value !== "clip" : ["auto", "scroll", "overlay"].includes(value);
}

/**
 * The scroller the pointer is near: the first element on `path` (the pointer event's composed path,
 * innermost first, shadow roots included, so a diff's code rows count) that scrolls vertically with
 * its trailing edge within `NEAR_PX` of the pointer, or sideways with its bottom edge (its bar)
 * that close; the page's own scroller as <html>, whose edges are the viewport's.
 */
export function nearScroller(path: readonly EventTarget[], x: number, y: number): Element | null {
  for (const node of path) {
    const element = node as Element;
    if (typeof element.getBoundingClientRect !== "function" || typeof element.scrollHeight !== "number") continue;
    const vertical = overflows(element, "y");
    const sideways = overflows(element, "x");
    if (!vertical && !sideways) continue;
    const view = element.ownerDocument.defaultView;
    const rect =
      element === element.ownerDocument.documentElement && view
        ? { left: 0, top: 0, right: view.innerWidth, bottom: view.innerHeight }
        : element.getBoundingClientRect();
    if ((vertical && nearTrailingEdge(rect, x, y)) || (sideways && nearBottomEdge(rect, x, y))) return element;
  }
  return null;
}

const proximityInstalled = new WeakSet<Document>();

/**
 * Keeps `NEAR_ATTRIBUTE` on the scroller the pointer is near (at most one per document), from
 * pointer moves only (passive capture listener, one per document, coalesced to a frame). Idempotent.
 */
export function installScrollerProximity(document: Document): void {
  const view = document.defaultView;
  if (proximityInstalled.has(document) || !view) return;
  proximityInstalled.add(document);
  let marked: Element | null = null;
  // The last move's path and point: a path read after its event has dispatched is empty.
  let pending: { path: EventTarget[]; x: number; y: number } | null = null;
  let frame = 0;
  const mark = (next: Element | null) => {
    if (next === marked) return;
    marked?.removeAttribute(NEAR_ATTRIBUTE);
    marked = next;
    marked?.setAttribute(NEAR_ATTRIBUTE, "");
  };
  document.addEventListener(
    "pointermove",
    (event) => {
      // While a button is down (a thumb drag, a selection) the marked scroller stays.
      const pointer = event as PointerEvent;
      if (pointer.buttons !== 0) return;
      pending = { path: pointer.composedPath(), x: pointer.clientX, y: pointer.clientY };
      if (frame) return;
      frame = view.requestAnimationFrame(() => {
        frame = 0;
        const last = pending;
        pending = null;
        if (last) mark(nearScroller(last.path, last.x, last.y));
      });
    },
    { capture: true, passive: true },
  );
  document.documentElement.addEventListener("pointerleave", () => mark(null), { passive: true });
  view.addEventListener("blur", () => mark(null));
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
 * On a transcript block's sideways scroller while its lines run past its width (an unwrapped diff,
 * Shell block or call output; conversation/sideways.ts `watchSideways` keeps it current). Such a
 * block keeps its thin thumb at rest, on no track, whatever the macOS setting: a line cut at the
 * edge with nothing at rest to say it scrolls read as clipped (Leo 2026-10-21, ask-d900f5acf9:
 * "doesn't really display properly or even show that there's a horizontal scrollbar"). Under the
 * scrollbar fade (`SCROLLER_FADE_ATTRIBUTE`, the agent pane's default since Lawrence 2026-10-23,
 * msg 11494: "auto-fades away") it fades like every other scroller instead: none at rest (the
 * right-edge fade still says the lines go on), shown while the box scrolls, and wide while the
 * pointer is near its bar (`NEAR_ATTRIBUTE`). The thumb
 * is the root rule's color (`--cmux-scroller-thumb`), in a lane `--cmux-sideways-lane` tall that
 * the block makes room for (conversation.css `--cv-lane`).
 */
export const SIDEWAYS_ATTRIBUTE = "data-cmux-sideways";

/** The thumb's color: the root rule's, or its value where the root rules are not installed. */
const SIDEWAYS_THUMB = "var(--cmux-scroller-thumb, color-mix(in srgb, currentColor 38%, transparent))";

/**
 * Appended to every @pierre/diffs `unsafeCSS`. The library's code rows have a custom horizontal
 * scrollbar whose thumb shows on hover; here it shows only while the row scrolls
 * (`--cmux-scroller-rest` is unset: nothing at rest), except in a transcript block whose rows run
 * past its edge (`SIDEWAYS_ATTRIBUTE`), where it stays, in the same color while it scrolls, unless
 * the page's scrollbar fade sets `--cmux-sideways-rest` (it inherits into Pierre's shadow root:
 * `SIDEWAYS_SCROLLER_CSS`). Near the pointer it widens and darkens: through the rest color, which
 * the library's own hover rule reads, since that rule outranks a plain near selector.
 */
export const PIERRE_DIFFS_SCROLLER_CSS = `
[data-code]::-webkit-scrollbar-thumb,
:is([data-diff], [data-file]):hover [data-code]::-webkit-scrollbar-thumb {
  background-color: var(--cmux-scroller-rest, transparent);
}
[data-code][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  background-color: var(--diffs-bg-context);
}
[data-code][${SIDEWAYS_ATTRIBUTE}] {
  --cmux-scroller-rest: var(--cmux-sideways-rest, ${SIDEWAYS_THUMB});
}
[data-code][${SIDEWAYS_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  background-color: ${SIDEWAYS_THUMB};
}
[data-code][${NEAR_ATTRIBUTE}] {
  --cmux-scroller-rest: var(--cmux-scroller-thumb-near, color-mix(in srgb, currentColor 55%, transparent));
}
[data-code][${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb,
[data-code][${NEAR_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  border-width: 0;
  background-color: var(--cmux-scroller-rest);
}
`;

/**
 * On a transcript block's own sideways box (a Shell block's or a call output's body) from the
 * moment it is made (its JSX), as `SIDEWAYS_SCROLLER_CSS` is installed with the page's other
 * scroller rules: the engine picks a scroller's kind (overlay or styled) when it makes it, and
 * WebKit keeps that kind when the style changes later.
 */
export const SIDEWAYS_SCROLLER_ATTRIBUTE = "data-cmux-sideways-scroller";

/**
 * The page side of `SIDEWAYS_ATTRIBUTE`: such a box's scrollbar is a thin thumb on no track, drawn
 * whenever it has one (an `overflow: auto` box has one only while its lines run past it), at rest
 * too, or under the scrollbar fade only while it scrolls or the pointer is near it (wide then). `--cmux-sideways-lane` is its lane's height while it has one. The `:root` prefix outranks
 * the "Always" rule's hidden thumb (`SCROLLER_ROOT_CSS`).
 */
export const SIDEWAYS_SCROLLER_CSS = `
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}][${SIDEWAYS_ATTRIBUTE}] {
  --cmux-sideways-lane: var(--cmux-scroller-size, 8px);
}
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar {
  width: var(--cmux-scroller-size, 8px);
  height: var(--cmux-scroller-size, 8px);
  background: transparent;
}
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-track,
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-corner {
  background: transparent;
}
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  min-width: 24px;
  border: 2px solid transparent;
  border-radius: var(--cmux-scroller-size, 8px);
  background: var(--cmux-sideways-rest, ${SIDEWAYS_THUMB}) padding-box;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] {
  --cmux-sideways-rest: transparent;
}
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb,
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb:hover,
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb:active {
  background-color: ${SIDEWAYS_THUMB};
}
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  border-width: var(--cmux-scroller-near-border, 1px);
  background-color: var(--cmux-scroller-thumb-near, color-mix(in srgb, currentColor 55%, transparent));
}
`;

/** Installs `SIDEWAYS_SCROLLER_CSS` once per document: with the others (`installScrollers`), or by `watchSideways` on a page without them. */
export function installSidewaysScrollers(document: Document): void {
  if (document.getElementById("cmux-sideways-scrollers")) return;
  const style = document.createElement("style");
  style.id = "cmux-sideways-scrollers";
  style.textContent = SIDEWAYS_SCROLLER_CSS;
  (document.head ?? document.documentElement).appendChild(style);
}

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
  /* Near the pointer the thumb widens (a thinner transparent border) and darkens. */
  --cmux-scroller-near-border: 1px;
  --cmux-scroller-thumb-near: color-mix(in srgb, currentColor 55%, transparent);
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
html[data-scrollers="legacy"] [${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb,
html[data-scrollers="legacy"][${NEAR_ATTRIBUTE}] > body::-webkit-scrollbar-thumb {
  border-width: var(--cmux-scroller-near-border);
  background-color: var(--cmux-scroller-thumb-near);
}
:root [${SHOWN_SCROLLER_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 38%;
  overflow-y: scroll;
}
:root [${SHOWN_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar {
  width: var(--cmux-scroller-size);
  height: var(--cmux-scroller-size);
  background: transparent;
}
:root [${SHOWN_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-track,
:root [${SHOWN_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-corner {
  background: transparent;
}
:root [${SHOWN_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb,
:root [${SHOWN_SCROLLER_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  min-height: 24px;
  border: 2px solid transparent;
  border-radius: var(--cmux-scroller-size);
  background: color-mix(in srgb, currentColor var(--cmux-shown-scroller-ink), transparent) padding-box;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 0%;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 38%;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb:hover,
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb:active {
  background-color: var(--cmux-scroller-thumb);
}
:root [${SHOWN_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb,
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  border-width: var(--cmux-scroller-near-border);
  background-color: var(--cmux-scroller-thumb-near);
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
  return {
    above: box.scrollTop > 0.5,
    below: box.scrollTop + box.clientHeight < box.scrollHeight - 0.5,
  };
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
 * (the native twin is ThinScroller.swift). An edge with more content past it fades out over
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
[${CARD_SCROLL_ATTRIBUTE}][${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  border-width: 0.5px;
  background-color: var(--cmux-scroller-thumb-near);
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

/** The attribute of a scroller that keeps its scrollbar while its content overflows (the agent
    chat's composer). See `MINIMAL_SCROLLER_CSS`. */
export const MINIMAL_SCROLLER_ATTRIBUTE = "data-cmux-minimal-scroller";

/**
 * The minimal scroller (Leo 2026-10-21: "IF THERE ARE THINGS TO SCROLL, JUST KEEP THE SCROLLBAR
 * IN THE COMPOSER, LIKE CLAUDE DOES."): a thin thumb in `--cmux-scroller-thumb` on no track, drawn
 * the whole time the content overflows, never faded on input, focus, hover or resize, whatever the
 * macOS setting. Content that fits draws no thumb. The lane is reserved even then, so the content
 * never rewraps as it starts or stops overflowing: `overflow-y: scroll`, the one exception to the
 * `auto` rule, since its track is transparent and a box with nothing to scroll draws no thumb.
 * (`scrollbar-gutter: stable` does not do it: WebKit ignores it on a custom scrollbar.) Take
 * `--cmux-scroller-size` out of the scroller's right padding to keep its text width. The track
 * stops `--cmux-minimal-scroller-inset` short of each end, clear of a rounded corner;
 * `--cmux-minimal-scroller-inset-end`, when set, replaces it at the bottom end (the composer's
 * track stops above Send, composerLocation.css). The `:root`
 * prefix outranks the legacy rule's hidden thumb above and the scroller's own `overflow-y`.
 */
export const MINIMAL_SCROLLER_CSS = `
:root [${MINIMAL_SCROLLER_ATTRIBUTE}] {
  overflow-y: scroll;
}
:root [${MINIMAL_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar {
  width: var(--cmux-scroller-size);
  height: var(--cmux-scroller-size);
  background: transparent;
}
:root [${MINIMAL_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-track {
  margin-top: var(--cmux-minimal-scroller-inset, 0px);
  margin-bottom: var(--cmux-minimal-scroller-inset-end, var(--cmux-minimal-scroller-inset, 0px));
  background: transparent;
}
:root [${MINIMAL_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-corner {
  background: transparent;
}
:root [${MINIMAL_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  min-height: 24px;
  border: 2px solid transparent;
  border-radius: var(--cmux-scroller-size);
  background: color-mix(in srgb, currentColor var(--cmux-shown-scroller-ink, 38%), transparent) padding-box;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${MINIMAL_SCROLLER_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 0%;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${MINIMAL_SCROLLER_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 38%;
}
:root [${MINIMAL_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}]::-webkit-scrollbar-thumb,
:root[${SCROLLER_FADE_ATTRIBUTE}] [${MINIMAL_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb:hover {
  border-width: var(--cmux-scroller-near-border);
  background-color: var(--cmux-scroller-thumb-near);
}
`;

/** Installs the root rules, the card and minimal scrollers, the Monaco rule, the wheel marks and
    the pointer-near marks once per document. */
export function installScrollers(document: Document, timers: ScrollTimers = defaultTimers): void {
  if (!document.getElementById("cmux-scrollers")) {
    const style = document.createElement("style");
    style.id = "cmux-scrollers";
    style.textContent = SCROLLER_ROOT_CSS + CARD_SCROLLER_CSS + MINIMAL_SCROLLER_CSS + MONACO_SCROLLER_CSS;
    (document.head ?? document.documentElement).appendChild(style);
  }
  installSidewaysScrollers(document);
  installScrollingMarks(document, timers);
  installScrollerProximity(document);
}
