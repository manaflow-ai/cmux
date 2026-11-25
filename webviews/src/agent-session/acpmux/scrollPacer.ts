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
 * `flush` commits a motion write before its current frame paints and cancels queued work.
 * `cancel` is called when the transcript unmounts or placement takes over.
 */
export function createScrollPacer(
  commit: (frame: ScrollFrame) => void,
  requestFrame: RequestFrame = (callback) => requestAnimationFrame(callback),
  cancelFrame: CancelFrame = (handle) => cancelAnimationFrame(handle),
) {
  let pending: ScrollFrame | undefined;
  let handle: number | undefined;
  // A motion callback has already committed this position before paint. Its later native
  // scroll event needs no second commit, unless the offset or follow intent changed.
  let immediate: ScrollFrame | undefined;
  const cancelPending = () => {
    pending = undefined;
    if (handle !== undefined) cancelFrame(handle);
    handle = undefined;
  };

  return {
    enqueue(frame: ScrollFrame) {
      if (immediate?.top === frame.top && immediate.atLatest === frame.atLatest) return;
      immediate = undefined;
      pending = frame;
      if (handle !== undefined) return;
      handle = requestFrame(() => {
        handle = undefined;
        const next = pending;
        pending = undefined;
        if (next) commit(next);
      });
    },
    flush(frame: ScrollFrame) {
      cancelPending();
      if (immediate?.top === frame.top && immediate.atLatest === frame.atLatest) return;
      immediate = frame;
      commit(frame);
    },
    cancel() {
      cancelPending();
      immediate = undefined;
    },
  };
}
