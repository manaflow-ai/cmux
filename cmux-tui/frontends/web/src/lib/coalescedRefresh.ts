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
      // One invalidation starts the current request. Notifications while it
      // is in flight collapse into one latest follow-up. Clear the marker
      // before that follow-up so a sustained event stream cannot turn this
      // helper into an unbounded request loop; a later event starts a new
      // bounded cycle after this one completes.
      dirty = false;
      try {
        await operation();
      } catch (error) {
        onError(error);
      }
      if (dirty && !cancelled) {
        dirty = false;
        try {
          await operation();
        } catch (error) {
          onError(error);
        }
      }
    } finally {
      running = false;
      dirty = false;
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
