// A chat mounts one viewport of history in its first commit and the rest after its first paint
// (VirtualTranscript OPEN_HISTORY_VIEWPORTS, afterNextPaint.ts): a test that measures a settled chat
// waits past that paint first, so the history mounting is not counted in what it measures.

/** Resolves after the next animation frame and the task after it, the point afterNextPaint runs at.
 * Pass it to `act` so the render it causes is flushed too. */
export function pastFirstPaint(): Promise<void> {
  return new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
}
