// Settings' page in jsdom, sized as a browser lays it out for the windowed cards (cardWindow.ts): an
// 800 px scroller (`main.content`) and each card row at its card's estimate (jsdom heights must
// equal the estimates: TanStack skips measuring at mount under jsdom).
export const SHARED_LINK_HEIGHT = 72;
export const KEY_HEIGHT = 96;
export const LIBRARY_HEIGHT = 72;

export function settingsCardSizes(element: HTMLElement): number {
  if (element.matches("main.content")) return 800;
  if (element.hasAttribute("data-shared-link")) return SHARED_LINK_HEIGHT;
  if (element.hasAttribute("data-key")) return KEY_HEIGHT;
  if (element.hasAttribute("data-library-entry")) return LIBRARY_HEIGHT;
  return 0;
}

/**
 * jsdom lays nothing out, so every rect is at 0 and a list's place in the scroller would read as the
 * scroller's own offset (cardWindow.ts reads `rect.top - scrollerRect.top + scrollTop`). A card's
 * `.rows` and its first row here sit at the top of the scroller's content, so they move up as the
 * page scrolls.
 */
export function installCardRects(window: { HTMLElement: { prototype: HTMLElement } }): void {
  const original = window.HTMLElement.prototype.getBoundingClientRect;
  window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const listed = this.classList.contains("rows") || this.matches('.rows > [data-index="0"]');
    const scroller = listed ? this.closest<HTMLElement>("main.content") : null;
    if (!scroller) return original.call(this);
    const top = -scroller.scrollTop;
    return { x: 0, y: top, top, left: 0, right: 0, bottom: top, width: 0, height: 0, toJSON: () => ({}) } as DOMRect;
  };
}
