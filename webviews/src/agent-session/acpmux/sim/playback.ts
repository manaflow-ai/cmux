/// Each step's time in a watched run's full playback (ms from its first step): its scaled wait since the
/// step before, at least `minGap` and at most `maxGap`, as test/browser/chat-sim.harness.tsx `watch`
/// sleeps them. A whole run's video shows step i about this long after the playback began, so a window
/// read off one (`--start S`, scripts/chat-sim-watch.ts) finds its steps.
export function playbackAt(ats: readonly number[], speed: number, minGap: number, maxGap: number): number[] {
  let total = 0;
  return ats.map((at, index) => {
    if (index > 0) total += Math.min(maxGap, Math.max(minGap, (at - ats[index - 1]!) / speed));
    return total;
  });
}

/// The first step a window that starts at `startMs` of the playback plays (its index; the steps before it
/// are drawn at once), and the step it stops before (`endMs`; the step count when it runs to the end).
export function playbackWindow(
  playback: readonly number[],
  startMs: number,
  endMs: number,
): { first: number; end: number } {
  let first = 0;
  while (first < playback.length && playback[first]! < startMs) first += 1;
  let end = first;
  while (end < playback.length && playback[end]! <= endMs) end += 1;
  return { first, end };
}
