// Counts the separate movement phases in per-frame samples of a few tracked boxes (each frame's
// tops, px; null while a box is not drawn). Leo, 2026-11-22, on a tall send: "when i send it
// collapses the compser then sends it to you... but i think we should be able to calculate it out to
// be like one smooth motion." A phase is a run of frames where something moves; a still frame between
// two runs, a box turning back, or boxes that move at different times (one stops before the
// next starts) each make another. One transition is one phase.

/// One frame: its time from the start (ms) and each tracked box's top.
export type MotionSample<K extends string = string> = { t: number } & { [key in K]: number | null };

export type MotionPhases = {
  phases: number;
  /// The largest move of one box in one frame (px).
  maxJump: number;
  /// Each phase: its frames' times and each box's moving span.
  detail: string[];
};

/// A box moved in a frame when its top changed by more than this (px).
const STILL_PX = 0.5;

export function countMotionPhases<K extends string>(
  frames: readonly MotionSample<K>[],
  keys: readonly K[],
): MotionPhases {
  const moves: Map<string, number>[] = [new Map()];
  let maxJump = 0;
  for (let index = 1; index < frames.length; index += 1) {
    const movers = new Map<string, number>();
    for (const key of keys) {
      const before = frames[index - 1]![key];
      const after = frames[index]![key];
      if (before == null || after == null || Math.abs(after - before) <= STILL_PX) continue;
      movers.set(key, after - before);
      maxJump = Math.max(maxJump, Math.abs(after - before));
    }
    moves.push(movers);
  }
  const runs: { from: number; to: number }[] = [];
  for (let index = 1; index < moves.length; index += 1) {
    if (moves[index]!.size === 0) continue;
    const last = runs.at(-1);
    if (last && last.to === index - 1) last.to = index;
    else runs.push({ from: index, to: index });
  }
  let phases = 0;
  const detail: string[] = [];
  for (const run of runs) {
    // Frames where some box turned back (two boxes turning in one frame are one turn).
    const turns = new Set<number>();
    const direction = new Map<string, number>();
    const spans = new Map<string, [number, number]>();
    for (let index = run.from; index <= run.to; index += 1)
      for (const [key, delta] of moves[index]!) {
        const sign = Math.sign(delta);
        if (direction.has(key) && direction.get(key) !== sign) turns.add(index);
        direction.set(key, sign);
        const span = spans.get(key);
        if (span) span[1] = index;
        else spans.set(key, [index, index]);
      }
    // Boxes whose moving spans do not overlap moved at different times: each group is a phase.
    let groups = 0;
    let reach = -1;
    for (const [from, to] of [...spans.values()].sort((a, b) => a[0] - b[0])) {
      if (from > reach) groups += 1;
      reach = Math.max(reach, to);
    }
    phases += groups + turns.size;
    const at = (index: number) => frames[index]!.t;
    const spanText = [...spans].map(([key, [from, to]]) => `${key} ${at(from)}-${at(to)}`).join(", ");
    detail.push(
      `${at(run.from)}-${at(run.to)} ms: ${spanText}${turns.size ? ` (turns back at ${[...turns].map(at).join(", ")} ms)` : ""}`,
    );
  }
  return { phases, maxJump: Math.round(maxJump * 10) / 10, detail };
}
