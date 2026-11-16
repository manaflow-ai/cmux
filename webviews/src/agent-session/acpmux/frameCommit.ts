// The chat's snapshot is drawn in the frame it is scheduled for (CMUX-571). The client coalesces every record
// that lands before a display frame into one snapshot (direct.ts `emitInFrame`) and hands it to the pane in that
// frame's callback (`nextFrame`). The pane keeps it in React state; an update made in a frame callback is not a
// discrete event, so React renders it at default priority in a scheduler task that runs after the frame has
// rendered, and the record reaches the screen one frame later. On an idle Mac that is 8 to 17 ms; on a loaded one,
// drawing 4 frames a second, it is a whole frame interval more for every record (Leo's NIGHTLY: p50 1,021 ms, p95
// 1,837 ms from a record's arrival to its first paint, while applying it took 2.6 ms at most). Chrome's model:
// changes coalesce to one frame per display refresh and are drawn by that frame, so the snapshot is committed
// synchronously in the frame callback (or the 50 ms fallback's task) that delivers it. The work is the same render
// the scheduler task would have done, moved before the paint instead of after it.
import { flushSync } from "react-dom";
import { nextFrame } from "./direct";

/// `AcpmuxDirectClient.scheduleFrame` for a page that draws the client's snapshots with React: `run` (the client's
/// emit, whose listener sets the pane's state) runs once before the next display frame, and what it sets is
/// committed before that frame paints.
export const commitInFrame = (run: () => void): (() => void) => nextFrame(() => flushSync(run));
