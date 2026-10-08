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
