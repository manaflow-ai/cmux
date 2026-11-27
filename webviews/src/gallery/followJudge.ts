// Follow judge: tells the follow a transcript makes on purpose from a real shift, frame by frame
// (Leo, 2026-11-18: the correctness of the layout shifts, without delay). The box score
// (shift.ts `scoreBoxFrames`) counts every move a scroll made, so a bottom-pinned reply that streams
// scores as high as a row that jumps. Here each frame is judged on its own, by where each box paints
// (`shown`: its box less its own clip, and for a box that is not a row less what a scroller or popup
// around it cuts off):
//   - the follow is the one vertical translation the transcript rows share in that frame (the dy
//     most of them moved by). Rows stay packed: a row keeps its gap to the judged rows next to it,
//     so a row that grows (a reply's new line, a call opened) moves the rows past it by its growth
//     and that is not a shift, while a row that jumps away from its neighbour is. A row with no
//     judged neighbour must move by the follow. Gaps are between painted edges (a reply clipped
//     over the line under it ends where it paints);
//   - the running turn's live line while pinned (pinnedLiveLine.ts, `pinned`: held still against the
//     follow chase, the reply's new lines showing from under it, the reply clipped at the line's drawn
//     top, then coming home over it once the clip is let go) may hold, follow, or move anything
//     between (it rides with the thread as far as the chase had drawn it when taken), or keep its gap
//     as any row does (a call opened over it pushes it down). It votes for no follow. A pinned line
//     that drops while the rows rise with nothing grown over it, or a line that drops away from the
//     reply while not pinned, strays;
//   - the composer and its bar never move: judged by their bottom edge, which the dock holds, so a
//     card that shrinks when its draft is sent is not a move;
//   - any other tracked box (a menu, a list row) moves by the follow or not at all. One that changes
//     size is judged by the edge it holds. One inside another tracked box (an option in its listbox)
//     may instead keep its place in that box, and one in a scroller (`port`: the model picker's
//     listbox) may keep its place in the scroller while the scroller holds, by an edge it kept as it
//     grew: when More models opens, the picker grows up from its chip with its bottom held, the
//     scroller with it, the listbox at the scroller's top and its options at the listbox's top; when
//     the highlight moves past the rows in view, the list scrolls and the options keep their places
//     in the listbox, whose painted box holds. A popup that jumps without resizing still strays (its
//     options go with it, so the popup alone is named), as does one that grows with no edge held;
//   - no tracked box moves sideways;
//   - the follow keeps its direction: rows that rise and then drop back within `REVERSE_FRAMES`
//     frames (or the other way round) bounced, though every row moved together. That move is listed
//     as `follow reversed`, with the frame's follow as dy and the one before it as follow.
// A box that breaks a rule is a stray move: the state, step, frame, box and px a fix must remove.
// Not judged: a box new or gone this frame (or painting nothing), one a keyframe animation moves (an
// entrance), one the turn's end fold slides (`folding`: turnEndFold.ts plays the rows above and below
// the work it takes away on a script-driven FLIP, so the gap closes over its settle by design), the
// step's own target (the row the click opens), and with `firstMoveFree` a box's first move after a
// resize (the new width laying it out once), and a row next to one that arrived this frame with no
// judged neighbour on its other side (the arrival moved it). Sizes are not judged, only where boxes sit.
import { MOVE_SLACK, type Box, type BoxFrame, type BoxSample } from "./shift";

export type StrayMove = { label: string; frame: number; dx: number; dy: number; follow: number };
export type FollowJudgement = {
  /** Frames in which anything moved. */
  movingFrames: number;
  /** Frames whose only moves were the shared follow. */
  followFrames: number;
  /** Frames with a stray move. */
  strayFrames: number;
  /** The first `MAX_STRAY` stray moves, in frame order. */
  stray: StrayMove[];
  /** The largest stray move in px (the longer of dx and the distance from the follow). */
  worst: number;
};

/** Stray moves listed in a judgement; the counts still cover every frame. */
export const MAX_STRAY = 24;
/** A follow that turns round within this many frames of the last one bounced. */
export const REVERSE_FRAMES = 3;
/** The label of a bounce: the rows' shared follow turned round. */
export const FOLLOW_REVERSED = "follow reversed";

const round = (value: number) => Math.round(value * 10) / 10;

/** The translation most rows share: the dy with the most rows within `MOVE_SLACK` of it (ties: the
 *  smaller move), 0 when no row is judged. */
export function sharedFollow(dys: readonly number[]): number {
  let best = 0;
  let bestCount = 0;
  for (const candidate of dys) {
    const count = dys.filter((dy) => Math.abs(dy - candidate) <= MOVE_SLACK).length;
    if (count > bestCount || (count === bestCount && Math.abs(candidate) < Math.abs(best))) {
      best = candidate;
      bestCount = count;
    }
  }
  return best;
}

const isRow = (sample: BoxSample) => sample.row ?? /\[row /.test(sample.label);
const isComposer = (sample: BoxSample) => sample.composer ?? /acpmux-composer-(box|bar)/.test(sample.label);
/** Where a box paints (`shown`), or all of it. */
const painted = (sample: BoxSample): Box => sample.shown ?? sample.box;
/** Moved by something the judge does not judge: a keyframe animation or the turn's end fold. */
const unjudged = (sample: BoxSample) => Boolean(sample.animating || sample.folding);
const bottomOf = (box: Box) => box.y + box.height;
const rightOf = (box: Box) => box.x + box.width;

/**
 * For each judged row next to another placed row (adjacent, top to bottom, in both frames), how far
 * the gap between them changed this frame: the larger change of its gap to the row above and to the
 * row below. Rows that stay packed while one of them changes size report 0. A placed row is in both
 * frames and nothing the judge leaves alone (a keyframe animation, the turn's end fold) moves it: the
 * step's target (a call clicked open) is placed, though not judged itself, so the rows it pushes keep
 * their gap to it. Gaps are between painted edges (`shown`).
 *
 * With `rest` (each pair's gap when the pair was first seen, kept across frames), a gap is judged by
 * how far it moved away from its rest: a gap that closes back to it reports 0. A reply's new line
 * that lands in the live line's room (followGlide.ts) closes the gap under it, and the follow a frame
 * later opens it back to its rest: the rows came back together, which is not a shift.
 */
export function rowGapMoves(
  previous: BoxFrame,
  current: BoxFrame,
  judged: ReadonlySet<number>,
  rest?: Map<string, number>,
): Map<number, number> {
  const placed = (id: number) => {
    const was = previous.get(id);
    const now = current.get(id);
    return Boolean(was && now && !unjudged(was) && !unjudged(now));
  };
  const order = (frame: BoxFrame) =>
    [...frame]
      .filter(([, sample]) => isRow(sample))
      .sort(([, a], [, b]) => painted(a).y - painted(b).y)
      .map(([id]) => id);
  const before = order(previous);
  const after = order(current);
  const nextBefore = new Map(before.slice(0, -1).map((id, index) => [id, before[index + 1]!]));
  const gaps = new Map<number, number>();
  for (let index = 0; index + 1 < after.length; index++) {
    const above = after[index]!;
    const below = after[index + 1]!;
    if (!placed(above) || !placed(below) || nextBefore.get(above) !== below) continue;
    const gap = (frame: BoxFrame) => painted(frame.get(below)!).y - bottomOf(painted(frame.get(above)!));
    const was = gap(previous);
    const now = gap(current);
    let change = now - was;
    // The gap to a pinned live line judges the line alone: the reply over it comes home on the
    // chase while the line holds, so that gap says nothing of the reply. Its rest is not learned
    // while the pin holds (the reply's clip closes it to the line's top).
    const pinned = (id: number) => Boolean(current.get(id)!.pinned || previous.get(id)!.pinned);
    if (rest && !pinned(above) && !pinned(below)) {
      const key = `${above}:${below}`;
      if (!rest.has(key)) rest.set(key, was);
      const atRest = rest.get(key)!;
      if (Math.abs(now - atRest) <= Math.abs(was - atRest)) change = 0;
    }
    for (const [id, other] of [
      [above, below],
      [below, above],
    ] as const)
      if (judged.has(id) && !pinned(other) && Math.abs(change) >= Math.abs(gaps.get(id) ?? 0)) gaps.set(id, change);
  }
  // A row next to one that arrived this frame is moved by the arrival (a reply's first row in over
  // the live line): 0, unless a judged neighbour on its other side says otherwise.
  for (let index = 0; index + 1 < after.length; index++) {
    const pair = [after[index]!, after[index + 1]!];
    for (const [id, other] of [pair, [pair[1], pair[0]]] as [number, number][])
      if (judged.has(id) && !previous.has(other) && !gaps.has(id)) gaps.set(id, 0);
  }
  return gaps;
}

/** How a box that is not a row moved, by its painted edges: its leading ones, or when its laid-out
 *  box changed size along an axis, the edge it held there (the smaller move of its two). A box that
 *  only shows more or less of itself (a scroller cutting it) is still judged by its leading edges. */
function heldEdgeMove(from: Box, to: Box, laidFrom: Box = from, laidTo: Box = to): { dx: number; dy: number } {
  const held = (start: number, end: number, size: number) =>
    Math.abs(size) > MOVE_SLACK && Math.abs(end) < Math.abs(start) ? end : start;
  return {
    dx: held(to.x - from.x, rightOf(to) - rightOf(from), laidTo.width - laidFrom.width),
    dy: held(to.y - from.y, bottomOf(to) - bottomOf(from), laidTo.height - laidFrom.height),
  };
}

/** How far a laid-out box moved from its place in the box that holds it (its tracked holder, or the
 *  scroller it sits in): sideways, and the nearer of its offset to the holder's top and to its
 *  bottom. Both are laid-out boxes, so a box scrolled with its holder's content keeps its place. */
function offPlace(was: Box, now: Box, holderWas: Box, holderNow: Box): number {
  const side = now.x - holderNow.x - (was.x - holderWas.x);
  const top = now.y - holderNow.y - (was.y - holderWas.y);
  const bottom = bottomOf(now) - bottomOf(holderNow) - (bottomOf(was) - bottomOf(holderWas));
  return Math.max(Math.abs(side), Math.min(Math.abs(top), Math.abs(bottom)));
}

/** How far a box that is not a row strayed, given its move: sideways, or off both the follow and
 *  its place. */
const boxOff = ({ dx, dy }: { dx: number; dy: number }, follow: number) =>
  Math.max(Math.abs(dx), Math.min(Math.abs(dy - follow), Math.abs(dy)));

/** How far `value` lies outside the range between `a` and `b` (0 inside it). */
const outside = (value: number, a: number, b: number) => Math.max(0, Math.min(a, b) - value, value - Math.max(a, b));

/** The samples the judge reads: a box that paints nothing (its clip took all of it) is not in view. */
const paintedFrame = (frame: BoxFrame): BoxFrame =>
  new Map([...frame].filter(([, sample]) => painted(sample).width > 0 && painted(sample).height > 0));

/** Judges a run of frames (`startBoxTracker`'s samples) as follow or stray, frame by frame. */
export function judgeFollowFrames(frames: BoxFrame[], options: { firstMoveFree?: boolean } = {}): FollowJudgement {
  frames = frames.map(paintedFrame);
  const freeUsed = new Set<number>();
  const restGaps = new Map<string, number>();
  const stray: StrayMove[] = [];
  let movingFrames = 0;
  let followFrames = 0;
  let strayFrames = 0;
  let worst = 0;
  let lastFollow = { frame: -REVERSE_FRAMES - 1, dy: 0 };
  for (let index = 1; index < frames.length; index++) {
    const previous = frames[index - 1]!;
    const current = frames[index]!;
    const moves: { id: number; sample: BoxSample; was: BoxSample; dx: number; dy: number }[] = [];
    // The rows the turn's end fold slides: not judged one by one, but what they paint still turns
    // the follow round (a fold that drops the rows back right after they rose bounced them).
    const folded: number[] = [];
    for (const [id, now] of current) {
      const was = previous.get(id);
      if (was && isRow(now) && !now.animating && !was.animating && !now.targeted && (now.folding || was.folding))
        folded.push(painted(now).y - painted(was).y);
      if (!was || unjudged(now) || unjudged(was) || now.targeted) continue;
      const from = painted(was);
      const to = painted(now);
      // The dock holds the composer's bottom edge; its top follows its draft's height.
      const { dx, dy } = isComposer(now)
        ? { dx: to.x - from.x, dy: bottomOf(to) - bottomOf(from) }
        : isRow(now)
          ? { dx: to.x - from.x, dy: to.y - from.y }
          : heldEdgeMove(painted(was), painted(now), was.box, now.box);
      if (options.firstMoveFree && (Math.abs(dx) > MOVE_SLACK || Math.abs(dy) > MOVE_SLACK) && !freeUsed.has(id)) {
        freeUsed.add(id);
        continue;
      }
      moves.push({ id, sample: now, was, dx, dy });
    }
    // Every frame, still or not: a pair's rest is its gap when first seen.
    const gapMoves = rowGapMoves(previous, current, new Set(moves.map(({ id }) => id)), restGaps);
    if (
      !moves.some(({ dx, dy }) => Math.abs(dx) > MOVE_SLACK || Math.abs(dy) > MOVE_SLACK) &&
      !folded.some((dy) => Math.abs(dy) > MOVE_SLACK)
    )
      continue;
    movingFrames++;
    const rowDys = moves.filter(({ sample }) => isRow(sample) && !sample.pinned).map(({ dy }) => dy);
    const follow = sharedFollow(rowDys);
    // The direction the rows painted this frame, the fold's included.
    const trend = folded.length ? sharedFollow([...rowDys, ...folded]) : follow;
    let strayHere = false;
    for (const { id, sample, was, dx, dy } of moves) {
      const offFollow = Math.abs(dy - follow);
      const still = Math.abs(dy);
      // A row next to a judged row keeps its gap to it: a row that grows or shrinks moves the rows
      // past it by its change, which is not a shift. A row off the follow strays by the lesser of
      // the two (the follow's rows are not blamed for a gap a neighbour opened). A row with no
      // judged neighbour is judged by the follow.
      const gap = gapMoves.get(id);
      let off = isComposer(sample)
        ? Math.max(Math.abs(dx), still)
        : isRow(sample)
          ? Math.max(Math.abs(dx), gap === undefined ? offFollow : Math.min(offFollow, Math.abs(gap)))
          : boxOff({ dx, dy }, follow);
      // The pinned live line may also hold, follow, or anything between: it rides with the thread
      // only as far as the chase had drawn it when it was taken (pinnedLiveLine.ts `cap`).
      if (sample.pinned || was.pinned) off = Math.min(off, Math.max(Math.abs(dx), outside(dy, 0, follow)));
      if (off > MOVE_SLACK && !isRow(sample) && !isComposer(sample)) {
        // A box inside another tracked box (an option in its listbox) may keep its place in it
        // instead: that box is judged on its own.
        const holderWas = sample.within === undefined ? undefined : previous.get(sample.within);
        const holderNow = sample.within === undefined ? undefined : current.get(sample.within);
        if (holderWas && holderNow && !unjudged(holderWas) && !unjudged(holderNow))
          off = Math.min(off, offPlace(was.box, sample.box, holderWas.box, holderNow.box));
        // So may a box in a scroller (the picker's listbox), if the scroller itself held (by an
        // edge it kept, as it grew).
        if (was.port && sample.port)
          off = Math.min(
            off,
            Math.max(
              offPlace(was.box, sample.box, was.port, sample.port),
              boxOff(heldEdgeMove(was.port, sample.port), follow),
            ),
          );
      }
      if (off <= MOVE_SLACK) continue;
      strayHere = true;
      worst = Math.max(worst, off);
      if (stray.length < MAX_STRAY)
        stray.push({ label: sample.label, frame: index, dx: round(dx), dy: round(dy), follow: round(follow) });
    }
    if (Math.abs(trend) > MOVE_SLACK) {
      const turned =
        index - lastFollow.frame <= REVERSE_FRAMES &&
        Math.abs(lastFollow.dy) > MOVE_SLACK &&
        Math.sign(trend) !== Math.sign(lastFollow.dy);
      if (turned) {
        strayHere = true;
        worst = Math.max(worst, Math.abs(trend));
        if (stray.length < MAX_STRAY)
          stray.push({ label: FOLLOW_REVERSED, frame: index, dx: 0, dy: round(trend), follow: round(lastFollow.dy) });
      }
      lastFollow = { frame: index, dy: trend };
    }
    if (strayHere) strayFrames++;
    else followFrames++;
  }
  return { movingFrames, followFrames, strayFrames, stray, worst: round(worst) };
}
