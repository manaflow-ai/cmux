// A disclosure's height fold, placed without a React render per frame (Leo, 2026-11-09, on opening a
// turn's "Ran 10 commands" and one step's Shell card: "It just, like, lags pretty heavily ... I don't
// know why it's lagging so much").
//
// A fold plays its body's height (fold.ts `useFold`). Each frame of it the row grows, the
// transcript's ResizeObserver reported the new height and rendered the whole transcript with
// `flushSync`, so the rows under it took their new `top`: about one commit and one forced layout per
// frame, React drawing every mounted row's frame again, all of it script on the frame's critical
// path. At four times slower script (a busy Mac) the fold ran at 30 frames a second or worse.
//
// While only folding rows change size, their height change is a move of the rows under them and
// nothing else: the rows above, the header the reader clicked and the offset stay. So the rows under
// ride: each takes a `translate` of the folding rows' change above it, a compositor-only write, and
// the transcript renders once, when the fold ends, with the rows' final heights (which places them
// where they rode to). The ride gives way to the full placement (the caller renders as before) when:
// - a row that is not folding changed size too (a streamed reply), or a folding row has no drawn
//   height yet;
// - a folding row's top is above the view: holding a line in it may move the offset;
// - the line the reader clicked (the transcript's fold hold) is in a row the ride would move, or has
//   moved from where it is held (another fold above it in its own row): the transcript keeps that
//   line in place by moving the offset, which a translate cannot;
// - any input arrives (`land`): the scroll range and the layout are still the placed ones, which a
//   scroll would clamp to and the map, find or a jump would aim by, so the transcript places the
//   rows before the input reaches anything;
// - the mounted rows, where they are placed or moved, do not reach past the view's end: a close
//   would show a gap the virtualizer has not mounted rows for, or the transcript's end is in view
//   or within a screen of it,
//   which the transcript places itself (the bottom pinned while a fold plays there, the room under
//   the last reply and the dock's); or a close would end the scroll range above the view.
// Work per frame is O(mounted rows), never O(transcript rows).
import { heightFoldInFlight, heightFoldUntil } from "./fold";

/// The mounted transcript rows that are siblings of `row`, with their index (aria-posinset).
function siblingRows(row: HTMLElement): { node: HTMLElement; index: number }[] {
  const out: { node: HTMLElement; index: number }[] = [];
  for (const node of row.parentElement?.children ?? []) {
    if (!(node instanceof HTMLElement) || !node.classList.contains("acpmux-row")) continue;
    out.push({ node, index: Number(node.getAttribute("aria-posinset")) });
  }
  return out;
}

const indexOf = (row: HTMLElement) => Number(row.getAttribute("aria-posinset"));

/// Whether `row` plays an animation of its own now (its subtree's are not its translate's).
const animating = (row: HTMLElement) => row.getAnimations?.().some((each) => each.playState === "running") ?? false;

export type FoldRideOptions = {
  /// The height the transcript placed `row` at (its drawn height in the last render), if any.
  placed: (row: HTMLElement) => number | undefined;
  /// The height `row` lays out at now.
  height: (row: HTMLElement) => number | undefined;
  /// Places every row at its drawn height now (the transcript's one render at the fold's end).
  finish: (rows: HTMLElement[]) => void;
  /// The transcript's drawn heights now (any value that changes when new heights are placed): a
  /// hand-over counts only for a placement of heights newer than the ones it was handed on.
  drawn?: () => unknown;
  /// The disclosure line the transcript holds in place while its fold plays, and the view top it is
  /// held at, if any.
  held?: () => { toggle: HTMLElement; top: number } | undefined;
};

/// A fold the rows showed: its row's id and index (aria-posinset), and its height change.
type HandedFold = { id: string; at: number; delta: number };

export class FoldRide {
  /// Each folding row and how far its height is from where the transcript placed it.
  private readonly folds = new Map<HTMLElement, number>();
  /// The rows wearing a ride's translate.
  private readonly moved = new Set<HTMLElement>();
  /// The folds the rows show now: each folding row's id, index (aria-posinset) and height change.
  private shown: HandedFold[] = [];
  /// The folds the rows showed when the ride let go: the rows under them already show where the
  /// transcript's next placement puts them, which the scroll anchor must not move them by again.
  private handed: HandedFold[] | undefined;
  /// The drawn heights the hand-over was made on (`drawn`).
  private handedOn: unknown;
  /// The folds an input landed (`land`), each by when it ends: the transcript places them to the end,
  /// so a scrub that goes on moving aims by the layout of every frame, not the one it landed on.
  private readonly landed = new WeakMap<HTMLElement, number>();
  private frame: number | undefined;
  private view: (Window & typeof globalThis) | null = null;

  constructor(private readonly options: FoldRideOptions) {}

  /// Whether rows ride now.
  get riding(): boolean {
    return this.folds.size > 0;
  }

  /// Places the rows under the folding `targets` (rows the ResizeObserver reported) by translate.
  /// False when the transcript must render instead; the ride has then let go of every row.
  ride(targets: readonly HTMLElement[]): boolean {
    if (targets.length === 0) return false;
    const scroller = targets[0]!.closest<HTMLElement>(".acpmux-scroll");
    if (!scroller) return this.release();
    const view = scroller.getBoundingClientRect();
    for (const target of targets) {
      if (!target.isConnected || !heightFoldInFlight(target)) return this.release();
      if (this.landed.get(target) === heightFoldUntil(target)) return this.release();
      const placed = this.options.placed(target);
      const height = this.options.height(target);
      if (placed === undefined || height === undefined) return this.release();
      if (target.getBoundingClientRect().top < view.top - 0.5) return this.release();
      this.folds.set(target, height - placed);
    }
    for (const fold of this.folds.keys()) if (!fold.isConnected) this.folds.delete(fold);
    const folds = [...this.folds].map(([node, delta]) => ({ index: indexOf(node), delta }));
    const total = folds.reduce((sum, fold) => sum + fold.delta, 0);
    // A close must leave the view inside the scroll range it ends with, or the offset clamps then.
    if (total < 0 && scroller.scrollTop + scroller.clientHeight > scroller.scrollHeight + total + 0.5)
      return this.release();
    const rows = siblingRows(targets[0]!);
    const shiftOf = (index: number) => folds.reduce((sum, fold) => (fold.index < index ? sum + fold.delta : sum), 0);
    const held = this.options.held?.();
    const heldRow = held?.toggle.closest<HTMLElement>(".acpmux-row");
    if (heldRow && Math.abs(shiftOf(indexOf(heldRow))) >= 0.01) return this.release();
    // The last mounted row must reach past the view's end both where the transcript placed it and
    // where it rides to. Otherwise a close would show rows the virtualizer has not mounted, or the
    // transcript's end is in view, which the transcript places itself: the bottom pinned while a
    // fold plays there, the room under the last reply and the dock's.
    let last: { node: HTMLElement; index: number } | undefined;
    for (const each of rows) if (!last || each.index > last.index) last = each;
    // Rows mounted outside the run (a margin drag's selection holds them) leave unmounted rows
    // between: the last of them says nothing of what a move shows.
    if (last && last.index - Math.min(...rows.map((each) => each.index)) + 1 !== rows.length) return this.release();
    if (!last) return this.release();
    // Its box includes the translate it wears now.
    const worn = parseFloat(last.node.style.translate.split(" ")[1] ?? "") || 0;
    const placedBottom = last.node.getBoundingClientRect().bottom - worn;
    const reach = Math.min(placedBottom, placedBottom + shiftOf(last.index));
    if (reach < view.bottom) return this.release();
    // The transcript's last row within a screen of the view's end: the end's room and its hold on
    // the latest row are the transcript's to place.
    if (Number(last.node.getAttribute("aria-setsize")) === last.index && reach < view.bottom + view.height)
      return this.release();
    // A row still playing its own animation (a live row's entry) may set its translate itself, over
    // the one the ride would write: the transcript places the rows while it plays.
    if (rows.some(({ node, index }) => Math.abs(shiftOf(index)) >= 0.01 && animating(node))) return this.release();
    // A folding row rides the folds above it too (its own change is not in its shift): two folds in
    // flight at once would otherwise overlap while the upper one plays.
    for (const { node, index } of rows) {
      const shift = shiftOf(index);
      if (Math.abs(shift) < 0.01) {
        if (this.moved.delete(node)) node.style.translate = "";
        continue;
      }
      node.style.translate = `0 ${shift}px`;
      this.moved.add(node);
    }
    this.shown = [];
    for (const [node, delta] of this.folds)
      if (node.dataset.rowId !== undefined) this.shown.push({ id: node.dataset.rowId, at: indexOf(node), delta });
    // A fold above the held line in its own row moves it with no shift of its row: measured.
    if (held && Math.abs(held.toggle.getBoundingClientRect().top - held.top) >= 0.5) return this.release();
    this.watch(scroller.ownerDocument.defaultView);
    return true;
  }

  /// The `targets` lay out at the heights the transcript placed them at again (a fold reversed, or
  /// landed at once): the rows under them ride on by what is left of the folds' change, or let go
  /// when they may not ride (`mayRide`) or the ride gives way.
  settled(targets: readonly HTMLElement[], mayRide: boolean): void {
    if (!this.riding || (mayRide && this.ride(targets))) return;
    this.release();
    // No placement follows (the heights are the placed ones): the rows just went back.
    this.handed = undefined;
  }

  /// The folds the rows showed when the ride let go, at their indices in `rows` (the rows the
  /// transcript placed them in), for a placement of the drawn heights `drawn`: none when no row rode,
  /// or when `drawn` are still the heights the ride let go on (a placement before its heights land
  /// moves no row by its fold).
  handedFolds(rows: readonly { id: string }[], drawn: unknown): { index: number; delta: number }[] | undefined {
    if (!this.handed?.length || drawn === this.handedOn) return undefined;
    return this.handed.flatMap(({ id, at, delta }) => {
      const index = rows[at - 1]?.id === id ? at - 1 : rows.findIndex((row) => row.id === id);
      return index < 0 ? [] : [{ index, delta }];
    });
  }

  /// Forgets what the ride handed over, once the transcript placed rows at heights newer than the
  /// ones it was handed on (`drawn`).
  takeHanded(drawn: unknown): void {
    if (drawn !== this.handedOn) this.handed = undefined;
  }

  /// Lets every row go and forgets everything, the hand-over too: the transcript shows another chat,
  /// whose placement has nothing of this one's to account for.
  reset(): void {
    this.release();
    this.handed = undefined;
  }

  /// Places every row at the height it lays out at now, as the fold's end does: the reader scrolls,
  /// and the scroll range must end where the rows show (review of #39917 at 184fed21: a scroll to a
  /// run's foot clamped 1250px short). The folds still playing ride again from there.
  land(): void {
    if (!this.riding) return;
    const folds = [...this.folds.keys()];
    for (const fold of folds) {
      const until = heightFoldUntil(fold);
      if (until !== undefined) this.landed.set(fold, until);
    }
    this.release();
    this.options.finish(folds.filter((fold) => fold.isConnected));
  }

  /// Lets every row go (no translate) and forgets the folds. Returns false, for `ride`'s callers.
  release(): false {
    if (this.moved.size) {
      this.handed = this.shown;
      this.handedOn = this.options.drawn?.();
    }
    this.shown = [];
    for (const node of this.moved) node.style.translate = "";
    this.moved.clear();
    this.folds.clear();
    if (this.frame !== undefined) this.view?.cancelAnimationFrame(this.frame);
    this.frame = undefined;
    return false;
  }

  /// Once no folding row is still in flight, lets go and has the transcript place every row.
  private watch(view: (Window & typeof globalThis) | null) {
    if (this.frame !== undefined || !view) return;
    this.view = view;
    const step = () => {
      this.frame = undefined;
      const folds = [...this.folds.keys()];
      if (folds.some((fold) => fold.isConnected && heightFoldInFlight(fold))) {
        this.frame = view.requestAnimationFrame(step);
        return;
      }
      this.release();
      this.options.finish(folds.filter((fold) => fold.isConnected));
    };
    this.frame = view.requestAnimationFrame(step);
  }
}
