// Whether a new box width belongs to the drag the last one belonged to.
//
// The transcript's fast paths for a drag all hang off this one answer: the rows go into normal flow
// so the browser rewraps them with no React pass and no height read (VirtualTranscript `startFlow`),
// the row observer stops its synchronous render-and-measure passes, and the layout measures only the
// rows around the view instead of every row (`layoutConversation`'s `resizing`).
//
// It used to be read from when the last width step **began**:
//
//     live = now - startedLastStep < LIVE_RESIZE_MS      // 120 ms
//
// which is the same quantity the fast paths exist to reduce. Beside a long chat one resize frame
// costs 250-400 ms, so the next width of the very same drag arrives more than 120 ms after the last
// one started; the drag reads as a one-off resize, the step count resets, flow is never entered and
// every row is measured again on every frame — which keeps the frame over 120 ms. The optimisation
// switched itself off exactly when it was needed, and could not switch back on: measured at 100k
// rows, `flow.anchored` never happened and the observer's `flush.drawn` cost 216 ms at p95, while
// the same drag at 33k rows (88 ms frames, inside the window) entered flow and spent 0 ms there.
//
// So liveness is read from when the last step's work **finished**. A drag's next width arrives
// within a frame of the previous pass ending whatever that pass cost, so the 120 ms keeps its
// meaning ("another width came promptly after the last one was served") and stops depending on how
// long serving takes. A real one-off resize still has no second width in that window, and a drag
// whose frames are slow is still a drag.

/// How soon after the last width step's work finished a new width counts as the same live resize.
/// A drag's frames come every 8 to 17 ms when the chat is short, and one frame after the last pass
/// when it is long; a window's or a strip's one-off change has no second width within it.
// motion-allow: a resize hold, not a motion
export const LIVE_RESIZE_MS = 120;

/// What the transcript remembers between width steps. `served` is when the last step's work
/// finished, `undefined` before any step has been served.
export interface LiveResizeClock {
  /// When the last width step began (the settle's timer is placed from this).
  at: number;
  /// Width steps in a row, each promptly after the one before was served.
  steps: number;
  /// When the last width step's own work finished: the render it forced and the measuring with it.
  served?: number;
}

/// Whether a width arriving at `now` continues the live resize `clock` describes.
///
/// Reads `served`, never `at`: the gap between the start of two steps is the cost of serving the
/// first, which is what this answer is used to reduce.
export function continuesLiveResize(clock: LiveResizeClock, now: number, window = LIVE_RESIZE_MS): boolean {
  if (clock.served === undefined) return false;
  return now - clock.served < window;
}

/// The clock after a width step at `now`: `steps` counts the steps of this drag, and starts again at
/// 0 for a width that begins a new one.
export function stepLiveResize(clock: LiveResizeClock, now: number, window = LIVE_RESIZE_MS): LiveResizeClock {
  const live = continuesLiveResize(clock, now, window);
  return { ...clock, at: now, steps: live ? clock.steps + 1 : 0 };
}
