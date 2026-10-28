// The presentation seam for daemon snapshots. Protocol state and acknowledgements stay in the
// client; React consumes one current view per display frame.
import type { AcpmuxSnapshot } from "./model";

export function keepHandoff(current: AcpmuxSnapshot | undefined, next: AcpmuxSnapshot): AcpmuxSnapshot {
  if (
    next.canHandoff &&
    !next.handoff?.ready &&
    !next.handoff?.record &&
    current &&
    next.sessionId === current.sessionId &&
    current.handoff?.record
  )
    return { ...next, handoff: { ...next.handoff, record: current.handoff.record } };
  return next;
}

export function snapshotFrames(schedule: (run: () => void) => void, publish: (value: AcpmuxSnapshot) => void) {
  let active = true;
  let queued = false;
  let pending: AcpmuxSnapshot | undefined;
  return {
    guard<Args extends unknown[]>(receive: (...args: Args) => void) {
      return (...args: Args) => {
        if (active) receive(...args);
      };
    },
    push(value: AcpmuxSnapshot) {
      if (!active) return;
      pending = keepHandoff(pending, value);
      if (queued) return;
      queued = true;
      schedule(() => {
        queued = false;
        const next = pending;
        pending = undefined;
        if (active && next) publish(next);
      });
    },
    stop() {
      active = false;
      pending = undefined;
    },
  };
}
