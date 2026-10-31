// Which code blocks are near the markdown editor's viewport (editor.ts, codeHighlightPlugin). Coloring
// a block loads its language's grammar and tokenizes it on the main thread, so the editor colors only
// the blocks near what the reader sees: a long file with code in many languages opens without
// coloring code nobody has scrolled to, and a block is colored a screen before it scrolls in.

/** The nearest ancestor that scrolls vertically, or null for the page itself. */
function scrollParent(element: Element): Element | null {
  for (let at = element.parentElement; at; at = at.parentElement) {
    const overflow = getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") return at;
  }
  return null;
}

/**
 * Watches one editor's code blocks and reports the document positions of those that come within a
 * screen of its scroll box. A reported block is not watched again until `watch` re-arms it (its
 * position stopped being near: the block was replaced).
 */
export class NearCodeBlocks {
  private observer: IntersectionObserver | null = null;
  private readonly positions = new Map<Element, () => number | undefined>();

  constructor(
    private readonly editor: Element,
    private readonly report: (positions: number[]) => void,
  ) {}

  /** Whether the page can tell; without an observer every block counts as near. */
  static get supported(): boolean {
    return typeof IntersectionObserver !== "undefined";
  }

  watch(element: Element, position: () => number | undefined): void {
    this.observer ??= new IntersectionObserver((entries) => this.seen(entries), {
      root: scrollParent(this.editor),
      rootMargin: "100% 0px",
    });
    this.positions.set(element, position);
    // Observing anew delivers the element's current state, so a re-armed block in view reports.
    this.observer.unobserve(element);
    this.observer.observe(element);
  }

  forget(element: Element): void {
    this.positions.delete(element);
    this.observer?.unobserve(element);
  }

  disconnect(): void {
    this.observer?.disconnect();
    this.positions.clear();
  }

  private seen(entries: IntersectionObserverEntry[]): void {
    const near: number[] = [];
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const position = this.positions.get(entry.target)?.();
      this.forget(entry.target);
      if (position !== undefined) near.push(position);
    }
    if (near.length) this.report(near);
  }
}
