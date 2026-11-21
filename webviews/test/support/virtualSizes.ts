// A windowed list (TanStack Virtual) sizes its viewport and measures its rows by `offsetHeight`, which
// jsdom (no layout) reports as 0: the list then mounts no rows at all. This gives every element of
// `window` a height by a rule, a `scrollTop` that keeps what is written and a `scrollTo` that
// scrolls, so a jsdom test mounts the rows a browser would.
type Window = { HTMLElement: { prototype: HTMLElement } };

/// Installs the sizes on `window`'s elements; `height` is read each time TanStack asks.
export function installVirtualSizes(window: Window, height: (element: HTMLElement) => number, width = 800): void {
  const offsets = new WeakMap<object, number>();
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return height(this);
    },
  });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", {
    configurable: true,
    get: () => width,
  });
  Object.defineProperty(window.HTMLElement.prototype, "scrollTop", {
    configurable: true,
    get(this: object) {
      return offsets.get(this) ?? 0;
    },
    set(this: object, value: number) {
      offsets.set(this, Math.max(0, value));
    },
  });
  // A scroller's content is its windowed list's spacer, sized inline (`height: getTotalSize()`).
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return height(this);
    },
  });
  Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      const spacer = parseFloat((this.firstElementChild as HTMLElement | null)?.style.height ?? "");
      return Number.isFinite(spacer) ? Math.max(spacer, height(this)) : height(this);
    },
  });
  // As a browser scrolls: the offset moves, then a scroll event says so (TanStack listens for it).
  window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
    this.scrollTop = typeof options === "object" ? (options.top ?? this.scrollTop) : (options ?? this.scrollTop);
    this.dispatchEvent(new this.ownerDocument.defaultView!.Event("scroll"));
  } as HTMLElement["scrollTo"];
}

/// The History page: a 600 px list of 36 px rows and headers.
export const historySizes = (element: HTMLElement) => (element.classList.contains("history-list") ? 600 : 36);
