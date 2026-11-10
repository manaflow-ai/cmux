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
// - the mounted rows, where they are placed or moved, do not reach past the view's end: a close
//   would show a gap the virtualizer has not mounted rows for, or the transcript's end is in view
//   or within a screen of it,
//   which the transcript places itself (the bottom pinned while a fold plays there, the room under
//   the last reply and the dock's); or a close would end the scroll range above the view.
// Work per frame is O(mounted rows), never O(transcript rows).
import { heightFoldInFlight } from "./fold";

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

export type FoldRideOptions = {
  /// The height the transcript placed `row` at (its drawn height in the last render), if any.
  placed: (row: HTMLElement) => number | undefined;
  /// The height `row` lays out at now.
  height: (row: HTMLElement) => number | undefined;
  /// Places every row at its drawn height now (the transcript's one render at the fold's end).
  finish: (rows: HTMLElement[]) => void;
  /// The disclosure line the transcript holds in place while its fold plays, and the view top it is
  /// held at, if any.
  held?: () => { toggle: HTMLElement; top: number } | undefined;
};

export class FoldRide {
  /// Each folding row and how far its height is from where the transcript placed it.
  private readonly folds = new Map<HTMLElement, number>();
  /// The rows wearing a ride's translate.
  private readonly moved = new Set<HTMLElement>();
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
    // A fold above the held line in its own row moves it with no shift of its row: measured.
    if (held && Math.abs(held.toggle.getBoundingClientRect().top - held.top) >= 0.5) return this.release();
    this.watch(scroller.ownerDocument.defaultView);
    return true;
  }

  /// Lets every row go (no translate) and forgets the folds. Returns false, for `ride`'s callers.
  release(): false {
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
