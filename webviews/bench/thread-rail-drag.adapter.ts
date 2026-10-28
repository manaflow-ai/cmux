// Importable rail drag adapter for the shared web perf flows harness.
// It uses production selectors only; no rail hooks or app-specific instrumentation.
import type { Page } from "playwright";

export const RAIL_DRAG_CASE = {
  id: "chat.rail.drag",
  metric: "drag_target_painted" as const,
  frameMetric: "frame_time" as const,
  selectors: {
    list: ".acpmux-minimap__list",
    rail: ".acpmux-minimap__rail",
    tick: (index: number) => `[data-tick="${index}"]`,
    row: (id: string) => `.acpmux-row[data-row-id="${id}"]`,
    bubble: ".cv-user__bubble",
    transcript: ".acpmux-scroll",
  },
} as const;

export type RailDragOptions = {
  startIndex: number;
  targetIndex: number;
  targetRowId: string;
  frameMs?: number;
  timeoutMs?: number;
};
export type RailDragSample = {
  releaseToPaintMs: number | null;
  lastMoveToPaintMs: number | null;
  alreadyPaintedBeforeRelease: boolean;
  droppedFrames: number | null;
  status: "painted" | "unsupported" | "timeout";
};
export type RailDragResult = {
  id: typeof RAIL_DRAG_CASE.id;
  metric: typeof RAIL_DRAG_CASE.metric;
  samples: RailDragSample[];
  unsupported: string[];
};

/** A target is painted only when its requested transcript row's bubble is visible and non-zero. */
export async function railDragTargetPainted(page: Page, targetRowId: string): Promise<boolean> {
  return page.evaluate(
    ({ rowSelector, transcriptSelector, bubbleSelector }) => {
      const transcript = document.querySelector<HTMLElement>(transcriptSelector);
      const row = document.querySelector<HTMLElement>(rowSelector);
      const bubble = row?.querySelector<HTMLElement>(bubbleSelector);
      if (!transcript || !row || !bubble || !transcript.contains(row)) return false;
      const viewport = transcript.getBoundingClientRect();
      const box = bubble.getBoundingClientRect();
      return (
        box.width > 0 &&
        box.height > 0 &&
        box.bottom > viewport.top &&
        box.top < viewport.bottom &&
        box.bottom > 0 &&
        box.top < window.innerHeight
      );
    },
    {
      rowSelector: RAIL_DRAG_CASE.selectors.row(targetRowId),
      transcriptSelector: RAIL_DRAG_CASE.selectors.transcript,
      bubbleSelector: RAIL_DRAG_CASE.selectors.bubble,
    },
  );
}

/** Runs one real pointer drag and samples the first painted target after release. */
export async function measureRailDrag(
  page: Page,
  options: RailDragOptions,
): Promise<RailDragResult> {
  const frameMs = options.frameMs ?? 16.7;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const list = page.locator(RAIL_DRAG_CASE.selectors.list);
  const source = list.locator(RAIL_DRAG_CASE.selectors.tick(options.startIndex));
  const target = list.locator(RAIL_DRAG_CASE.selectors.tick(options.targetIndex));
  await source.scrollIntoViewIfNeeded();
  await target.scrollIntoViewIfNeeded();
  const sourceBox = await source.boundingBox();
  const targetBox = await target.boundingBox();
  if (!sourceBox || !targetBox)
    return {
      id: RAIL_DRAG_CASE.id,
      metric: RAIL_DRAG_CASE.metric,
      samples: [
        {
          releaseToPaintMs: null,
          lastMoveToPaintMs: null,
          alreadyPaintedBeforeRelease: false,
          droppedFrames: null,
          status: "unsupported",
        },
      ],
      unsupported: ["source or target tick is not mounted"],
    };
  await page.mouse.move(sourceBox.x + sourceBox.width / 2, sourceBox.y + sourceBox.height / 2);
  await page.mouse.down();
  await page.mouse.move(targetBox.x + targetBox.width / 2, targetBox.y + targetBox.height / 2, {
    steps: 2,
  });
  const lastMoveAt = await page.evaluate(() => performance.now());
  const paintedBeforeRelease = await railDragTargetPainted(page, options.targetRowId);
  const releaseAt = await page.evaluate(() => performance.now());
  await page.mouse.up();
  const sample = await page.evaluate(
    ({
      rowSelector,
      transcriptSelector,
      bubbleSelector,
      frameMs,
      timeoutMs,
      releaseAt,
      lastMoveAt,
      paintedBeforeRelease,
    }) =>
      new Promise<RailDragSample>((resolve) => {
        const startedAt = performance.now();
        let previous = startedAt;
        let dropped = 0;
        const stop = window.cmuxAfterPaint((frame) => {
          dropped += Math.max(0, Math.round((frame - previous) / frameMs) - 1);
          previous = frame;
          const transcript = document.querySelector<HTMLElement>(transcriptSelector);
          const row = document.querySelector<HTMLElement>(rowSelector);
          const bubble = row?.querySelector<HTMLElement>(bubbleSelector);
          const viewport = transcript?.getBoundingClientRect();
          const box = bubble?.getBoundingClientRect();
          const painted =
            !!viewport &&
            !!box &&
            !!transcript &&
            !!row &&
            transcript.contains(row) &&
            box.width > 0 &&
            box.height > 0 &&
            box.bottom > viewport.top &&
            box.top < viewport.bottom &&
            box.bottom > 0 &&
            box.top < window.innerHeight;
          if (painted) {
            resolve({
              releaseToPaintMs: frame - releaseAt,
              lastMoveToPaintMs: frame - lastMoveAt,
              alreadyPaintedBeforeRelease: paintedBeforeRelease,
              droppedFrames: dropped,
              status: "painted",
            });
            stop();
            return false;
          }
          if (performance.now() - startedAt > timeoutMs) {
            resolve({
              releaseToPaintMs: null,
              lastMoveToPaintMs: null,
              alreadyPaintedBeforeRelease: paintedBeforeRelease,
              droppedFrames: dropped,
              status: "timeout",
            });
            stop();
            return false;
          }
          return true;
        });
      }),
    {
      rowSelector: RAIL_DRAG_CASE.selectors.row(options.targetRowId),
      transcriptSelector: RAIL_DRAG_CASE.selectors.transcript,
      bubbleSelector: RAIL_DRAG_CASE.selectors.bubble,
      frameMs,
      timeoutMs,
      releaseAt,
      lastMoveAt,
      paintedBeforeRelease,
    },
  );
  return {
    id: RAIL_DRAG_CASE.id,
    metric: RAIL_DRAG_CASE.metric,
    samples: [sample],
    unsupported: [
      "EventTiming interactionId, long tasks, React commits, paint duration, idle wakeups",
    ],
  };
}
