// What a Markdown tab shows besides its file, kept while the host discards its hidden page
// (`memoryDiscardInternalPages`): the mode and the scroll, anchored to the heading
// above the top of the view as Chrome's scroll anchoring keeps a node and an offset
// (third_party/blink/renderer/core/layout/scroll_anchor.cc), so the place survives images that
// load late and an edit of the file above it. The host asks `cmux.markdown.viewState` and gives the
// answer back as the next page's config `viewState`.
import type { HistoryEntry, MarkdownMode } from "./store";

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
  /** Rich mode only: the source view has no headings to anchor to. */
  anchor?: MarkdownScrollAnchor;
  mode?: MarkdownMode;
  /** The page's link history (files followed in place), with the current entry. */
  history?: { entries: HistoryEntry[]; index: number };
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
  const raw = value as { scroll?: unknown; anchor?: unknown; mode?: unknown; history?: unknown };
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
  const history = historyOf(raw.history);
  if (history) state.history = history;
  return state;
}

/** A saved link history, or undefined when it is not one. */
function historyOf(value: unknown): MarkdownViewState["history"] {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as { entries?: unknown; index?: unknown };
  if (!Array.isArray(raw.entries) || typeof raw.index !== "number") return undefined;
  const entries: HistoryEntry[] = [];
  for (const entry of raw.entries as Partial<HistoryEntry>[]) {
    if (
      !entry ||
      typeof entry.path !== "string" ||
      typeof entry.anchor !== "string" ||
      typeof entry.scroll !== "number"
    )
      return undefined;
    entries.push({ path: entry.path, anchor: entry.anchor, scroll: Math.max(0, entry.scroll) });
  }
  if (!Number.isInteger(raw.index) || raw.index < 0 || raw.index >= entries.length) return undefined;
  return { entries, index: raw.index };
}

/** The laid-out headings inside `scroller` with their tops in its content coordinates. A hidden
 * heading (the rich document under the source view) has an empty box and no place: it is left out. */
export function markdownHeadingBoxes(scroller: HTMLElement | null): MarkdownHeadingBox[] {
  if (!scroller) return [];
  const origin = scroller.getBoundingClientRect().top - scroller.scrollTop;
  const boxes: MarkdownHeadingBox[] = [];
  for (const heading of scroller.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    const rect = heading.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) continue;
    boxes.push({ text: heading.textContent ?? "", top: rect.top - origin });
  }
  return boxes;
}
