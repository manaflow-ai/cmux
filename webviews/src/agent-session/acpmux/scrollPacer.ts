/** The latest transcript scroll state waiting for the next display frame. */
export type ScrollFrame = { top: number; atLatest: boolean };

/** Resolve a stale queued frame against live scroll position and current reader intent. */
export function authoritativeScrollIntent({
  top,
  scrollHeight,
  clientHeight,
  following,
  jumping,
  deadband,
}: {
  top: number;
  scrollHeight: number;
  clientHeight: number;
  following: boolean;
  jumping: boolean;
  deadband: number;
}): boolean {
  return jumping || (following && top >= scrollHeight - clientHeight - deadband);
}

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
      pending = frame;
      if (handle !== undefined) return;
      handle = requestFrame(() => {
        handle = undefined;
        const next = pending;
        pending = undefined;
        if (next) commit(next);
      });
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
