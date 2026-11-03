// l10n-allow-file: benchmark diagnostics, not shipped UI.
// The transcript-fling regression's mounted-row oracle, sampled after paint. Consecutive
// aria positions form a run: intentional spacing inside a run is not an unrendered row.
// This measures DOM coverage, not compositor presentation; native frame receipts still matter.
export type ScrollCoverage = {
  frames: number;
  blank_frames: number;
  blank_ms: number;
  duration_ms: number;
  max_uncovered_px: number;
  probe_ms: number;
  distance_px: number;
  timed_out: boolean;
};

declare global {
  interface Window {
    __stopScrollCoverage?: () => ScrollCoverage;
  }
}

/** Serialized into the page; requires installPaintedFrames and closes over no module state. */
export function startScrollCoverage({ timeoutMs }: { timeoutMs: number }): void {
  window.__stopScrollCoverage?.();
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  const thread = scroller?.querySelector<HTMLElement>(".acpmux-thread");
  if (!scroller || !thread) throw new Error("scroll coverage: transcript missing");
  const padding = Number.parseFloat(getComputedStyle(thread).paddingTop) || 0;
  const result: ScrollCoverage = {
    frames: 0,
    blank_frames: 0,
    blank_ms: 0,
    duration_ms: 0,
    max_uncovered_px: 0,
    probe_ms: 0,
    distance_px: 0,
    timed_out: false,
  };
  const deadline = performance.now() + timeoutMs;
  const initialTop = scroller.scrollTop;
  let previousTop = initialTop;
  let first: number | undefined;
  let last: number | undefined;
  let previousBlank = false;
  let stopped = false;
  const stop = window.cmuxAfterPaint((now) => {
    if (stopped) return false;
    if (performance.now() >= deadline) {
      result.timed_out = true;
      return false;
    }
    // Ignore the debug fling's warm-up and the initial bottom placement.
    if (first === undefined && scroller.scrollTop === initialTop) return;
    first ??= now;
    result.distance_px += Math.abs(scroller.scrollTop - previousTop);
    previousTop = scroller.scrollTop;
    if (last !== undefined && previousBlank) result.blank_ms += now - last;
    result.duration_ms = now - first;
    last = now;
    const started = performance.now();
    const view = scroller.getBoundingClientRect();
    const top = view.top + scroller.clientTop + Math.max(0, padding - scroller.scrollTop);
    let bottom = Math.min(
      view.top + scroller.clientTop + scroller.clientHeight,
      view.top + scroller.clientTop + scroller.scrollHeight - scroller.scrollTop,
    );
    const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
      .map((row) => ({
        index: Number(row.getAttribute("aria-posinset")),
        size: Number(row.getAttribute("aria-setsize")),
        box: row.getBoundingClientRect(),
      }))
      .sort((a, b) => a.index - b.index);
    // The transcript deliberately keeps room after its final row (tail gap/composer).
    // Exclude it only when the actual final row is mounted and touches the viewport;
    // a missing final row or a view entirely past the rows must still count as blank.
    const finalRow = rows.find((row) => row.index > 0 && row.index === row.size);
    if (finalRow && finalRow.box.bottom > top && finalRow.box.top < bottom)
      bottom = Math.min(bottom, finalRow.box.bottom);
    const runs: { top: number; bottom: number }[] = [];
    rows.forEach((row, at) => {
      if (at > 0 && row.index === rows[at - 1].index + 1) {
        runs.at(-1)!.bottom = Math.max(runs.at(-1)!.bottom, row.box.bottom);
      } else runs.push({ top: row.box.top, bottom: row.box.bottom });
    });
    runs.sort((a, b) => a.top - b.top);
    let coveredTo = top;
    let missing = 0;
    for (const run of runs) {
      if (run.bottom <= coveredTo || run.top >= bottom) continue;
      missing += Math.max(0, run.top - coveredTo);
      coveredTo = Math.max(coveredTo, Math.min(bottom, run.bottom));
    }
    missing += Math.max(0, bottom - coveredTo);
    previousBlank = missing > 0.5;
    result.frames += 1;
    if (previousBlank) result.blank_frames += 1;
    result.max_uncovered_px = Math.max(result.max_uncovered_px, missing);
    result.probe_ms += performance.now() - started;
  });
  window.__stopScrollCoverage = () => {
    stopped = true;
    stop();
    // Duration ends at the last sampled paint. Do not invent a last-frame duration from
    // Playwright transport time or assume the requested refresh rate was achieved.
    return { ...result };
  };
}
