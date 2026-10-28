/**
 * The running line's text shimmer has one compositor loop on each of its two layers: the masked
 * band and the generated lit copy. Keep the layers separate so a duplicate loop on one element
 * still fails the gallery check instead of being mistaken for the approved pair.
 */
export const RUNNING_LINE_SHIMMER_NAMES = ["cmux-shimmer-band", "cmux-shimmer-lit"] as const;

const RUNNING_LINE_SHIMMER_SET = new Set<string>(RUNNING_LINE_SHIMMER_NAMES);

export type RunningLineLoop = {
  name: string | undefined;
  target: object | null;
};

export type RunningLineLoopCheck = {
  shimmer: RunningLineLoop[];
  unapproved: RunningLineLoop[];
  duplicateTargets: object[];
};

export function checkRunningLineLoops(loops: readonly RunningLineLoop[]): RunningLineLoopCheck {
  const shimmer = loops.filter((loop) => loop.name !== undefined && RUNNING_LINE_SHIMMER_SET.has(loop.name));
  const unapproved = loops.filter((loop) => !shimmer.includes(loop));
  const counts = new Map<object, number>();
  for (const loop of loops) {
    if (loop.target !== null) counts.set(loop.target, (counts.get(loop.target) ?? 0) + 1);
  }
  const duplicateTargets = [...counts].filter(([, count]) => count > 1).map(([target]) => target);
  return { shimmer, unapproved, duplicateTargets };
}

export function hasCompleteRunningLineShimmer(check: RunningLineLoopCheck): boolean {
  return (
    check.unapproved.length === 0 &&
    check.duplicateTargets.length === 0 &&
    check.shimmer.length === RUNNING_LINE_SHIMMER_NAMES.length &&
    new Set(check.shimmer.map((loop) => loop.name)).size === RUNNING_LINE_SHIMMER_NAMES.length
  );
}
