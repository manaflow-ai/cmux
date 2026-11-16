// l10n-allow-file: benchmark diagnostics, not shipped UI.
// What a chat's first load after a restart painted, frame by frame, as the numbers
// bench/first-load-after-restart.bench.ts reports. A first load is a state transition: its first
// painted frame should already be its last, it never blanks a pane that had content, and nothing in
// it moves (Leo, 2026-11-09, after "restart to update": "the chat loading kinda flickered in and out
// and layout shifted"). Pure, so test/first-load-frames.test.ts checks it without a browser.

/// A transcript row in view in a painted frame: its id (`data-row-id`) and its top edge, in CSS
/// pixels from the viewport's top.
export type FrameRow = { id: string; top: number };

/// What one painted frame showed, read from the layer on top: the chat's drawn copy while it shows
/// (chatSnapshot/paint.ts), else the live page.
export type FrameRecord = {
  /// `performance.now()` of the read: ms from navigation start.
  t: number;
  /// A `cmux-chat-snapshot` element was in the document.
  copyShown: boolean;
  /// The transcript rows intersecting the scroller's viewport, top to bottom.
  rows: FrameRow[];
  /// The composer's box (`.acpmux-composer-box`), or null when none showed.
  composer: { top: number; height: number } | null;
  /// The transcript scroller's offset, or null when there was none.
  scrollTop: number | null;
};

/// A box moved when an edge went further than this, so sub-pixel rounding between the copy and the
/// live page is no shift.
export const MOVE_TOLERANCE_PX = 1;

export type FrameMetrics = {
  frames: number;
  /// When the first frame with a row in view painted (ms from navigation), or null when none did.
  firstContentMs: number | null;
  /// Frames after the first one with content that showed no row in view.
  blankAfterContent: number;
  /// Frames in which the composer or the bottom-most row in view moved, or that row was replaced
  /// (``shiftBetween``).
  shiftFrames: number;
  /// When the first frame of the final state painted: from it on, every frame shows the same rows
  /// at the same places (within ``MOVE_TOLERANCE_PX``) and the composer at the same box. Null when
  /// no frame painted.
  finalFirstPaintMs: number | null;
  /// The frames counted above, by index, for a trace: why each one counted.
  blankAt: number[];
  shiftAt: { index: number; why: string }[];
};

const moved = (a: number, b: number) => Math.abs(a - b) > MOVE_TOLERANCE_PX;

/// The row lowest in view: the one the eye holds at the transcript's end.
export function bottomRow(rows: FrameRow[]): FrameRow | undefined {
  let bottom: FrameRow | undefined;
  for (const row of rows) if (!bottom || row.top >= bottom.top) bottom = row;
  return bottom;
}

/// Why `next` shifted from `previous`, or undefined when nothing moved. A frame that swaps the copy
/// for the live page is no shift when both draw the same boxes. `shown` is the last frame before
/// `next` that had rows in view (`previous` itself when it had): rows that come back after a blank
/// gap are held to where they were before it, so a pane that blanked and refilled elsewhere counts.
export function shiftBetween(
  previous: FrameRecord,
  next: FrameRecord,
  shown: FrameRecord = previous,
): string | undefined {
  const before = previous.composer;
  const after = next.composer;
  if (before && after) {
    if (moved(before.top, after.top)) return `composer top ${before.top.toFixed(1)} -> ${after.top.toFixed(1)}`;
    if (moved(before.height, after.height))
      return `composer height ${before.height.toFixed(1)} -> ${after.height.toFixed(1)}`;
  } else if (!!before !== !!after && previous.rows.length > 0 && next.rows.length > 0)
    // The composer came or went while the transcript showed: the pane's bottom changed under it.
    return after ? "composer appeared" : "composer went";
  const held = bottomRow(shown.rows);
  if (held && next.rows.length > 0) {
    const same = next.rows.find((row) => row.id === held.id);
    if (!same) return `bottom row ${held.id} replaced by ${bottomRow(next.rows)!.id}`;
    if (moved(held.top, same.top)) return `bottom row ${held.id} top ${held.top.toFixed(1)} -> ${same.top.toFixed(1)}`;
    // A new row under the one held (the transcript grew at its end) replaces it as the bottom.
    const lowest = bottomRow(next.rows)!;
    if (lowest.id !== held.id) return `bottom row ${held.id} replaced by ${lowest.id}`;
  }
  return undefined;
}

/// Whether two frames show the same state: the same rows in view in the same order, each at the same
/// top, and the composer at the same box (within ``MOVE_TOLERANCE_PX``).
export function sameState(a: FrameRecord, b: FrameRecord): boolean {
  if (a.rows.length !== b.rows.length) return false;
  for (let at = 0; at < a.rows.length; at += 1) {
    const one = a.rows[at]!;
    const other = b.rows[at]!;
    if (one.id !== other.id || moved(one.top, other.top)) return false;
  }
  if (!a.composer || !b.composer) return !a.composer && !b.composer;
  return !moved(a.composer.top, b.composer.top) && !moved(a.composer.height, b.composer.height);
}

/// The numbers of one load from its painted frames, oldest first.
export function classifyFrames(frames: FrameRecord[]): FrameMetrics {
  const blankAt: number[] = [];
  const shiftAt: { index: number; why: string }[] = [];
  const first = frames.findIndex((frame) => frame.rows.length > 0);
  if (first >= 0)
    for (let at = first + 1; at < frames.length; at += 1) if (frames[at]!.rows.length === 0) blankAt.push(at);
  let shown: FrameRecord | undefined;
  for (let at = 1; at < frames.length; at += 1) {
    const previous = frames[at - 1]!;
    if (previous.rows.length > 0) shown = previous;
    const why = shiftBetween(previous, frames[at]!, shown ?? previous);
    if (why) shiftAt.push({ index: at, why });
  }
  let settled = frames.length - 1;
  while (settled > 0 && sameState(frames[settled - 1]!, frames[frames.length - 1]!)) settled -= 1;
  return {
    frames: frames.length,
    firstContentMs: first >= 0 ? frames[first]!.t : null,
    blankAfterContent: blankAt.length,
    shiftFrames: shiftAt.length,
    finalFirstPaintMs: settled >= 0 ? frames[settled]!.t : null,
    blankAt,
    shiftAt,
  };
}
