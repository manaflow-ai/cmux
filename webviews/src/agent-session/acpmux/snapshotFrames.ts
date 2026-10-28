// The presentation seam for daemon snapshots. Protocol state and acknowledgements stay in the
// client; React consumes one current view per display frame.
import type { AcpmuxSnapshot } from "./model";

export function keepHandoff(current: AcpmuxSnapshot | undefined, next: AcpmuxSnapshot): AcpmuxSnapshot {
  if (
    next.canHandoff &&
    !next.handoff?.ready &&
    current &&
    next.sessionId === current.sessionId &&
    current.handoff?.record
  )
    return { ...next, handoff: { ...next.handoff, record: current.handoff.record } };
  return next;
}

export function snapshotFrames(
  schedule: (run: () => void) => void,
  publish: (update: (current: AcpmuxSnapshot) => AcpmuxSnapshot) => void,
) {
  let active = true;
  let generation = 0;
  let queued: number | undefined;
  let pending: AcpmuxSnapshot[] = [];
  const flush = () => {
    queued = undefined;
    const batch = pending;
    pending = [];
    // Fold once against React's actual current state. Pre-folding and then falling back to
    // committed state would erase an explicit handoff clear or a session boundary.
    if (active && batch.length) publish((current) => batch.reduce(keepHandoff, current));
  };
  return {
    guard<Args extends unknown[]>(receive: (...args: Args) => void) {
      return (...args: Args) => {
        if (active) receive(...args);
      };
    },
    push(value: AcpmuxSnapshot, timing?: "frame") {
      if (!active) return;
      pending.push(value);
      // Direct event streams already waited for their display frame. Present them now, together
      // with preceding immediate snapshots; another schedule would add a full frame of latency.
      if (timing === "frame") {
        flush();
        return;
      }
      if (queued !== undefined) return;
      const mine = ++generation;
      queued = mine;
      schedule(() => {
        // A framed delivery may have drained this batch and a later burst scheduled its own frame.
        if (queued === mine) flush();
      });
    },
    stop() {
      active = false;
      queued = undefined;
      pending = [];
    },
  };
}
