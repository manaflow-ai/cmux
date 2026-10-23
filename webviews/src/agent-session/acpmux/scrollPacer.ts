/** The latest transcript scroll state waiting for the next display frame. */
export type ScrollFrame = { top: number; atLatest: boolean };

type RequestFrame = (callback: FrameRequestCallback) => number;
type CancelFrame = (handle: number) => void;

/**
 * Coalesces transcript scroll updates so one display frame commits the latest offset.
 * `cancel` is called when the transcript unmounts and drops any pending frame.
 */
export function createScrollPacer(
  commit: (frame: ScrollFrame) => void,
  requestFrame: RequestFrame = (callback) => requestAnimationFrame(callback),
  cancelFrame: CancelFrame = (handle) => cancelAnimationFrame(handle),
) {
  let pending: ScrollFrame | undefined;
  let handle: number | undefined;

  return {
    enqueue(frame: ScrollFrame) {
      commit(frame);
    },
    cancel() {
      pending = undefined;
      if (handle !== undefined) {
        cancelFrame(handle);
        handle = undefined;
      }
    },
  };
}
