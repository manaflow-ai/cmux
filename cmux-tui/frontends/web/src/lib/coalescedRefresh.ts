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
  let drainTimer: ReturnType<typeof setTimeout> | undefined;
  let operationCallDepth = 0;
  let reentrantInvalidation = false;
  let lateInvalidation = false;

  const scheduleDrain = () => {
    if (cancelled) return;
    if (drainTimer !== undefined) clearTimeout(drainTimer);
    drainTimer = setTimeout(() => {
      drainTimer = undefined;
      void drain();
    }, 0);
  };

  const runOperation = async () => {
    reentrantInvalidation = false;
    lateInvalidation = false;
    operationCallDepth += 1;
    let pending: Promise<void>;
    try {
      pending = operation();
    } catch (error) {
      operationCallDepth -= 1;
      onError(error);
      return;
    }
    operationCallDepth -= 1;
    try {
      await pending;
    } catch (error) {
      onError(error);
    }
  };

  const drain = async () => {
    if (running || cancelled) return;
    running = true;
    try {
      // One invalidation starts the current request. Notifications while it
      // is in flight collapse into one latest follow-up. Clear the marker
      // before that follow-up so a sustained event stream cannot turn this
      // helper into an unbounded request loop; a later event starts a new
      // bounded cycle after this one settles.
      dirty = false;
      await runOperation();
      if (dirty && !cancelled) {
        dirty = false;
        await runOperation();
        // An event that arrives while the follow-up is in flight cannot be
        // represented by its partial payload. Let the current bounded cycle
        // settle, then start one fresh cycle so the final snapshot wins. A
        // same-stack reentrant queue call is an operation-local invalidation;
        // dropping it keeps defensive self-invalidating operations bounded.
        if (dirty && lateInvalidation && !cancelled) scheduleDrain();
      }
    } finally {
      running = false;
      if (cancelled || drainTimer === undefined) dirty = false;
    }
  };

  const queue = (() => {
    if (cancelled) return;
    dirty = true;
    if (running) {
      if (operationCallDepth > 0) reentrantInvalidation = true;
      else lateInvalidation = true;
      return;
    }
    if (drainTimer !== undefined) {
      scheduleDrain();
      return;
    }
    void drain();
  }) as CoalescedRefresh;
  queue.cancel = () => {
    cancelled = true;
    dirty = false;
    if (drainTimer !== undefined) clearTimeout(drainTimer);
    drainTimer = undefined;
  };
  return queue;
}
