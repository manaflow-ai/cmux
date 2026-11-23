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
// The agent chat's transcript and composer draw a shown scroller (`SHOWN_SCROLLER_ATTRIBUTE`): its
// lane always reserved, its thumb faded in while it scrolls and out at rest under the scrollbar fade
// (`SCROLLER_FADE_ATTRIBUTE`, on in the agent pane since Lawrence 2026-10-23, msg 11494: "auto-fades
// away"). The composer's also carries `MINIMAL_SCROLLER_ATTRIBUTE`: its track inset clear of the
// box's corner and controls, and no thumb while its box settles (Leo 2026-11-22: "the thumb only
// appears when it's relevant INSTEAD OF ALWAYS SHOWING UP").
//
// Every scroller drawn here also widens and darkens its thumb while the pointer is over its
// scrollbar lane (`NEAR_ATTRIBUTE`, `installScrollerProximity`), as a macOS overlay scroller does,
// so it is easy to grab. The lane is exactly where the engine takes a press on the scrollbar, so the
// thumb widens where a press grabs it and nowhere else (Lawrence 2026-11-20, msg 42498: "it is
// possible for me to hover close, and for the width to change, but after i mousedown and drag, it
// fails to scroll").
//
// Libraries that draw their own scrollers (Monaco; the @pierre/diffs code rows and the
// @pierre/trees list show theirs on hover) follow the same rule: hidden at rest and while the
// pointer only hovers, shown while the element scrolls.

export type ScrollerStyle = "overlay" | "legacy";

/** The attribute a scrolling element carries until `SCROLLING_HIDE_MS` after its last scroll. */
export const SCROLLING_ATTRIBUTE = "data-cmux-scrolling";
/** On a scrolling element whose scrollbar is hidden, so it needs no reveal or fade timer. */
export const HIDDEN_SCROLLER_ATTRIBUTE = "data-cmux-hidden-scroller";
/** How long a scroller stays after the last scroll step (AppKit's overlay fade starts about here). */
export const SCROLLING_HIDE_MS = 800;

/**
 * On a scroller whose thin thumb stays drawn the whole time its content overflows, whatever the
 * macOS setting: the agent chat's transcript (Leo 2026-10-21: "SCROLLBAR IT SHOULD SHOW").
 * The rules come after the legacy ones in `SCROLLER_ROOT_CSS`, and their `:root` prefix outranks
 * them. The thumb never shows, hides and shows again as rows arrive or the view follows them. Its
 * lane is always there (`overflow-y: scroll`, on no track; no thumb is drawn while the content
 * fits), so the content never reflows as it starts to overflow. Its ink is
 * `--cmux-shown-scroller-ink`: under `SCROLLER_FADE_ATTRIBUTE` it is none at rest and full while
 * the element scrolls, and `followShownScrollerFade` fades it between the two.
 */
export const SHOWN_SCROLLER_ATTRIBUTE = "data-cmux-shown-scroller";
/** On `<html>` when shown scrollers fade out at rest instead (the agent pane sets it whenever its
    host pushes a theme, acpmux paneTheme.ts `applyPaneTheme`). */
export const SCROLLER_FADE_ATTRIBUTE = "data-cmux-scroller-fade";
/** A shown scroller's full ink, in percent of the text color (`--cmux-scroller-thumb`'s). */
const SHOWN_INK = 38;
/** A shown scroller's ink while the pointer is near its bar (`--cmux-scroller-thumb-near`'s). */
const SHOWN_NEAR_INK = 55;
/// A fade out runs a third longer than its duration property (the host's, after ui.animationSpeed,
/// Reduce Motion and animations off, so 0 stays 0): the pane's 180 ms move is 240 ms, the motion
/// scale's longest step, so the thumb is seen to fade (Leo 2026-10-29).
const FADE_OUT_STRETCH = 4 / 3;

/**
 * The custom properties a scroller's thumb is drawn from: its ink (`property`, percent) in full and
 * near the pointer, and how far it has gone to its near look (`nearProperty`, 0 to 1: its border
 * goes from 2 px to `--cmux-scroller-near-border`, and a sideways thumb's colour toward
 * `--cmux-scroller-thumb-near`).
 */
export type ScrollerInk = { property: string; full: number; near: number; nearProperty: string };

/** The transcript's shown scroller's (`SHOWN_SCROLLER_ATTRIBUTE`). */
export const SHOWN_INK_PROPERTIES: ScrollerInk = {
  property: "--cmux-shown-scroller-ink",
  full: SHOWN_INK,
  near: SHOWN_NEAR_INK,
  nearProperty: "--cmux-shown-scroller-near",
};

/**
 * A sideways scroller's thumb ink (a wide table's, a Shell block's): percent of the thumb's color.
 * `followShownScrollerFade(box, SIDEWAYS_INK)` steps it so the thumb fades in and out under the
 * scrollbar fade instead of showing and hiding in one frame (user 2026-11-08: "this table thing
 * needs better animation on appear/disappear"). Near the pointer its colour goes toward the near
 * colour (`--cmux-sideways-near`).
 */
export const SIDEWAYS_INK: ScrollerInk = {
  property: "--cmux-sideways-ink",
  full: 100,
  near: 100,
  nearProperty: "--cmux-sideways-near",
};

/**
 * How a thumb takes the pointer coming near its bar (`NEAR_ATTRIBUTE`). `fade`: it fades to the near
 * ink and widens over the fade's duration, and back as the pointer leaves. `thin`: the same fade,
 * staying as thin as it scrolls. `instant`: the near look in one frame, as before (the stylesheet's
 * near rule).
 */
export type ScrollerNearMotion = "fade" | "thin" | "instant";

/** A duration custom property's value in ms (`120ms`, `0.18s`); 0 when it is unset or not one. */
function durationMs(element: Element, property: string): number {
  const value = element.ownerDocument.defaultView?.getComputedStyle(element).getPropertyValue(property).trim() ?? "";
  const match = /^(\d*\.?\d+)(ms|s)$/.exec(value);
  if (!match) return 0;
  return Number(match[1]) * (match[2] === "s" ? 1000 : 1);
}

/**
 * Under `SCROLLER_FADE_ATTRIBUTE`, fades `element`'s shown thumb in when it starts scrolling and out
 * once it stops (`SCROLLING_ATTRIBUTE`); with or without it, to its near look while the pointer is
 * near its bar and back (`NEAR_ATTRIBUTE`); over `--cmux-scroller-fade-in` and
 * `--cmux-scroller-fade-out` (0 or unset: at once). The ink and the near share step once per frame
 * from script: WebKit restyles a scrollbar's parts only when its element's style is resolved again,
 * never on a CSS transition's steps, so a transition there showed the thumb and hid it with nothing
 * between. Between fades the stylesheet's values apply. Before, the near look was the stylesheet's
 * alone: the thumb came in wide at 55% the frame the pointer reached the bar, from nothing at rest,
 * and went the frame it left (Leo 2026-11-20: "the thumb needs to look better when i do stuff").
 * Returns the stop function.
 */
export function followShownScrollerFade(
  element: HTMLElement,
  ink: ScrollerInk = SHOWN_INK_PROPERTIES,
  nearMotion: ScrollerNearMotion = "fade",
): () => void {
  const { property: INK_PROPERTY, nearProperty: NEAR_PROPERTY, full } = ink;
  const view = element.ownerDocument.defaultView;
  // A view that draws no frames (a test page made without them, or one that stubs only
  // requestAnimationFrame: the stop function cancels a frame) runs no fade.
  if (
    !view?.MutationObserver ||
    typeof view.requestAnimationFrame !== "function" ||
    typeof view.cancelAnimationFrame !== "function"
  )
    return () => {};
  const root = element.ownerDocument.documentElement;
  // The thin look keeps the scrolling border near the pointer too: on the shown thumb's own
  // property, since the shared one is inherited by every scroller inside (sideways blocks, cards).
  if (nearMotion === "thin") element.style.setProperty("--cmux-shown-scroller-near-border", "2px");
  type Look = { ink: number; near: number };
  /// The look the stylesheet gives `element` now: none at rest under the fade, else full, and the
  /// near look while the pointer is near.
  const resting = (): Look => {
    if (element.hasAttribute(NEAR_ATTRIBUTE)) return { ink: ink.near, near: 1 };
    return {
      ink: root.hasAttribute(SCROLLER_FADE_ATTRIBUTE) && !element.hasAttribute(SCROLLING_ATTRIBUTE) ? 0 : full,
      near: 0,
    };
  };
  /// The look drawn now; a fade starts from it.
  let drawn = resting();
  let target = drawn;
  let frame = 0;
  const settle = () => {
    view.cancelAnimationFrame(frame);
    drawn = target = resting();
    element.style.removeProperty(INK_PROPERTY);
    element.style.removeProperty(NEAR_PROPERTY);
  };
  const fade = () => {
    const to = resting();
    // Every scroll step marks the element again: a fade already headed there runs on.
    if (to.ink === target.ink && to.near === target.near) return;
    // `instant` takes the near look and leaves it at once, as before; inline ink from a scroll
    // fade would beat the stylesheet's near look.
    if (nearMotion === "instant" && (to.near === 1 || target.near === 1)) return settle();
    target = to;
    const from = drawn;
    // In when the ink rises (at the same ink, when the thumb widens), else out.
    const rising = to.ink !== from.ink ? to.ink > from.ink : to.near > from.near;
    const ms = rising
      ? durationMs(element, "--cmux-scroller-fade-in")
      : durationMs(element, "--cmux-scroller-fade-out") * FADE_OUT_STRETCH;
    view.cancelAnimationFrame(frame);
    if (ms <= 0) return settle();
    // The fade's clock is the frames' own: a frame's time can run on a clock other than
    // performance.now (a page whose animations are slowed or paused through the inspector), and a
    // start read from performance.now then left the fade at its first step for good.
    let start: number | undefined;
    const step = (now: number) => {
      start ??= now;
      const t = Math.min(1, Math.max(0, (now - start) / ms));
      if (t >= 1) return settle();
      // A fade in eases out, as the pane's other fades (--agent-ease-out). A fade out eases in and
      // out: eased out, three quarters of the ink went in the first half and the thumb read as
      // vanishing at once (Leo 2026-10-29: "the scroll thumb should fade instead of disappearing
      // instantly").
      const eased = rising ? 1 - (1 - t) * (1 - t) : t * t * (3 - 2 * t);
      drawn = { ink: from.ink + (to.ink - from.ink) * eased, near: from.near + (to.near - from.near) * eased };
      element.style.setProperty(INK_PROPERTY, `${drawn.ink.toFixed(2)}%`);
      element.style.setProperty(NEAR_PROPERTY, drawn.near.toFixed(3));
      frame = view.requestAnimationFrame(step);
    };
    frame = view.requestAnimationFrame(step);
  };
  const marks = new view.MutationObserver(fade);
  marks.observe(element, { attributes: true, attributeFilter: [SCROLLING_ATTRIBUTE, NEAR_ATTRIBUTE] });
  const fadeSetting = new view.MutationObserver(fade);
  fadeSetting.observe(root, { attributes: true, attributeFilter: [SCROLLER_FADE_ATTRIBUTE] });
  return () => {
    marks.disconnect();
    fadeSetting.disconnect();
    settle();
    if (nearMotion === "thin") element.style.removeProperty("--cmux-shown-scroller-near-border");
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
  if (element.hasAttribute(HIDDEN_SCROLLER_ATTRIBUTE)) {
    pending.delete(element);
    element.removeAttribute(SCROLLING_ATTRIBUTE);
    return;
  }
  // Set once per scroll, not on every step: each set is a DOM change that restyles the scroller and
  // wakes every observer of the mark (Session Info's body took one per frame while it scrolled).
  if (!element.hasAttribute(SCROLLING_ATTRIBUTE)) element.setAttribute(SCROLLING_ATTRIBUTE, "");
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

/** The user's last wheel, key or button in a document: when (ms, `now()`), what it was aimed at
    (`path`: its composed path, innermost first, across shadow roots), and the key, for a key. */
export type UserInput = { at: number; target: EventTarget | null; path?: readonly EventTarget[]; key?: string };

/** The user's last input in each document. */
const lastUserInput = new WeakMap<Document, UserInput>();

/** The element that scrolled last in each document (<html> for the page's own scroller). */
const lastScrolled = new WeakMap<Document, Element>();

/** The element that scrolled last in `document`, however it scrolled, or null before any scroll
    (or before `installScrollingMarks`). A reload keeps its position (pages/shared/pageHealth.ts). */
export function lastScrolledElement(document: Document): Element | null {
  return lastScrolled.get(document) ?? null;
}

/** Keys that scroll whatever the page scrolls by keyboard, wherever focus is (outside a text field).
    "Spacebar" is an older engine's name for " ". */
const SCROLLING_KEYS = new Set([
  "PageUp",
  "PageDown",
  "Home",
  "End",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  " ",
  "Spacebar",
]);

function editable(node: Node): boolean {
  const element = node as HTMLElement;
  return element.tagName === "INPUT" || element.tagName === "TEXTAREA" || element.isContentEditable === true;
}

/** Whether a key pressed on `node` is the control's own and scrolls nothing: Space on a button
    presses it (a Send button sends), and a select takes the arrows. */
function control(node: Node, key: string): boolean {
  const element = node as HTMLElement;
  if (element.tagName === "SELECT") return true;
  return (
    (key === " " || key === "Spacebar") && (element.tagName === "BUTTON" || element.getAttribute?.("role") === "button")
  );
}

/** Whether `input` can have scrolled `element`: it was aimed inside it, or it is a scrolling key
    pressed outside a text field. A key or button aimed elsewhere (Enter in a composer, a click on
    Send) leaves the page to scroll it, and that is the page's scroll. */
function reaches(input: UserInput, element: Element): boolean {
  const target = (input.path?.[0] ?? input.target) as Node | null;
  if (!target || typeof target.nodeType !== "number") return true;
  // Content in a shadow root is not contained by the scroller around its host: its host, further
  // out on the composed path, is.
  for (const node of input.path ?? [target])
    if ((node as Node).nodeType === 1 && element.contains(node as Node)) return true;
  // Tab moves focus, from a text field too, and the page scrolls the newly focused item into view.
  if (input.key === "Tab") return true;
  return input.key !== undefined && SCROLLING_KEYS.has(input.key) && !editable(target) && !control(target, input.key);
}

/**
 * Whether a scroll event on `element` is the user's. Right after a wheel, key or button (within
 * `SCROLLING_HIDE_MS`), it is when that input could have scrolled it (`reaches`): a send's scroll
 * after an Enter in the composer or a click on Send is the page's, and must not flash the thumb
 * (Leo 2026-11-07: "the thumb scroll sidebar thing, like, kind of flashes for a second"). With no
 * input that recent, it is on an ordinary scroller (a scroll by the track or a scroller of its own),
 * and never on a scroller whose thumb is shown or fades by script (`SHOWN_SCROLLER_ATTRIBUTE`,
 * `MINIMAL_SCROLLER_ATTRIBUTE`): that is the page following new rows or the caret, which must not
 * flash the thumb (Leo 2026-10-21: it never flashes as rows arrive).
 */
export function isUserScroll(element: Element, lastInput: UserInput | undefined, now: number): boolean {
  if (lastInput !== undefined && now - lastInput.at <= SCROLLING_HIDE_MS) return reaches(lastInput, element);
  return !element.hasAttribute(SHOWN_SCROLLER_ATTRIBUTE) && !element.hasAttribute(MINIMAL_SCROLLER_ATTRIBUTE);
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
  const input = (event: Event) =>
    lastUserInput.set(document, {
      at: now(),
      target: event.target,
      path: event.composedPath?.(),
      key: event.type === "keydown" ? (event as KeyboardEvent).key : undefined,
    });
  for (const type of ["wheel", "keydown", "pointerdown"])
    document.addEventListener(type, input, { capture: true, passive: true });
  document.addEventListener(
    "scroll",
    (event) => {
      const target = event.target;
      if (target === document) lastScrolled.set(document, document.documentElement);
      else if (target && "setAttribute" in target) lastScrolled.set(document, target as Element);
      // The page's own scroller is <html>, and it answers to the same rule as every other.
      if (target === document) {
        if (isUserScroll(document.documentElement, lastUserInput.get(document), now()))
          markScrolling(document.documentElement, timers);
      } else if (
        target &&
        "setAttribute" in target &&
        isUserScroll(target as Element, lastUserInput.get(document), now())
      )
        markScrolling(target as Element, timers);
    },
    { capture: true, passive: true },
  );
}

/** On a scroller while the pointer is over its scrollbar lane (`scrollbarLane`): its thumb shows
    and widens, as a macOS overlay scroller does (Lawrence 2026-10-23, msg 11494: "grows bigger on
    near-hover so it's easier to grab"), exactly where a press grabs it (Lawrence 2026-11-20, msg
    42498). */
export const NEAR_ATTRIBUTE = "data-cmux-scroller-near";

type Box = { left: number; right: number; top: number; bottom: number };

/** `element`'s border widths in px (its scrollbars sit inside them). */
function borders(element: Element): Box {
  const style = element.ownerDocument.defaultView?.getComputedStyle(element) as unknown as
    | Record<string, string>
    | undefined;
  const width = (side: string) => Number.parseFloat(style?.[`border${side}Width`] ?? "") || 0;
  return { left: width("Left"), right: width("Right"), top: width("Top"), bottom: width("Bottom") };
}

/**
 * How thick `element`'s own scrollbar is on `axis` (`y`: the vertical bar's width, `x`: the
 * sideways bar's height), in px: the lane the engine draws it in and takes presses on. 0 for an
 * overlay scrollbar, which takes no layout and widens and hit-tests itself.
 */
export function scrollbarLane(element: Element, axis: "x" | "y"): number {
  const document = element.ownerDocument;
  const view = document.defaultView;
  const box = element as HTMLElement;
  if (element === document.documentElement)
    return view
      ? Math.max(0, axis === "y" ? view.innerWidth - box.clientWidth : view.innerHeight - box.clientHeight)
      : 0;
  const border = borders(element);
  return Math.max(
    0,
    axis === "y"
      ? box.offsetWidth - box.clientWidth - border.left - border.right
      : box.offsetHeight - box.clientHeight - border.top - border.bottom,
  );
}

/** Whether a point at `x`, `y` is over the sideways bar of a box whose inside (its border box less
    its borders) is `rect`: its bottom `lane` px. Half-open, so a pixel row is in or out. */
export function nearBottomEdge(rect: Box, x: number, y: number, lane: number): boolean {
  return lane > 0 && y < rect.bottom && y >= rect.bottom - lane && x >= rect.left && x < rect.right;
}

/** Whether a point at `x`, `y` is over the vertical bar of a box whose inside is `rect`: its
    trailing `lane` px. Half-open, so a pixel column is in or out. */
export function nearTrailingEdge(rect: Box, x: number, y: number, lane: number): boolean {
  return lane > 0 && x < rect.right && x >= rect.right - lane && y >= rect.top && y < rect.bottom;
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
 * the pointer over its vertical bar's lane, or sideways with the pointer over its sideways bar's lane
 * (`scrollbarLane`); the page's own scroller as <html>, whose edges are the viewport's.
 */
export function nearScroller(path: readonly EventTarget[], x: number, y: number): Element | null {
  for (const node of path) {
    const element = node as Element;
    if (typeof element.getBoundingClientRect !== "function" || typeof element.scrollHeight !== "number") continue;
    const vertical = overflows(element, "y");
    const sideways = overflows(element, "x");
    if (!vertical && !sideways) continue;
    const view = element.ownerDocument.defaultView;
    let inside: Box;
    if (element === element.ownerDocument.documentElement && view) {
      inside = { left: 0, top: 0, right: view.innerWidth, bottom: view.innerHeight };
    } else {
      const rect = element.getBoundingClientRect();
      const border = borders(element);
      inside = {
        left: rect.left + border.left,
        right: rect.right - border.right,
        top: rect.top + border.top,
        bottom: rect.bottom - border.bottom,
      };
    }
    if (
      (vertical && nearTrailingEdge(inside, x, y, scrollbarLane(element, "y"))) ||
      (sideways && nearBottomEdge(inside, x, y, scrollbarLane(element, "x")))
    )
      return element;
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
/** Its colour near the pointer. */
const SIDEWAYS_NEAR_THUMB = "var(--cmux-scroller-thumb-near, color-mix(in srgb, currentColor 55%, transparent))";

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
  border: solid transparent;
  /* As the shown scroller's: 2 px, the near border near the pointer, stepped between by script. */
  border-width: calc(2px - (2px - var(--cmux-scroller-near-border, 1px)) * var(--cmux-sideways-near, 0));
  border-radius: var(--cmux-scroller-size, 8px);
  background: color-mix(
      in srgb,
      color-mix(in srgb, ${SIDEWAYS_NEAR_THUMB} calc(var(--cmux-sideways-near, 0) * 100%), ${SIDEWAYS_THUMB})
        var(--cmux-sideways-ink, 100%),
      transparent
    )
    padding-box;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] {
  --cmux-sideways-rest: transparent;
}
/* Under the scrollbar fade the thumb rests at no ink and has full ink while it scrolls; between
   the two, followShownScrollerFade steps --cmux-sideways-ink inline, once a frame. */
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SIDEWAYS_SCROLLER_ATTRIBUTE}] {
  --cmux-sideways-ink: 0%;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SIDEWAYS_SCROLLER_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}] {
  --cmux-sideways-ink: 100%;
}
/* Near the pointer (a hover on the thumb is near too) it widens and takes the near colour, faded
   there and back by followShownScrollerFade, never in one frame. */
:root [${SIDEWAYS_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}],
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SIDEWAYS_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}] {
  --cmux-sideways-ink: 100%;
  --cmux-sideways-near: 1;
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
  border: solid transparent;
  /* 2 px at rest and while it scrolls, the near border near the pointer, and between the two while
     followShownScrollerFade steps --cmux-shown-scroller-near (0 to 1). */
  border-width: calc(
    2px - (2px - var(--cmux-shown-scroller-near-border, var(--cmux-scroller-near-border, 1px))) *
      var(--cmux-shown-scroller-near, 0)
  );
  border-radius: var(--cmux-scroller-size);
  background: color-mix(in srgb, currentColor var(--cmux-shown-scroller-ink), transparent) padding-box;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 0%;
}
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 38%;
}
/* Near the pointer it widens and darkens through the same properties, so the script fades it there
   and back instead of the frame the pointer comes or goes (a hover on the thumb is near too). */
:root [${SHOWN_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}],
:root[${SCROLLER_FADE_ATTRIBUTE}] [${SHOWN_SCROLLER_ATTRIBUTE}][${NEAR_ATTRIBUTE}] {
  --cmux-shown-scroller-ink: 55%;
  --cmux-shown-scroller-near: 1;
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

/** On a sideways scroller (a wide table, an unwrapped code box) while content lies past its left
    edge (it was scrolled) or its right edge. The stylesheet fades that edge out with a mask, so the
    fade takes whatever background the box sits on, light or dark (user 2026-11-07: "markdown
    missing fade now"). */
export const MORE_LEFT_ATTRIBUTE = "data-more-left";
export const MORE_RIGHT_ATTRIBUTE = "data-more-right";

/** Which side edges of a scroller have content past them (a half pixel of slack for zoomed pages). */
export function sidewaysEdges(box: { scrollLeft: number; clientWidth: number; scrollWidth: number }): {
  left: boolean;
  right: boolean;
} {
  return {
    left: box.scrollLeft > 0.5,
    right: box.scrollLeft + box.clientWidth < box.scrollWidth - 0.5,
  };
}

/** Sets `MORE_LEFT_ATTRIBUTE` and `MORE_RIGHT_ATTRIBUTE` on `box` from where it is scrolled now. */
export function markSidewaysEdges(box: Element): void {
  const edges = sidewaysEdges(box);
  if (box.hasAttribute(MORE_LEFT_ATTRIBUTE) !== edges.left) box.toggleAttribute(MORE_LEFT_ATTRIBUTE, edges.left);
  if (box.hasAttribute(MORE_RIGHT_ATTRIBUTE) !== edges.right) box.toggleAttribute(MORE_RIGHT_ATTRIBUTE, edges.right);
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
/* Picker columns opt out of hover-only reveal: the thumb appears only during a scroll. */
:root [${CARD_SCROLL_ATTRIBUTE}][data-cmux-scroll-only] {
  --cmux-card-scroll-only-thumb: transparent;
}
:root [${CARD_SCROLL_ATTRIBUTE}][data-cmux-scroll-only][${SCROLLING_ATTRIBUTE}] {
  --cmux-card-scroll-only-thumb: var(--cmux-scroller-thumb);
}
:root [${CARD_SCROLL_ATTRIBUTE}][data-cmux-scroll-only]::-webkit-scrollbar-thumb {
  background-color: var(--cmux-card-scroll-only-thumb);
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

/** On a shown scroller (`SHOWN_SCROLLER_ATTRIBUTE`) whose track is inset at its ends and whose thumb
    stays clear while its box settles (the agent chat's composer). See `MINIMAL_SCROLLER_CSS`. */
export const MINIMAL_SCROLLER_ATTRIBUTE = "data-cmux-minimal-scroller";

/** On a minimal scroller whose box is moving to a height its content fits (the composer's field
    growing by a line, composer/fieldGrowth.ts): mid-move the content is taller than the box, yet
    nothing will be left to scroll, so no thumb is drawn. See `MINIMAL_SCROLLER_CSS`. */
export const SETTLING_SCROLLER_ATTRIBUTE = "data-cmux-scroller-settling";

/**
 * The composer's additions to a shown scroller (the element carries both attributes; the lane, ink,
 * scroll fade and near look are `SHOWN_SCROLLER_ATTRIBUTE`'s, `followShownScrollerFade`). Its thumb
 * shows only while it scrolls or the pointer is near its lane, then fades, as Claude desktop's does
 * (Leo 2026-11-22: "the thumb only appears when it's relevant INSTEAD OF ALWAYS SHOWING UP
 * LIKE ..."); before, it stayed drawn the whole time the draft overflowed (Leo
 * 2026-10-21, superseded).
 *
 * The track stops `--cmux-minimal-scroller-inset` short of each end, clear of a rounded corner;
 * `--cmux-minimal-scroller-inset-end`, when set, replaces it at the bottom end (the composer's
 * track ends above its button row, composerLocation.css).
 *
 * While its box moves to a height the content fits (`SETTLING_SCROLLER_ATTRIBUTE`), the content
 * overflows only until the move lands, so the thumb stays clear even if the move scrolls it (Leo
 * 2026-11-08: "when we have the composer grow a bit if it's not long enough to actually be
 * scrollable stop showing a flash of the thumb scrollbar"). Only the thumb's ink goes: the lane,
 * the overflow and the text's width stay, so nothing rewraps or moves when the move lands. Comes
 * after `SCROLLER_ROOT_CSS`, so at equal specificity it beats the shown thumb's scrolling ink.
 */
export const MINIMAL_SCROLLER_CSS = `
:root [${MINIMAL_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-track {
  margin-top: var(--cmux-minimal-scroller-inset, 0px);
  margin-bottom: var(--cmux-minimal-scroller-inset-end, var(--cmux-minimal-scroller-inset, 0px));
}
:root [${MINIMAL_SCROLLER_ATTRIBUTE}][${SETTLING_SCROLLER_ATTRIBUTE}]::-webkit-scrollbar-thumb,
:root [${MINIMAL_SCROLLER_ATTRIBUTE}][${SETTLING_SCROLLER_ATTRIBUTE}][${SCROLLING_ATTRIBUTE}]::-webkit-scrollbar-thumb {
  background: transparent;
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
