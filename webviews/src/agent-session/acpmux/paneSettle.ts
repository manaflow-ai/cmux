// While the pane renders a snapshot as a transition, the live stores (liveThought, liveCallLine,
// liveToolOutput, streamingRow) hold their news until it commits.
//
// A store's notify is a synchronous update (useSyncExternalStore): one that lands while the pane's
// transition render is under way makes React drop that render and start it again from the pane root,
// with the same snapshot. And a store whose value moved under a render it read fails React's tearing
// check at the render's end, which renders the pane root again, synchronously. Under a busy session
// that was most of the pane's renders: 282 of 569 drew a snapshot the pane had already rendered
// (scripts/measure/replay-under-load.sh RENDERS=1). So while a draw is pending, each store's
// notify waits here (the newest per key), and its hook reads the value it last read; the draw's
// commit lets them go, and each row takes its news in that same frame.

/// The pane draws that have not committed yet.
const pending = new Set<object>();
const queue = new Map<string, () => void>();
let timer: ReturnType<typeof setTimeout> | undefined;

/// A draw that takes longer than this lets the stores go anyway: a row's news never waits on a
/// render that does not end.
const HOLD_MS = 400;

export function settleHeld(): boolean {
  return pending.size > 0;
}

/// `owner` (a pane's pending draw) began a transition draw.
export function holdSettle(owner: object): void {
  pending.add(owner);
  if (timer === undefined) timer = setTimeout(releaseAll, HOLD_MS);
}

/// `owner`'s draw committed, was overtaken by an urgent one, or the pane stopped.
export function releaseSettle(owner: object): void {
  if (!pending.delete(owner) || pending.size > 0) return;
  flush();
}

function releaseAll(): void {
  timer = undefined;
  pending.clear();
  flush();
}

function flush(): void {
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  if (queue.size === 0) return;
  const due = [...queue.values()];
  queue.clear();
  for (const run of due) run();
}

/// Runs `notify` now, or once the pending draws commit (the newest per `key`).
export function whenSettled(key: string, notify: () => void): void {
  if (pending.size === 0) notify();
  else queue.set(key, notify);
}

/// `read` (a useSyncExternalStore getSnapshot) that keeps its last value while a draw is pending, so
/// a store that moved under the pane's render does not fail React's tearing check. Make one per
/// hook-render's `read` (inside its useCallback or useMemo): a new `read` reads fresh.
export function settledRead<T>(read: () => T): () => T {
  let seen = false;
  let last: T;
  return () => {
    if (seen && pending.size > 0) return last;
    last = read();
    seen = true;
    return last;
  };
}
