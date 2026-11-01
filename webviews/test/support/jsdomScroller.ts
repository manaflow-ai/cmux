// A transcript scroller for jsdom tests, which have no layout, as WebKit (the app's engine) scrolls:
// the scroll offset moves only when written (no scroll event), the content's height is the
// spacer's rounded to a whole pixel, as `scrollHeight` reports it, and a written offset is floored
// to a whole pixel and clamped to the scroller's end. The transcript writes a following view's end rounded up and lets the browser
// clamp it (App.tsx `settleFollowBottom`): without the clamp a model scroller kept that offset,
// half a pixel past a fractional end no browser shows.
type Window = { HTMLElement: { prototype: HTMLElement } };

/// Installs the model on `window`'s elements; `viewport` reads the scroller's height now.
export function installJsdomScroller(window: Window, viewport: () => number): void {
  const offsets = new WeakMap<object, number>();
  const content = (element: HTMLElement) => {
    const spacer = element.querySelector?.<HTMLElement>(":scope > .acpmux-spacer");
    const height = spacer ? parseFloat(spacer.style.height) : NaN;
    return Number.isFinite(height) ? Math.round(height) : undefined;
  };
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get: () => viewport(),
  });
  Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return content(this) ?? viewport();
    },
  });
  Object.defineProperty(window.HTMLElement.prototype, "scrollTop", {
    configurable: true,
    get(this: object) {
      return offsets.get(this) ?? 0;
    },
    set(this: HTMLElement, value: number) {
      const height = content(this);
      const top = Math.floor(value);
      offsets.set(this, height === undefined ? top : Math.max(0, Math.min(top, height - viewport())));
    },
  });
}

/// The scroller's end as the browser reports it: its rounded content height less its height.
export const scrollerEnd = (scroller: HTMLElement) => scroller.scrollHeight - scroller.clientHeight;
