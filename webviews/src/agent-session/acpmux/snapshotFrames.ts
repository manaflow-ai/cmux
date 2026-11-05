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

/// Direct snapshots carry only the subagent progress that changed since the one before
/// (direct.ts `takeChangedProgress`). Presenting only the latest of a frame's snapshots would lose
/// the earlier ones' values, so the last one carries every value its session changed in the batch.
export function withBatchProgress(batch: readonly AcpmuxSnapshot[]): AcpmuxSnapshot[] {
  let session: string | undefined;
  let progress: AcpmuxSnapshot["subagentProgress"];
  let carried = 0;
  for (const snapshot of batch) {
    if (snapshot.sessionId !== session) {
      session = snapshot.sessionId;
      progress = undefined;
      carried = 0;
    }
    if (snapshot.subagentProgress) {
      progress = { ...progress, ...snapshot.subagentProgress };
      carried += 1;
    }
  }
  const last = batch.at(-1);
  if (!last || !progress || (carried === 1 && last.subagentProgress)) return [...batch];
  return [...batch.slice(0, -1), { ...last, subagentProgress: progress }];
}

/// When the presenter shows what it queued: the next display frame on a shown page, or 50 ms,
/// whichever comes first (a page hidden while it waits draws at the 50 ms mark, as the client's
/// own hidden draws do). A hidden page presents at once: it paints nothing, but its effects still
/// act on each snapshot (a subagent's pane, the tab's header), which `nextFrame` would hold
/// until the page shows.
export function presentFrame(run: () => void): void {
  if (typeof document !== "undefined" && document.visibilityState === "hidden") return run();
  let ran = false;
  const once = () => {
    if (ran) return;
    ran = true;
    run();
  };
  requestAnimationFrame(once);
  // timeout: rAF does not fire while the page is hidden; 50 ms matches the client's hidden draw.
  setTimeout(once, 50);
}

/// The task after the display frame now running: every frame callback of this frame runs before it.
export function afterFrame(run: () => void): void {
  setTimeout(run, 0);
}

export function snapshotFrames(
  schedule: (run: () => void) => void,
  publish: (update: (current: AcpmuxSnapshot) => AcpmuxSnapshot) => void,
  frameEnd: (run: () => void) => void = afterFrame,
) {
  let active = true;
  let generation = 0;
  let queued: number | undefined;
  let pending: AcpmuxSnapshot[] = [];
  /// This display frame already published: until it ends, a framed delivery waits for the next.
  let framePublished = false;
  /// A user action, or a change of state drawn beside the snapshot, ran and the display frame it
  /// paints in has not come yet: snapshots present at once, in the same paint as that state (the
  /// cleared composer, the queued prompt's row, the started chat), never a frame behind it.
  let actionWindow = false;
  let windowGeneration = 0;
  const publishPending = () => {
    queued = undefined;
    const batch = pending;
    pending = [];
    // Fold once against React's actual current state. Pre-folding and then falling back to
    // committed state would erase an explicit handoff clear or a session boundary.
    if (active && batch.length) publish((current) => withBatchProgress(batch).reduce(keepHandoff, current));
  };
  const markFrame = () => {
    if (framePublished) return;
    framePublished = true;
    frameEnd(() => (framePublished = false));
  };
  /// A frame callback of the presenter: this frame's one publication, unless it already had one.
  const onFrame = () => {
    queued = undefined;
    if (framePublished) {
      if (pending.length) scheduleFrame();
      return;
    }
    publishPending();
    markFrame();
  };
  function scheduleFrame() {
    if (queued !== undefined) return;
    const mine = ++generation;
    queued = mine;
    schedule(() => {
      // A framed delivery may have drained this batch and a later burst scheduled its own frame.
      if (queued === mine) onFrame();
    });
  }
  /// Publishes now, outside any frame callback. The frame already asked for still runs: it presents
  /// what arrives after this, and holds a framed delivery behind it to that frame's one publication.
  const publishNow = () => {
    const asked = queued;
    publishPending();
    queued = asked;
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
      if (framePublished) {
        // This display frame has its publication: a delivery here joins the next frame.
        scheduleFrame();
        return;
      }
      // Direct event streams already waited for their display frame. Present them now, together
      // with preceding immediate snapshots; another schedule would add a full frame of latency.
      if (timing === "frame") {
        publishPending();
        markFrame();
        return;
      }
      if (actionWindow) {
        publishNow();
        return;
      }
      scheduleFrame();
    },
    /// A user action (Send, a new chat's start, Stop) or a change of state the pane draws beside the
    /// snapshot (the harness switch's queued prompt or started chat) just ran: what is queued and
    /// what arrives before the frame it paints in present at once, with it. The streams after that
    /// frame coalesce again.
    act() {
      if (!active) return;
      if (pending.length && !framePublished) publishNow();
      if (actionWindow) return;
      actionWindow = true;
      const mine = ++windowGeneration;
      schedule(() => {
        if (windowGeneration === mine) actionWindow = false;
      });
    },
    /// Presents what is queued now, in the caller's commit; the frame asked for presents nothing.
    flush() {
      if (active && pending.length) publishNow();
    },
    stop() {
      active = false;
      queued = undefined;
      pending = [];
      actionWindow = false;
      windowGeneration += 1;
    },
  };
}
