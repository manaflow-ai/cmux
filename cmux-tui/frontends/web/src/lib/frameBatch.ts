type RequestFrame = (callback: FrameRequestCallback) => number;
type CancelFrame = (frame: number) => void;

export interface FrameBatch<T> {
  schedule(value: T): void;
  cancel(): void;
}

/** Publish only the latest scheduled value once per animation frame. */
export function createFrameBatch<T>(
  publish: (value: T) => void,
  requestFrame: RequestFrame = requestAnimationFrame,
  cancelFrame: CancelFrame = cancelAnimationFrame,
): FrameBatch<T> {
  let frame: number | null = null;
  let pending: T | undefined;
  let hasPending = false;

  return {
    schedule(value) {
      pending = value;
      hasPending = true;
      if (frame !== null) return;
      frame = requestFrame(() => {
        frame = null;
        if (!hasPending) return;
        const value = pending as T;
        pending = undefined;
        hasPending = false;
        publish(value);
      });
    },
    cancel() {
      if (frame !== null) cancelFrame(frame);
      frame = null;
      pending = undefined;
      hasPending = false;
    },
  };
}
