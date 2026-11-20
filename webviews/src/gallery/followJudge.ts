// Follow judge: tells the follow a transcript makes on purpose from a real shift, frame by frame
// (Leo, 2026-11-18: the correctness of the layout shifts, without delay). The box score
// (shift.ts `scoreBoxFrames`) counts every move a scroll made, so a bottom-pinned reply that streams
// scores as high as a row that jumps. Here each frame is judged on its own:
//   - the follow is the one vertical translation the transcript rows share in that frame (the dy
//     most of them moved by). Rows stay packed: a row keeps its gap to the judged rows next to it,
//     so a row that grows (a reply's new line, a call opened) moves the rows past it by its growth
//     and that is not a shift, while a row that jumps away from its neighbour is. A row with no
//     judged neighbour must move by the follow;
//   - the composer and its bar never move: judged by their bottom edge, which the dock holds, so a
//     card that shrinks when its draft is sent is not a move;
//   - any other tracked box (a menu, a list row) moves by the follow or not at all;
//   - no tracked box moves sideways;
//   - the follow keeps its direction: rows that rise and then drop back within `REVERSE_FRAMES`
//     frames (or the other way round) bounced, though every row moved together. That move is listed
//     as `follow reversed`, with the frame's follow as dy and the one before it as follow.
// A box that breaks a rule is a stray move: the state, step, frame, box and px a fix must remove.
// Not judged: a box new or gone this frame, one a keyframe animation moves (an entrance), the
// step's own target (the row the click opens), and with `firstMoveFree` a box's first move after a
// resize (the new width laying it out once), and a row next to one that arrived this frame with no
// judged neighbour on its other side (the arrival moved it). Sizes are not judged, only where boxes sit.
import { MOVE_SLACK, type BoxFrame, type BoxSample } from "./shift";

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

/**
 * For each judged row next to another placed row (adjacent, top to bottom, in both frames), how far
 * the gap between them changed this frame: the larger change of its gap to the row above and to the
 * row below. Rows that stay packed while one of them changes size report 0. A placed row is in both
 * frames and no keyframe animation moves it: the step's target (a call clicked open) is placed,
 * though not judged itself, so the rows it pushes keep their gap to it.
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
    return Boolean(was && now && !was.animating && !now.animating);
  };
  const order = (frame: BoxFrame) =>
    [...frame]
      .filter(([, sample]) => isRow(sample))
      .sort(([, a], [, b]) => a.box.y - b.box.y)
      .map(([id]) => id);
  const before = order(previous);
  const after = order(current);
  const nextBefore = new Map(before.slice(0, -1).map((id, index) => [id, before[index + 1]!]));
  const gaps = new Map<number, number>();
  for (let index = 0; index + 1 < after.length; index++) {
    const above = after[index]!;
    const below = after[index + 1]!;
    if (!placed(above) || !placed(below) || nextBefore.get(above) !== below) continue;
    const gap = (frame: BoxFrame) => frame.get(below)!.box.y - (frame.get(above)!.box.y + frame.get(above)!.box.height);
    const was = gap(previous);
    const now = gap(current);
    let change = now - was;
    if (rest) {
      const key = `${above}:${below}`;
      if (!rest.has(key)) rest.set(key, was);
      const atRest = rest.get(key)!;
      if (Math.abs(now - atRest) <= Math.abs(was - atRest)) change = 0;
    }
    for (const id of [above, below])
      if (judged.has(id) && Math.abs(change) >= Math.abs(gaps.get(id) ?? 0)) gaps.set(id, change);
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

/** Judges a run of frames (`startBoxTracker`'s samples) as follow or stray, frame by frame. */
export function judgeFollowFrames(frames: BoxFrame[], options: { firstMoveFree?: boolean } = {}): FollowJudgement {
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
    const moves: { id: number; sample: BoxSample; dx: number; dy: number }[] = [];
    for (const [id, now] of current) {
      const was = previous.get(id);
      if (!was || now.animating || was.animating || now.targeted) continue;
      const dx = now.box.x - was.box.x;
      // The dock holds the composer's bottom edge; its top follows its draft's height.
      const dy = isComposer(now) ? now.box.y + now.box.height - (was.box.y + was.box.height) : now.box.y - was.box.y;
      if (options.firstMoveFree && (Math.abs(dx) > MOVE_SLACK || Math.abs(dy) > MOVE_SLACK) && !freeUsed.has(id)) {
        freeUsed.add(id);
        continue;
      }
      moves.push({ id, sample: now, dx, dy });
    }
    // Every frame, still or not: a pair's rest is its gap when first seen.
    const gapMoves = rowGapMoves(previous, current, new Set(moves.map(({ id }) => id)), restGaps);
    if (!moves.some(({ dx, dy }) => Math.abs(dx) > MOVE_SLACK || Math.abs(dy) > MOVE_SLACK)) continue;
    movingFrames++;
    const follow = sharedFollow(moves.filter(({ sample }) => isRow(sample)).map(({ dy }) => dy));
    let strayHere = false;
    for (const { id, sample, dx, dy } of moves) {
      const offFollow = Math.abs(dy - follow);
      const still = Math.abs(dy);
      // A row next to a judged row keeps its gap to it: a row that grows or shrinks moves the rows
      // past it by its change, which is not a shift. A row off the follow strays by the lesser of
      // the two (the follow's rows are not blamed for a gap a neighbour opened). A row with no
      // judged neighbour is judged by the follow.
      const gap = gapMoves.get(id);
      const off = isComposer(sample)
        ? Math.max(Math.abs(dx), still)
        : isRow(sample)
          ? Math.max(Math.abs(dx), gap === undefined ? offFollow : Math.min(offFollow, Math.abs(gap)))
          : Math.max(Math.abs(dx), Math.min(offFollow, still));
      if (off <= MOVE_SLACK) continue;
      strayHere = true;
      worst = Math.max(worst, off);
      if (stray.length < MAX_STRAY)
        stray.push({ label: sample.label, frame: index, dx: round(dx), dy: round(dy), follow: round(follow) });
    }
    if (Math.abs(follow) > MOVE_SLACK) {
      const turned =
        index - lastFollow.frame <= REVERSE_FRAMES &&
        Math.abs(lastFollow.dy) > MOVE_SLACK &&
        Math.sign(follow) !== Math.sign(lastFollow.dy);
      if (turned) {
        strayHere = true;
        worst = Math.max(worst, Math.abs(follow));
        if (stray.length < MAX_STRAY)
          stray.push({ label: FOLLOW_REVERSED, frame: index, dx: 0, dy: round(follow), follow: round(lastFollow.dy) });
      }
      lastFollow = { frame: index, dy: follow };
    }
    if (strayHere) strayFrames++;
    else followFrames++;
  }
  return { movingFrames, followFrames, strayFrames, stray, worst: round(worst) };
}
