export type CoalescedRefresh = (() => void) & {
  cancel: () => void;
};

export function createCoalescedRefresh(
  operation: () => Promise<void>,
  onError: (error: unknown) => void = () => {},
): CoalescedRefresh {
  let dirty = false;
  let running = false;
  let cancelled = false;

  const drain = async () => {
    if (running || cancelled) return;
    running = true;
    try {
      while (dirty && !cancelled) {
        dirty = false;
        try {
          await operation();
        } catch (error) {
          onError(error);
        }
      }
    } finally {
      running = false;
      if (dirty && !cancelled) void drain();
    }
  };

  const queue = (() => {
    if (cancelled) return;
    dirty = true;
    void drain();
  }) as CoalescedRefresh;
  queue.cancel = () => {
    cancelled = true;
    dirty = false;
  };
  return queue;
}
