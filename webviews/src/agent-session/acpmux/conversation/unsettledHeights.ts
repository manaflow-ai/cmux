// Parts of a transcript row whose height is not final yet, so a chat being opened is not shown
// before they are (https://github.com/manaflow-ai/cmux/issues/48498: "loading chats scrolls randomly
// up and down, loads jaggedly, and shifts layout"). An opened chat is one motion: its first shown
// frame is its final one. A row is placed by its drawn height before the frame paints, but some parts
// draw at another height a moment later, after work the page cannot do before that frame:
//   - math, until KaTeX's chunk has run (Math.tsx: the TeX source first, then the typeset equation);
//   - a diagram, until Mermaid or Vega has drawn it (DiagramBlock.tsx: an empty frame first);
//   - an image the host reads or fetches, until it answers (ReplyImage.tsx: the fixed waiting frame
//     first, then the image in its own shape);
//   - the composer's draft, until its editor is made (MarkdownField.tsx: its text unformatted first).
// A part that draws only once the reader comes near it (a diagram or lazy image a screen or more away,
// or in a hidden pane) does not count while it is that far: nothing would settle it.
// Each such part counts itself here while it is unsettled. The transcript holds an opening chat
// unseen while any part counts, up to a short ceiling (`OPEN_SETTLE_MAX_MS`),
// placing it at its latest row under the hold as the parts settle, then shows it once, in place.
// Once a chat is shown nothing waits on this: a part that settles later is a part the reader is
// looking at, and the transcript keeps the latest row (or the reader's row) still as it does for any
// row that changes height.
import { useCallback, useEffect, useLayoutEffect, useState, useSyncExternalStore } from "react";

/// The longest an opening chat is held unseen for its parts to settle. KaTeX's chunk and an image the
/// host reads from disk settle in a frame or two; a diagram's renderer can take longer, and a chat is
/// never held longer than this for it: past it the chat shows as it is, and the part settles in view.
export const OPEN_SETTLE_MAX_MS = 400;

let unsettled = 0;
const listeners = new Set<() => void>();

const tell = () => {
  for (const listener of listeners) listener();
};

/// The number of parts not at their final height now.
export function unsettledHeights(): number {
  return unsettled;
}

/// Calls `listener` whenever the count changes; the returned function stops it.
export function watchUnsettledHeights(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Counts the calling part as unsettled while `pending` is true and it is mounted. A layout effect,
/// so a part that mounts unsettled counts before the frame it first draws in paints.
export function useUnsettledHeight(pending: boolean): void {
  useLayoutEffect(() => {
    if (!pending) return;
    unsettled += 1;
    tell();
    return () => {
      unsettled -= 1;
      tell();
    };
  }, [pending]);
}

/// Whether every part has settled, or `OPEN_SETTLE_MAX_MS` has passed since `wanted` turned true (it
/// then stays true). The pane holds its first paint report on it (App.tsx), so the host shows the
/// page once the chat in it is at its final layout. A getter, read where the report is made: the
/// parts of the rows that commit with `wanted` count themselves in that commit's layout effects,
/// after this render read the store, so a value from the render would say settled too early. The
/// hook renders again when the count or the ceiling changes, so the reader's effect runs again.
export function useHeightsSettledFor(wanted: boolean): () => boolean {
  // Settled once is settled for good (the pane reports its first paint once): from then on the count
  // is not watched, so a part settling while the chat is read renders nothing here.
  const [latched, setLatched] = useState(false);
  const settled = useSyncExternalStore(
    latched ? ignore : watchUnsettledHeights,
    () => latched || unsettled === 0,
    () => true,
  );
  const [over, setOver] = useState(false);
  useEffect(() => {
    if (!wanted || latched) return;
    // The live count: the render's `settled` was read before this commit's parts counted themselves.
    if (over || unsettled === 0) return setLatched(true);
    const timer = window.setTimeout(() => setOver(true), OPEN_SETTLE_MAX_MS);
    return () => window.clearTimeout(timer);
  }, [wanted, settled, over, latched]);
  return useCallback(() => latched || over || (settled && unsettled === 0), [latched, over, settled]);
}

const ignore = () => () => {};

/// Holds `node` unseen (opacity 0: it lays out, scrolls and measures as shown) while any part is
/// unsettled, at most OPEN_SETTLE_MAX_MS, then shows it and calls `show` (the opened chat's fade
/// in) on the frame after the parts settled, so that frame has placed the rows at their final heights.
/// With nothing unsettled it calls `show` at once and holds nothing. Returns a function that ends a
/// hold early without calling `show` (another chat opened, the transcript went away).
export function holdUntilSettled(node: HTMLElement | null, show: () => void): (() => void) | undefined {
  if (!node || unsettled === 0) {
    show();
    return undefined;
  }
  const before = node.style.opacity;
  node.style.opacity = "0";
  let released = false;
  let frame: number | undefined;
  const release = () => {
    if (released) return;
    released = true;
    stop();
    window.clearTimeout(timer);
    // The frame after the last part settled lays it out and the transcript places its row (its
    // ResizeObserver, before that frame paints); the frame after that is the first one shown.
    frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(() => {
        frame = undefined;
        node.style.opacity = before;
        show();
      });
    });
  };
  const stop = watchUnsettledHeights(() => {
    if (unsettled === 0) release();
  });
  const timer = window.setTimeout(release, OPEN_SETTLE_MAX_MS);
  return () => {
    released = true;
    stop();
    window.clearTimeout(timer);
    if (frame !== undefined) cancelAnimationFrame(frame);
    node.style.opacity = before;
  };
}
