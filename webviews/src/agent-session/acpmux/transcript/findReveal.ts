import { FIND_ACTIVE_HIGHLIGHT } from "../conversation/chatFind";

/// Scrolls `scroller` so `range` sits a third of the way down it, when it is not already in view
/// above the `inset` px at its foot that the bottom stack covers.
export function scrollRangeIn(scroller: HTMLElement, range: Range, inset = 0) {
  const box = range.getBoundingClientRect();
  const view = scroller.getBoundingClientRect();
  if (box.top < view.top || box.bottom > view.bottom - inset)
    scroller.scrollTop += box.top - view.top - scroller.clientHeight / 3;
}

/// Scrolls `range` into view in the scrollers between it and `transcript` (a command's capped
/// output scrolls on its own), innermost first; the transcript itself is left to the caller.
export function scrollRangeInBoxes(transcript: HTMLElement, range: Range) {
  for (let box = range.startContainer.parentElement; box && box !== transcript; box = box.parentElement)
    if (box.scrollHeight > box.clientHeight && /auto|scroll/.test(getComputedStyle(box).overflowY))
      scrollRangeIn(box, range);
}

/// How long Find keeps a new match in view while its groups open and the rows above it measure:
/// at least 600 ms and 36 frames, so a page the machine starves (fewer frames) still holds the
/// match through the measures that come late. A page hidden meanwhile draws no frames and finishes
/// the frames it has left once shown.
export const FIND_REVEAL_MS = 600;

export const FIND_REVEAL_FRAMES = 36;

/// ...and until the match has not moved for this many frames: on a starved page the fold it opened
/// measures for seconds, each measure pushing the match down.
export const FIND_REVEAL_STILL_FRAMES = 12;

/// A layout that never settles (a reply streaming above the match) ends the hold after this many.
export const FIND_REVEAL_MAX_FRAMES = 600;

/// The current Find match's range, if it is drawn.
export function findActiveRange(): Range | undefined {
  const highlights = (globalThis.CSS as unknown as { highlights?: Map<string, Set<Range>> } | undefined)?.highlights;
  return [...(highlights?.get(FIND_ACTIVE_HIGHLIGHT) ?? [])][0];
}

/// Where the current Find match sits in `scroller`'s content, if it is drawn.
export function findMatchOffset(scroller: HTMLElement): number | undefined {
  const range = findActiveRange();
  if (!range) return undefined;
  return range.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
}
