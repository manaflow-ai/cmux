// jsdom has no layout, so every element's scrollHeight is 0. A transcript test stubs clientHeight
// (its viewport) but a scroller with no content height reads as a reader always at its end: since
// #48114 handleScroll takes a fall that rests at or past `scrollHeight - clientHeight` for the
// browser's spring back, not a reader's scroll up (Leo, 2026-11-18: "did we fix this scroll bounce
// at the bottom yet?"), so in such a test no scroll up ever left the end. A browser's scroller is as
// tall as its content: the transcript's spacer (`.acpmux-spacer`, `height: layout.totalHeight`),
// and never shorter than its own view.
export function installTranscriptScrollHeight(window: { HTMLElement: typeof HTMLElement }): void {
  Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      const spacer = this.classList.contains("acpmux-scroll")
        ? this.querySelector<HTMLElement>(".acpmux-spacer")
        : null;
      const content = spacer ? Number.parseFloat(spacer.style.height) || 0 : 0;
      return spacer ? Math.max(this.clientHeight, content) : 0;
    },
  });
}
