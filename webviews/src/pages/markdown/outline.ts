// The heading outline (the rail at the left of the document, OutlineRail.tsx): the editor's
// headings (`MarkdownEditorOptions.onOutline`) and the one the reader is in, which follows the
// scroll once a frame. A click goes through the link router's `#heading` path, so it scrolls the
// way an anchor link does and Back returns.
import type { HeadingTarget } from "./links";

export interface OutlineState {
  headings: readonly HeadingTarget[];
  /** The index of the heading whose section is at the top of the pane; -1 above the first. */
  active: number;
}

export interface OutlineDeps {
  /** The element a heading draws as (`MarkdownEditor.headingElement`). */
  element(pos: number): HTMLElement | null;
  scroller(): HTMLElement | null;
  /** Scrolls to a heading by its anchor (the link router's `#slug`). */
  go(slug: string): void;
}

/** A section counts as current once its heading is this far under the pane's top edge or higher. */
const ACTIVE_LINE = 24;

/** The last of `count` headings in document order whose top (`top(index)`) is at or above `line`; -1 for none. */
export function activeHeading(count: number, top: (index: number) => number, line: number): number {
  let low = 0;
  let high = count - 1;
  let found = -1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (top(middle) <= line) {
      found = middle;
      low = middle + 1;
    } else high = middle - 1;
  }
  return found;
}

export class Outline {
  private state: OutlineState = { headings: [], active: -1 };
  private readonly listeners = new Set<() => void>();
  private frame = 0;

  constructor(private readonly deps: OutlineDeps) {}

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getState = (): OutlineState => this.state;

  setHeadings(headings: readonly HeadingTarget[]): void {
    this.set({ headings, active: this.state.active });
    this.track();
  }

  go(slug: string): void {
    this.deps.go(slug);
  }

  /** Follows the scroll of the pane while the rail shows; the returned function stops. */
  attach(): () => void {
    const scroller = this.deps.scroller();
    if (!scroller) return () => {};
    const onScroll = () => this.track();
    scroller.addEventListener("scroll", onScroll, { passive: true });
    this.track();
    return () => {
      scroller.removeEventListener("scroll", onScroll);
      if (this.frame) cancelAnimationFrame(this.frame);
      this.frame = 0;
    };
  }

  /** The current heading again, on the next frame (a binary search: a few layout reads). */
  private track(): void {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      const scroller = this.deps.scroller();
      const { headings } = this.state;
      if (!scroller || headings.length < 2) return;
      const line = scroller.getBoundingClientRect().top + ACTIVE_LINE;
      // At the end of the page the last section is current, though its heading cannot reach the top.
      const atEnd =
        scroller.scrollHeight > scroller.clientHeight &&
        scroller.scrollTop > 0 &&
        scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2;
      const active = atEnd
        ? headings.length - 1
        : activeHeading(
            headings.length,
            (index) => this.deps.element(headings[index]!.pos)?.getBoundingClientRect().top ?? Number.POSITIVE_INFINITY,
            line,
          );
      if (active !== this.state.active) this.set({ headings, active });
    });
  }

  private set(next: OutlineState): void {
    this.state = next;
    for (const listener of this.listeners) listener();
  }
}
