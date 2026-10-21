// The sync motion model (plans/cmux-next/sync-ux/DESIGN.md, part 1): how a list of synced objects
// (workspaces, tabs, sessions, sidebar groups, conversations) moves when its state changes, from
// this client, another client, a remote host or a Chief. The same rules hold on the Mac (AppKit),
// in the web views and on iOS; only the drawing differs.
//
// 1. Identity: a row is its object id (object-sync DESIGN 5.3). A rename changes a field, never
//    the key, so a renamed row never remounts; an optimistic row takes its confirmed id in place.
// 2. Diff by id between what is drawn and what the new state says: insert, remove, move, rename.
//    The planner never looks at positions alone.
// 3. Batch: every change that arrives before the next frame is one transition (one plan, one
//    spring per row). A burst of 20 renames in 3 ms is one crossfade per row, not 20.
// 4. No motion for: the first state a list shows, a snapshot that replaces the state (resync,
//    reconnect, a gap), a change that moves more than `BURST_MOVE_LIMIT` rows at once, rows that
//    are off screen before and after, and the local user's own change that was already drawn
//    optimistically (it diffs to nothing).
// 5. Springs from the motion tokens (design-tokens.json `motion.springs`, plans/cmux-next/motion.md):
//    moves `move`, inserts `appear`, removals `disappear`, all critically damped. A new change
//    mid-motion starts from what is on screen.
// 6. Reduce Motion: positions and sizes change in one frame; only a rename keeps a crossfade of at
//    most `crossfade` (motion.md rule 7). `ui.animationSpeed` off: everything in one frame.
import {
  MOTION_FADES,
  MOTION_SPRINGS,
  springStepResponse,
  springVisibleEnd,
  type SpringParameters,
} from "../files-panel-motion";

/** Motion springs at speed "fast": the app's (MotionTunables.springDefaults, MOTION_SPRINGS). */
export const SYNC_SPRINGS = {
  move: MOTION_SPRINGS.move,
  appear: MOTION_SPRINGS.appear,
  disappear: MOTION_SPRINGS.disappear,
} as const satisfies Record<string, SpringParameters>;

/** Fade tokens in ms at speed "fast": the motion scale's steps, and the Reduce Motion crossfade. */
export const SYNC_FADES = {
  fadeIn: MOTION_FADES.fadeIn,
  fadeOut: MOTION_FADES.fadeOut,
  crossfade: MOTION_FADES.crossfade,
} as const;

/** A change that moves more rows than this at once is a re-sort, not a move: it applies at once. */
export const BURST_MOVE_LIMIT = 12;

/** Who made a change (object-sync DESIGN 5.3 item 5). */
export type SyncOrigin = "local" | "remote";

/** One row as the list draws it: its id, the text that may be renamed, and its order. */
export type SyncRow = { id: string; title: string };

export type SyncChangeKind = "insert" | "remove" | "move" | "rename";

export type SyncRowPlan = {
  id: string;
  kinds: SyncChangeKind[];
  /** False: the row takes its new state in one frame. */
  animate: boolean;
};

export type SyncPlan = {
  /** Why the whole change applies at once, if it does. */
  still?: "initial" | "snapshot" | "burst" | "motion-off" | "direct";
  rows: SyncRowPlan[];
};

export type SyncPlanInput = {
  before: readonly SyncRow[] | undefined;
  after: readonly SyncRow[];
  /** The change replaced the state (resync, reconnect, a gap): no motion. */
  snapshot?: boolean;
  /** Rows on screen before or after the change; absent: every row is on screen. */
  visible?: (id: string) => boolean;
  /** Animations off (`ui.animationSpeed` off). Reduce Motion is not this: see `reduced`. */
  motionOff?: boolean;
  /** Reduce Motion: no movement; a rename keeps a short crossfade. */
  reduced?: boolean;
  /**
   * The change is this client's own direct manipulation (a drag that already left the row at its
   * drop place, an inline rename the user just typed): the screen already shows it.
   */
  direct?: boolean;
};

/**
 * Moved rows: those whose position among the rows present before and after changed, by the
 * longest increasing subsequence of old positions (the rows that kept their relative order stay;
 * the others moved). A row pushed down by an insert above is not "moved": its slide comes from
 * the layout delta, which the drawing layer measures.
 */
function movedIds(before: readonly SyncRow[], after: readonly SyncRow[]): Set<string> {
  const oldIndex = new Map(before.map((row, index) => [row.id, index] as const));
  const common = after.filter((row) => oldIndex.has(row.id)).map((row) => row.id);
  const seq = common.map((id) => oldIndex.get(id) as number);
  // Patience LIS, O(n log n).
  const tails: number[] = [];
  const tailIndex: number[] = [];
  const previous: number[] = Array.from({ length: seq.length }, () => -1);
  for (let index = 0; index < seq.length; index += 1) {
    let low = 0;
    let high = tails.length;
    while (low < high) {
      const mid = (low + high) >> 1;
      if (tails[mid] < seq[index]) low = mid + 1;
      else high = mid;
    }
    tails[low] = seq[index];
    tailIndex[low] = index;
    previous[index] = low > 0 ? tailIndex[low - 1] : -1;
  }
  const kept = new Set<string>();
  for (let index = tails.length > 0 ? tailIndex[tails.length - 1] : -1; index >= 0; index = previous[index])
    kept.add(common[index]);
  return new Set(common.filter((id) => !kept.has(id)));
}

/** The transition from `before` to `after`, keyed by id. */
export function planSyncChange(input: SyncPlanInput): SyncPlan {
  const { before, after } = input;
  const visible = input.visible ?? (() => true);
  const still: SyncPlan["still"] =
    before === undefined
      ? "initial"
      : input.snapshot
        ? "snapshot"
        : input.motionOff
          ? "motion-off"
          : input.direct
            ? "direct"
            : undefined;
  const previous = new Map((before ?? []).map((row) => [row.id, row] as const));
  const next = new Map(after.map((row) => [row.id, row] as const));
  const moved = before ? movedIds(before, after) : new Set<string>();
  const burst = moved.size > BURST_MOVE_LIMIT;
  const rows: SyncRowPlan[] = [];
  for (const row of after) {
    const was = previous.get(row.id);
    const kinds: SyncChangeKind[] = [];
    if (!was) kinds.push("insert");
    else {
      if (moved.has(row.id)) kinds.push("move");
      if (was.title !== row.title) kinds.push("rename");
    }
    rows.push({ id: row.id, kinds, animate: false });
  }
  for (const row of before ?? []) if (!next.has(row.id)) rows.push({ id: row.id, kinds: ["remove"], animate: false });
  const overall = still ?? (burst ? "burst" : undefined);
  for (const plan of rows) {
    if (plan.kinds.length === 0 || overall !== undefined || !visible(plan.id)) continue;
    // Reduce Motion: only the rename crossfade survives.
    plan.animate = input.reduced ? plan.kinds.includes("rename") : true;
  }
  return { still: overall, rows };
}

/** Linear keyframe samples of a spring's step response (0 to exactly 1) and its visible length. */
export function springSamples(spring: SpringParameters, samples = 24): { durationMs: number; progress: number[] } {
  const end = springVisibleEnd(spring);
  const progress: number[] = [];
  for (let index = 0; index <= samples; index += 1)
    progress.push(
      index === samples ? 1 : Math.round(springStepResponse(spring, (end * index) / samples) * 10_000) / 10_000,
    );
  return { durationMs: Math.round(end * 1000), progress };
}

/**
 * Coalesces events that arrive before the next frame into one apply (rule 3). Event driven:
 * the first event of a burst asks for one frame; nothing runs while no event arrives.
 */
export function createFrameBatcher<E>(
  apply: (events: E[]) => void,
  schedule: (callback: () => void) => unknown = (callback) => requestAnimationFrame(callback),
): { push(event: E): void; flush(): void } {
  let queue: E[] = [];
  let pending = false;
  const flush = () => {
    pending = false;
    if (queue.length === 0) return;
    const events = queue;
    queue = [];
    apply(events);
  };
  return {
    push(event) {
      queue.push(event);
      if (pending) return;
      pending = true;
      schedule(flush);
    },
    flush,
  };
}
