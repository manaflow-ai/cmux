/**
 * The running line's text shimmer has one compositor loop on each of its two layers: the masked
 * band and the generated lit copy. Keep the layers separate so a duplicate loop on one element
 * still fails the gallery check instead of being mistaken for the approved pair.
 */
export const RUNNING_LINE_SHIMMER_NAMES = ["cmux-shimmer-band", "cmux-shimmer-lit"] as const;

export type RunningLineLoop = {
  name: string | undefined;
  target: Element | null;
  playState: AnimationPlayState;
  playbackRate: number;
  currentTime: CSSNumberish | null;
  duration: number;
  progress: number | null;
};

export type RunningLineLoopCheck = {
  shimmer: RunningLineLoop[];
  unapproved: RunningLineLoop[];
  duplicateTargets: Element[];
};

export function checkRunningLineLoops(loops: readonly RunningLineLoop[]): RunningLineLoopCheck {
  const active = loops.filter(
    (loop) =>
      loop.playState === "running" &&
      loop.playbackRate !== 0 &&
      Number.isFinite(loop.duration) &&
      loop.duration > 0 &&
      typeof loop.currentTime === "number" &&
      Number.isFinite(loop.currentTime) &&
      typeof loop.progress === "number" &&
      Number.isFinite(loop.progress) &&
      loop.progress >= 0 &&
      loop.progress <= 1,
  );
  const shimmer = active.filter((loop) => {
    if (loop.name === "cmux-shimmer-band") return loop.target?.classList.contains("cv-shimmer__band") ?? false;
    if (loop.name === "cmux-shimmer-lit") {
      return (
        loop.target?.classList.contains("cv-shimmer__lit") === true &&
        loop.target.parentElement?.classList.contains("cv-shimmer__band") === true
      );
    }
    return false;
  });
  const unapproved = loops.filter((loop) => !shimmer.includes(loop));
  const counts = new Map<Element, number>();
  for (const loop of active) {
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
