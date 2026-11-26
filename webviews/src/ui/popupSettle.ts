// A popup opens at its final size and keeps it (Leo, 2026-11-22: "the shifting projects and sizing
// of stuff. and the shifting of the inner content. we need to prevent this once and for all").
//
// The rule, for every floating surface (`.ui-popup`): once its box has drawn the same for two
// frames it is settled, and from then on only the person resizes it. A key, a typed letter or a
// press in the popup frees the box (while the press is held, and `POPUP_INPUT_MS` after: a
// filter's results, a group they opened, an edge they drag), then it settles again. Data that
// arrives while they only look (a list read again, a count, a late icon, a status) changes the
// rows in place: the box stays.
//
// What a settled box holds (popupSurface.css `[data-popup-settled]`, from the lengths written here):
// - its width: late rows cut or wrap inside it, and it never gets narrower while open (typing in
//   a filter does not shrink the menu around the field);
// - its height as a floor: it never collapses under the pointer;
// - its height whole, when it holds a scroller and is tall enough to scroll in
//   (`POPUP_SCROLL_MIN_PX`): late rows scroll. A short box grows instead of clipping what arrives;
//   that growth is a bug its data fixes (load before open, or reserve the rows), and the detector
//   names it (test/popup-settle-browser.test.ts).
// The sheet's own `max-*` caps still bound all three, so a popup still gives way to a short window.
//
// Not for a results list, whose whole box is the answer to what is typed elsewhere (the composer's
// slash, mention and emoji lists, the omnibar's, a Combobox's own popup): `data-popup-settle="results"`.
// Not for a popup that sizes itself by a stricter rule of its own (the model menu's columns, which
// the person drags): `data-popup-settle="own"`. test/popup-settle-wired.test.ts holds every
// `.ui-popup` in the tree to this hook or one of the two.
//
// Stop condition: no loop and no polling. One ResizeObserver per open popup, a handful of window
// listeners while at least one popup is open, and two animation frames after each size change.
import { useCallback, useRef } from "react";

/** How long after the person's input in an open popup its box may change (ms). */
export const POPUP_INPUT_MS = 600;
/** A popup with a scroller keeps its whole height from this height up (px): enough rows to scroll in. */
export const POPUP_SCROLL_MIN_PX = 160;
/** Frames a box draws unchanged before it is settled. */
const STABLE_FRAMES = 2;

type Settled = {
  /** The person acted: `held` while a press is down. */
  release(held: boolean): void;
  /** The press ended. */
  drop(): void;
  reset(): void;
};

const open = new Map<HTMLElement, Settled>();

function onInput(event: Event): void {
  const target = event.target instanceof Node ? event.target : null;
  const press = event.type === "pointerdown";
  for (const [element, settled] of open) {
    // A key or a typed letter may filter any open popup (a list beside the field it filters); a
    // press counts only inside the popup it lands in.
    if (!press || (target && element.contains(target))) settled.release(press);
  }
}

function onPressEnd(): void {
  for (const settled of open.values()) settled.drop();
}

function onResize(): void {
  for (const settled of open.values()) settled.reset();
}

function listen(view: Window, on: boolean): void {
  const change = on ? view.addEventListener.bind(view) : view.removeEventListener.bind(view);
  change("keydown", onInput, true);
  change("input", onInput, true);
  change("pointerdown", onInput, true);
  change("pointerup", onPressEnd, true);
  change("pointercancel", onPressEnd, true);
  change("resize", onResize);
}

/** Whether the popup holds rows it does not show (a scroller inside, or its own scrolling overflow). */
function scrolls(element: HTMLElement, overflowY: string): boolean {
  return (
    overflowY === "auto" ||
    overflowY === "scroll" ||
    element.classList.contains("ui-popup-scroll-shell") ||
    element.querySelector(".ui-popup-scroll, .ui-combobox-scroll, .ui-scroll-area, [data-popup-scroll]") !== null
  );
}

const PROPERTIES = ["--popup-settled-width", "--popup-settled-floor", "--popup-settled-height"] as const;

/** Settles `element` for as long as it is mounted; the answer stops it and gives its box back. */
export function settlePopup(element: HTMLElement): () => void {
  const view = element.ownerDocument.defaultView;
  // A window with no layout (a test DOM without frames or a ResizeObserver) has no box to hold.
  if (!view || typeof view.ResizeObserver !== "function" || typeof view.requestAnimationFrame !== "function")
    return () => {};
  let frame = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let freeUntil = 0;
  let held = false;
  let floor = 0;
  let settled = false;
  let closed = false;

  const cancel = () => {
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
  };
  const free = () => {
    if (!settled) return;
    settled = false;
    element.removeAttribute("data-popup-settled");
    element.style.removeProperty("--popup-settled-width");
    element.style.removeProperty("--popup-settled-height");
  };
  const forget = () => {
    floor = 0;
    element.removeAttribute("data-popup-floor");
    element.style.removeProperty("--popup-settled-floor");
  };
  const settle = () => {
    if (closed || settled || held) return;
    const wait = freeUntil - view.performance.now();
    if (wait > 0) {
      timer = setTimeout(arm, wait);
      return;
    }
    // A popup that names its own rule (see the head of this file) is left alone.
    if (element.dataset.popupSettle) return;
    const box = element.getBoundingClientRect();
    // Not drawn (closed in place, or not laid out yet): the next size change settles it.
    if (!(box.width > 0) || !(box.height > 0)) return;
    const overflowY = view.getComputedStyle(element).overflowY;
    settled = true;
    floor = Math.max(floor, box.width);
    element.style.setProperty("--popup-settled-width", `${box.width}px`);
    element.style.setProperty("--popup-settled-floor", `${floor}px`);
    element.style.setProperty("--popup-settled-height", `${box.height}px`);
    element.setAttribute("data-popup-floor", "");
    element.setAttribute(
      "data-popup-settled",
      box.height >= POPUP_SCROLL_MIN_PX && scrolls(element, overflowY) ? "box" : "floor",
    );
  };
  // The box counts as drawn once it stayed the same for STABLE_FRAMES frames.
  function arm(): void {
    cancel();
    let left = STABLE_FRAMES;
    const step = () => {
      frame = 0;
      left -= 1;
      if (left > 0) frame = view!.requestAnimationFrame(step);
      else settle();
    };
    frame = view!.requestAnimationFrame(step);
  }
  const observer = new view.ResizeObserver(() => {
    const box = element.getBoundingClientRect();
    // Hidden in place (a popup kept mounted while closed): the next open starts over.
    if (box.width === 0 && box.height === 0) {
      cancel();
      free();
      forget();
      freeUntil = 0;
      return;
    }
    if (!settled) arm();
  });
  const entry: Settled = {
    release(press) {
      if (press) held = true;
      freeUntil = view.performance.now() + POPUP_INPUT_MS;
      free();
      arm();
    },
    drop() {
      if (!held) return;
      held = false;
      freeUntil = view.performance.now() + POPUP_INPUT_MS;
      arm();
    },
    reset() {
      // The window changed: every cap may have, so the box and its floor start over.
      free();
      forget();
      arm();
    },
  };
  if (open.size === 0) listen(view, true);
  open.set(element, entry);
  observer.observe(element);
  arm();
  return () => {
    if (closed) return;
    closed = true;
    cancel();
    observer.disconnect();
    element.removeAttribute("data-popup-settled");
    element.removeAttribute("data-popup-floor");
    for (const property of PROPERTIES) element.style.removeProperty(property);
    open.delete(element);
    if (open.size === 0) listen(view, false);
  };
}

/**
 * The ref of a popup's sized box (`.ui-popup`): it settles while mounted. `also` receives the node
 * too, for a popup that already keeps a ref.
 */
export function usePopupSettle<T extends HTMLElement>(also?: (node: T | null) => void): (node: T | null) => void {
  const stop = useRef<(() => void) | undefined>(undefined);
  const forward = useRef(also);
  forward.current = also;
  return useCallback((node: T | null) => {
    stop.current?.();
    stop.current = node ? settlePopup(node) : undefined;
    forward.current?.(node);
  }, []);
}
