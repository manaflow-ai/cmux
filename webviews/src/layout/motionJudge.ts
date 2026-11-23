// The undeclared-move judge: given what a surface drew frame by frame and the moves declared in each frame,
// every box that rested and then moved or resized with no declaration its surface allows is an undeclared
// move (schemas/layout-motion/contract.json). Pure, so the gallery, the dev-build audit and the unit test
// all judge the same way; schemas/layout-motion/vectors.json holds the cases any judge must agree on.
import { REST_FRAMES, SLACK_PX, surfaceById, type MotionEvent } from "./motionContract";

export type JudgeBox = { x: number; y: number; width: number; height: number };

/** One box in one frame. The relation flags are to the targets of the frame's targeted declarations:
 *  `targeted` it is one, holds one or is inside one (or inside the fold one opens at the very bottom);
 *  `after` it follows one in document order; `before` it precedes one that is a fold at the very bottom. */
export type JudgeSample = {
  label: string;
  surface?: string;
  box: JudgeBox;
  animating?: boolean;
  targeted?: boolean;
  after?: boolean;
  before?: boolean;
};

export type JudgeDeclaration = {
  key: number;
  event: MotionEvent;
  scope: "all" | "targets";
  once?: boolean;
  by?: string;
};

export type JudgeFrame = { samples: Map<number | string, JudgeSample>; declared: readonly JudgeDeclaration[] };

export type UndeclaredMove = {
  label: string;
  surface: string;
  frame: number;
  dx: number;
  dy: number;
  dw: number;
  dh: number;
  /** The events open in that frame (none when nothing was declared). */
  during: MotionEvent[];
};

export type MotionVerdict = {
  /** Boxes that made at least one undeclared move: the count the gate reads. */
  undeclared: number;
  /** The first undeclared move of each such box, at most `MAX_LISTED`. */
  moves: UndeclaredMove[];
  /** Boxes that moved under a declaration, by event. */
  declared: Partial<Record<MotionEvent, number>>;
};

const MAX_LISTED = 24;
const round = (value: number) => Math.round(value * 10) / 10;

function covers(declaration: JudgeDeclaration, sample: JudgeSample, dx: number, dy: number): boolean {
  const surface = surfaceById(sample.surface ?? "tracked");
  if (!surface?.moves.includes(declaration.event)) return false;
  if (declaration.scope === "all") return true;
  if (sample.targeted) return true;
  const straight = Math.abs(dx) <= SLACK_PX;
  if (sample.after && dy > 0 && straight) return true; // pushed down by what opened above it
  return !!sample.before && dy < 0 && straight; // the text above a fold at the very bottom rises with it
}

export function judgeMotion(frames: readonly JudgeFrame[]): MotionVerdict {
  const still = new Map<number | string, number>();
  const usedOnce = new Set<string>();
  const flagged = new Set<number | string>();
  const counted = new Map<MotionEvent, Set<number | string>>();
  const moves: UndeclaredMove[] = [];
  for (let index = 1; index < frames.length; index++) {
    const previous = frames[index - 1]!.samples;
    const { samples, declared } = frames[index]!;
    // A move made in the frame a declaration ends is still the declaration's (it laid out that frame).
    const open = [
      ...declared,
      ...frames[index - 1]!.declared.filter((was) => !declared.some((now) => now.key === was.key)),
    ];
    for (const [id, now] of samples) {
      const was = previous.get(id);
      if (!was) {
        still.delete(id);
        continue;
      }
      if (now.animating || was.animating) {
        still.set(id, 0);
        continue;
      }
      const dx = now.box.x - was.box.x;
      const dy = now.box.y - was.box.y;
      const dw = now.box.width - was.box.width;
      const dh = now.box.height - was.box.height;
      const moved = Math.max(Math.abs(dx), Math.abs(dy), Math.abs(dw), Math.abs(dh)) > SLACK_PX;
      if (!moved) {
        still.set(id, (still.get(id) ?? 0) + 1);
        continue;
      }
      const rested = (still.get(id) ?? 0) >= REST_FRAMES;
      if (!rested) {
        still.set(id, 0);
        continue;
      }
      const by = open.find((declaration) => {
        if (!covers(declaration, now, dx, dy)) return false;
        if (!declaration.once) return true;
        const key = `${declaration.key}:${id}`;
        if (usedOnce.has(key)) return false;
        usedOnce.add(key);
        return true;
      });
      if (by) {
        const set = counted.get(by.event) ?? new Set();
        set.add(id);
        counted.set(by.event, set);
        continue;
      }
      if (flagged.has(id)) continue;
      flagged.add(id);
      if (moves.length < MAX_LISTED)
        moves.push({
          label: now.label,
          surface: now.surface ?? "tracked",
          frame: index,
          dx: round(dx),
          dy: round(dy),
          dw: round(dw),
          dh: round(dh),
          during: [...new Set(open.map((declaration) => declaration.event))],
        });
    }
  }
  return {
    undeclared: flagged.size,
    moves,
    declared: Object.fromEntries([...counted].map(([event, ids]) => [event, ids.size])),
  };
}
