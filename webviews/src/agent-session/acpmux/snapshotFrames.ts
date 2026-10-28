// The presentation seam for daemon snapshots. Protocol state and acknowledgements stay in the
// client; React consumes one current view per display frame.
import type { AcpmuxSnapshot } from "./model";

export function keepHandoff(current: AcpmuxSnapshot | undefined, next: AcpmuxSnapshot): AcpmuxSnapshot {
  if (next.canHandoff && !next.handoff?.ready && next.sessionId === current?.sessionId && current.handoff?.record)
    return { ...next, handoff: { ...next.handoff, record: current.handoff.record } };
  return next;
}

export function snapshotFrames(schedule: (run: () => void) => void, publish: (value: AcpmuxSnapshot) => void) {
  let active = true;
  return {
    push(value: AcpmuxSnapshot) {
      if (active) publish(value);
    },
    stop() {
      active = false;
    },
  };
}
