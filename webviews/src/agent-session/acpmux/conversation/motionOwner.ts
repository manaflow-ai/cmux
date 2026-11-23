// The transcript's motion owner: `transition(cause, anchorRow)` (docs/design/transcript-motion-model.md,
// "The owner, and what a row may no longer do"; rules 7 and 8).
//
// A row asks for a change; the owner runs it as one transition:
// 1. read the anchor `(rowId, offsetPx)` before anything changes;
// 2. lay out the final state (`apply`, synchronously);
// 3. measure, and restore the anchor so its row stays on its pixel;
// 4. play at most one transform/opacity FLIP per row, on one clock (the caller's `play`, optional);
// 5. end in one `settle`: no transform left, every mounted row measured again.
// Before step 2 it declares the move to the layout watcher (`layoutWatch.expect`) for the rows it
// names, so a move the owner did not start is a flagged move. Nothing else calls `expect`.
//
// The list it drives is injected (`MotionList`): today VirtualTranscript's placement path, later the
// anchored list (#45412). The model is the same on both, so nothing here waits for that flip.
//
// Stop condition: one timer per transition, ended at `ms` (or early by `end`), and a transition
// started on the same list ends the one before it (its settle runs first).

import { expect } from "./layoutWatch";

export type Anchor = { rowId: string; offsetPx: number };

export type TransitionCause =
  | "disclosure"
  | "turn-end"
  | "card-leave"
  | "gap-read"
  | "room"
  | "append"
  | (string & Record<never, never>);

/// What the owner needs from the list.
export type MotionList = {
  /// The anchor row's offset from the viewport's top, or undefined when it is not mounted.
  offsetOf(rowId: string): number | undefined;
  /// Move the scroll offset by `deltaPx` (the list is the only scroll writer).
  scrollBy(deltaPx: number): void;
  /// The ids of the rows that may move: the anchor's followers in list order.
  rowsAfter(rowId: string): string[];
  /// Measure every mounted row again and place them once; clear any transform left on a row.
  settle(): void;
};

export type TransitionRequest = {
  cause: TransitionCause;
  anchorRow: string;
  /// Rows the change may move; default: the anchor's followers.
  rows?: readonly string[];
  /// How long the motion plays, including its settle frame.
  ms: number;
  /// Lay out the final state (open a fold, swap a row's phase). Runs synchronously.
  apply?: () => void;
  /// Play the FLIP for the moved rows from their old offsets (transform/opacity only).
  play?: (rows: readonly string[]) => void;
};

export type Transition = {
  cause: TransitionCause;
  anchor: Anchor | undefined;
  rows: readonly string[];
  /// End now: settle and close the watcher's window.
  end(): void;
  readonly ended: boolean;
};

const running = new WeakMap<MotionList, Transition>();

/**
 * Run one transition on `list`. Returns at once with a handle; the transition settles at `ms` (or
 * when `end` is called, or when the next transition on the same list starts).
 */
export function transition(
  list: MotionList,
  request: TransitionRequest,
  timers: { set: (run: () => void, ms: number) => unknown; clear: (handle: unknown) => void } = {
    set: (run, ms) => setTimeout(run, ms), // motion-allow: the transition's one end timer, not an animation
    clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  },
): Transition {
  running.get(list)?.end();
  const before = list.offsetOf(request.anchorRow);
  const anchor = before === undefined ? undefined : { rowId: request.anchorRow, offsetPx: before };
  const rows = request.rows ?? list.rowsAfter(request.anchorRow);
  const close = expect(request.cause, { rows, ms: request.ms, anchorRow: request.anchorRow });
  request.apply?.();
  if (anchor) {
    const after = list.offsetOf(anchor.rowId);
    if (after !== undefined && Math.abs(after - anchor.offsetPx) > 0.5) list.scrollBy(after - anchor.offsetPx);
  }
  request.play?.(rows);
  let ended = false;
  let handle: unknown;
  const item: Transition = {
    cause: request.cause,
    anchor,
    rows,
    get ended() {
      return ended;
    },
    end() {
      if (ended) return;
      ended = true;
      timers.clear(handle);
      if (running.get(list) === item) running.delete(list);
      list.settle();
      close();
    },
  };
  handle = timers.set(() => item.end(), Math.max(0, request.ms));
  running.set(list, item);
  return item;
}

/// The transition playing on `list`, if any.
export const runningTransition = (list: MotionList): Transition | undefined => running.get(list);
