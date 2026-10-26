// What a Markdown tab shows besides its file, kept while the host discards its hidden page
// (`memoryDiscardInternalPages`, p07-memory-026): the mode and the scroll, anchored to the heading
// above the top of the view as Chrome's scroll anchoring keeps a node and an offset
// (third_party/blink/renderer/core/layout/scroll_anchor.cc), so the place survives images that
// load late and an edit of the file above it. The host asks `cmux.markdown.viewState` and gives the
// answer back as the next page's config `viewState`.
import type { MarkdownMode } from "./store";

/** A heading of the shown document and its top, in the scroller's content coordinates. */
export interface MarkdownHeadingBox {
  text: string;
  top: number;
}

/** The heading at or above the top of the view: its text, which of the headings with that text it
 * is, and how far below its top the view starts. */
export interface MarkdownScrollAnchor {
  heading: string;
  occurrence: number;
  offset: number;
}

export interface MarkdownViewState {
  scroll: number;
  anchor?: MarkdownScrollAnchor;
  mode?: MarkdownMode;
}

/** The anchor of a view scrolled to `scrollTop` over `headings` (in document order). */
export function markdownScrollAnchor(
  headings: readonly MarkdownHeadingBox[],
  scrollTop: number,
): MarkdownScrollAnchor | undefined {
  let index = -1;
  for (let next = 0; next < headings.length && headings[next]!.top <= scrollTop; next += 1) index = next;
  if (index < 0) return undefined;
  const box = headings[index]!;
  const occurrence = headings.slice(0, index).filter((other) => other.text === box.text).length;
  return { heading: box.text, occurrence, offset: scrollTop - box.top };
}

/** Where a view saved as `state` scrolls to over `headings` now: its anchor heading's top plus the
 * offset, or the saved scroll when that heading is gone. */
export function anchoredScrollTop(headings: readonly MarkdownHeadingBox[], state: MarkdownViewState): number {
  const anchor = state.anchor;
  if (!anchor) return state.scroll;
  const box = headings.filter((heading) => heading.text === anchor.heading)[anchor.occurrence];
  return box ? Math.max(0, box.top + anchor.offset) : state.scroll;
}

/** A `viewState` from the host, or null when it is not one (an older page's, a malformed one). */
export function markdownViewStateOf(value: unknown): MarkdownViewState | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as { scroll?: unknown; anchor?: unknown; mode?: unknown };
  if (typeof raw.scroll !== "number" || !Number.isFinite(raw.scroll)) return null;
  const state: MarkdownViewState = { scroll: Math.max(0, raw.scroll) };
  const anchor = raw.anchor as Partial<MarkdownScrollAnchor> | undefined;
  if (
    anchor &&
    typeof anchor.heading === "string" &&
    typeof anchor.occurrence === "number" &&
    typeof anchor.offset === "number"
  ) {
    state.anchor = { heading: anchor.heading, occurrence: anchor.occurrence, offset: anchor.offset };
  }
  if (raw.mode === "rich" || raw.mode === "source") state.mode = raw.mode;
  return state;
}

/** The headings inside `scroller` with their tops in its content coordinates. */
export function markdownHeadingBoxes(scroller: HTMLElement | null): MarkdownHeadingBox[] {
  if (!scroller) return [];
  const origin = scroller.getBoundingClientRect().top - scroller.scrollTop;
  return Array.from(scroller.querySelectorAll("h1, h2, h3, h4, h5, h6"), (heading) => ({
    text: heading.textContent ?? "",
    top: heading.getBoundingClientRect().top - origin,
  }));
}
