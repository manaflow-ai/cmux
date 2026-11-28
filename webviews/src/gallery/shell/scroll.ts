export type GalleryScrollPosition = { x: number; y: number };

/** The shell's scrolling element on desktop; mobile lets the document scroll instead. */
export function scrollTargetFor(iframe: HTMLIFrameElement): HTMLElement | null {
  const main = iframe.closest<HTMLElement>(".gallery-main");
  const view = iframe.ownerDocument.defaultView;
  return main && (view?.getComputedStyle(main).overflowY ?? getComputedStyle(main).overflowY) !== "visible"
    ? main
    : null;
}

export function readScrollPosition(target: HTMLElement | null): GalleryScrollPosition {
  return target ? { x: target.scrollLeft, y: target.scrollTop } : { x: scrollX, y: scrollY };
}

export function restoreScrollPosition(target: HTMLElement | null, position: GalleryScrollPosition): void {
  if (!target) {
    scrollTo(position.x, position.y);
    return;
  }
  if (typeof target.scrollTo === "function") target.scrollTo({ left: position.x, top: position.y, behavior: "auto" });
  else {
    target.scrollLeft = position.x;
    target.scrollTop = position.y;
  }
}

/** Restore a mount position unless the reviewer intentionally scrolled while the frame loaded. */
export function restoreScrollPositionUnlessMoved(
  target: HTMLElement | null,
  position: GalleryScrollPosition,
  userMoved: boolean,
): boolean {
  if (userMoved) return false;
  restoreScrollPosition(target, position);
  return true;
}

export function scrollBaselineAfterEvent(
  target: HTMLElement | null,
  iframe: HTMLIFrameElement,
  baseline: GalleryScrollPosition,
  userMoved: boolean,
): { baseline: GalleryScrollPosition; restore: boolean } {
  const current = readScrollPosition(target);
  if (userMoved) return { baseline, restore: false };
  if (iframe.ownerDocument.activeElement === iframe) {
    return { baseline, restore: current.x !== baseline.x || current.y !== baseline.y };
  }
  return { baseline: current, restore: false };
}

/**
 * Treat an input event as intentional gallery scrolling only after it changes the
 * shell's scroll position. Pointer/key events can be delivered without scrolling
 * (for example, a click on a card control), so the intent is kept pending until
 * the following scroll event proves that it moved the target.
 */
export function scrollStateAfterEvent(
  target: HTMLElement | null,
  iframe: HTMLIFrameElement,
  baseline: GalleryScrollPosition,
  userMoved: boolean,
  intentPending: boolean,
): { baseline: GalleryScrollPosition; userMoved: boolean; intentPending: boolean; restore: boolean } {
  const current = readScrollPosition(target);
  const moved = current.x !== baseline.x || current.y !== baseline.y;
  if (intentPending && !userMoved && moved) {
    return { baseline, userMoved: true, intentPending: false, restore: false };
  }
  const result = scrollBaselineAfterEvent(target, iframe, baseline, userMoved);
  return { ...result, userMoved, intentPending };
}

export const SCROLL_KEYS = new Set([
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "ArrowUp",
  "End",
  "Home",
  "PageDown",
  "PageUp",
  " ",
]);
