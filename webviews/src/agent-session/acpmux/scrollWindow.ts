// The transcript's row window (VirtualTranscript's TranscriptView): the rows a scroll offset mounts,
// worked out from the offset, the scroll's direction and the layout. A render reads it at the offset it
// draws; a scroll frame reads it at its own offset against the last commit (`scrollWindowAt`) and
// renders only when the rows it would mount differ. Pure, so the two read the same rows.
import { layoutGeometry, mergeRowRanges, scrollLeadRanges, visibleLayoutRange } from "./model";
import type { AcpmuxRow, PlacedLayout, RowRange } from "./model";

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
export const SCROLL_LEAD_STEPS = 2;

export const MAX_SCROLL_LEAD_VIEWPORTS = 4;

/// Viewports of just-passed rows kept mounted behind a moving scroll (scrollLeadRanges `trail`), so a
/// quick reversal finds them drawn.
export const SCROLL_TRAIL_VIEWPORTS = 1;

/// Viewports of rows kept mounted either side of the reader, built between frames.
export const WARM_VIEWPORTS = 1;

/// Viewports of history mounted above the reader, in the commit that draws the view: a chat opens
/// with rows to scroll up into already drawn, and the warm rows keep that much above while the reader
/// scrolls (Leo, 2026-11-12: "if you try to scroll up, you can't really scroll much of anything up at
/// all. Like it doesn't load enough"). Rows the transcript already holds only; older pages still come
/// by OLDER_AHEAD_VIEWPORTS. Above the view, so a followed view's end anchors them: their heights
/// land in the offset in the frame they are measured and no visible row moves.
export const HISTORY_VIEWPORTS = 4;

/// How far the reader scrolls, in viewports, before the warm rows move with them.
export const WARM_STEP_VIEWPORTS = 0.5;

/// Where the warm rows are built from, as a row and how far into it: one string, so the deferred
/// render that builds them runs only when it moves. A row holds its content as rows page in above
/// it or a followed end moves under it; an offset into the whole stack did not, and a deferred one
/// from the frame before picked rows turns away (`warmTop`). The row's index is a hint for the read.
export function warmAnchor(
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
  at: number,
  step: number,
) {
  const index = visibleLayoutRange(placed, at, 0, 0).first;
  const row = shown[index];
  // In steps too: a row above that settles to its drawn height moves the row, not the anchor.
  return row ? `${Math.round((at - layoutGeometry(placed).topAt(index)) / step) * step}\n${index}\n${row.id}` : "";
}

/// The offset of `anchor` (warmAnchor) in `placed`: its row at the index it was found at, else looked
/// for (older history paged in above it, once, until the deferred anchor catches up). Undefined once
/// it is gone.
export function warmAnchorTop(
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
  anchor: string,
) {
  const [offset, hint, id] = anchor.split("\n");
  if (id === undefined) return undefined;
  const at = Number(hint);
  const index = shown[at]?.id === id ? at : shown.findIndex((row) => row.id === id);
  return index < 0 ? undefined : layoutGeometry(placed).topAt(index) + Number(offset);
}

/// The rows a scroll offset mounts, before the warm rows' deferred place is read (TranscriptView
/// `scrollWindowAt`): where the view shows (`shownTop`, the offset less `lift`), the scroll's lead and
/// trail (`ahead`), the rows in view (`view`) and the run of mounted rows they are in (`range`), and
/// where the warm rows are built from (`warmAt`, held while a fling outruns them). `top` is in layout
/// px, `heldWarmAt` the last commit's.
export type ScrollLead = {
  shownTop: number;
  ahead: RowRange[];
  view: RowRange;
  range: RowRange;
  warmStep: number;
  liveWarmAt: number;
  warmAt: string;
};
export function scrollLeadAt(
  layout: PlacedLayout,
  rows: readonly AcpmuxRow[],
  top: number,
  delta: number,
  lift: number,
  height: number,
  heldWarmAt: string | undefined,
): ScrollLead {
  const shownTop = top - lift;
  const ahead = scrollLeadRanges(
    layout,
    shownTop,
    delta,
    height,
    SCROLL_LEAD_STEPS,
    height * MAX_SCROLL_LEAD_VIEWPORTS,
    height * SCROLL_TRAIL_VIEWPORTS,
  );
  const view = visibleLayoutRange(layout, shownTop, height);
  const range = ahead.find((each) => each.first <= view.first && view.first < each.last) ?? view;
  // The deferred offset moves in steps of WARM_STEP_VIEWPORTS (TranscriptView, `warm`).
  const warmStep = Math.max(1, height * WARM_STEP_VIEWPORTS);
  const liveWarmAt = Math.round(top / warmStep) * warmStep;
  const warmOutrun = Math.abs(delta) * SCROLL_LEAD_STEPS > height * WARM_VIEWPORTS;
  const warmAt = warmOutrun && heldWarmAt !== undefined ? heldWarmAt : warmAnchor(layout, rows, liveWarmAt, warmStep);
  return { shownTop, ahead, view, range, warmStep, liveWarmAt, warmAt };
}

/// The rows a scroll offset mounts (`lead`, scrollLeadAt): its lead and trail, the warm rows built at
/// `deferredWarmAt`, and for a followed view the history above it. TranscriptView's render works them
/// out the same way, inline (`scrolledRanges`): a call there that took the lead kept the rows it
/// mounts open to change past the effects that read them, and the React Compiler then read those
/// effects as render code. The two must agree: a scroll frame renders when they do not.
export function scrollRangesAt(
  layout: PlacedLayout,
  rows: readonly AcpmuxRow[],
  lead: ScrollLead,
  deferredWarmAt: string,
  following: boolean,
  height: number,
): RowRange[] {
  const { shownTop, ahead, range, warmStep, liveWarmAt } = lead;
  const warmTop = warmAnchorTop(layout, rows, deferredWarmAt) ?? liveWarmAt;
  // Above the view the warm rows reach HISTORY_VIEWPORTS: history to scroll up into, built between
  // frames as the rest of them are.
  const warm = visibleLayoutRange(
    layout,
    warmTop - height * HISTORY_VIEWPORTS - warmStep / 2,
    height * (1 + HISTORY_VIEWPORTS + WARM_VIEWPORTS) + warmStep,
  );
  // A followed view mounts that history in the commit that draws it (TranscriptView, `history`).
  const history = following
    ? visibleLayoutRange(layout, shownTop - height * HISTORY_VIEWPORTS, height * HISTORY_VIEWPORTS, 0)
    : undefined;
  return mergeRowRanges([
    ...(warm.last < range.first || warm.first > range.last ? ahead : [...ahead, warm]),
    ...(history ? [history] : []),
  ]);
}
