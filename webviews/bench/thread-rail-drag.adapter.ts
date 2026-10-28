// Importable rail drag adapter for the shared web perf flows harness.
// It uses production selectors only; no rail hooks or app-specific instrumentation.
import type { Page } from "playwright";

declare global {
  interface Window {
    cmuxAfterPaint: (read: (frame: number) => boolean | void, drive?: (frame: number) => void) => () => void;
    __railDragSampler?: { done: Promise<RailDragInPageResult>; stop: () => void };
  }
}

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
  targetTick: number;
  targetRowId: string | null;
  inputAt: number;
  firstPaintAt: number | null;
  latencyMs: number | null;
  status: "painted" | "superseded" | "deadline";
};
export type RailDragResult = {
  id: typeof RAIL_DRAG_CASE.id;
  metric: typeof RAIL_DRAG_CASE.metric;
  samples: RailDragSample[];
  release: {
    inputAt: number | null;
    firstPaintAt: number | null;
    latencyMs: number | null;
    alreadyPaintedBeforeRelease: boolean;
  };
  frameGaps: number[];
  droppedFrames: number | null;
  unsupported: string[];
};

type RailDragInPageResult = Omit<RailDragResult, "id" | "metric" | "unsupported" | "droppedFrames"> & {
  droppedFrames: number;
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
        box.right > viewport.left &&
        box.left < viewport.right &&
        box.bottom > 0 &&
        box.top < window.innerHeight &&
        box.right > 0 &&
        box.left < window.innerWidth
      );
    },
    {
      rowSelector: RAIL_DRAG_CASE.selectors.row(targetRowId),
      transcriptSelector: RAIL_DRAG_CASE.selectors.transcript,
      bubbleSelector: RAIL_DRAG_CASE.selectors.bubble,
    },
  );
}

/** Runs one real pointer drag with capture-phase input timestamps and continuous painted sampling. */
export async function measureRailDrag(page: Page, options: RailDragOptions): Promise<RailDragResult> {
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
      samples: [],
      release: {
        inputAt: null,
        firstPaintAt: null,
        latencyMs: null,
        alreadyPaintedBeforeRelease: false,
      },
      frameGaps: [],
      droppedFrames: null,
      unsupported: ["source or target tick is not mounted"],
    };

  await page.evaluate(
    ({ targetIndex, targetRowId, frameMs, timeoutMs, selectors }) => {
      const list = document.querySelector<HTMLElement>(selectors.list);
      if (!list) throw new Error("Rail list is not mounted");
      type Pending = RailDragSample & { state: "pending" | "painted" | "superseded" | "deadline" };
      const samples: Pending[] = [];
      const frameGaps: number[] = [];
      let previousFrame: number | undefined;
      let releaseAt: number | null = null;
      let releasePaintAt: number | null = null;
      let startedAt = performance.now();
      let finished = false;
      let resolveDone!: (result: RailDragInPageResult) => void;
      const done = new Promise<RailDragInPageResult>((resolve) => (resolveDone = resolve));
      const painted = (rowId: string | null) => {
        const transcript = document.querySelector<HTMLElement>(selectors.transcript);
        const row = rowId ? document.querySelector<HTMLElement>(selectors.targetRow) : null;
        const bubble = row?.querySelector<HTMLElement>(selectors.bubble);
        if (!transcript || !row || !bubble || !transcript.contains(row)) return false;
        const viewport = transcript.getBoundingClientRect();
        const box = bubble.getBoundingClientRect();
        return (
          box.width > 0 &&
          box.height > 0 &&
          box.bottom > viewport.top &&
          box.top < viewport.bottom &&
          box.right > viewport.left &&
          box.left < viewport.right &&
          box.bottom > 0 &&
          box.top < window.innerHeight &&
          box.right > 0 &&
          box.left < window.innerWidth
        );
      };
      const finish = () => {
        if (finished) return;
        finished = true;
        for (const sample of samples)
          if (sample.state === "pending") {
            sample.state = "deadline";
            sample.status = "deadline";
          }
        resolveDone({
          samples: samples.map(({ state: _state, ...sample }) => sample),
          release: {
            inputAt: releaseAt,
            firstPaintAt: releasePaintAt,
            latencyMs: releasePaintAt === null || releaseAt === null ? null : releasePaintAt - releaseAt,
            alreadyPaintedBeforeRelease: samples.some(
              (sample) =>
                sample.status === "painted" &&
                sample.firstPaintAt !== null &&
                releaseAt !== null &&
                sample.firstPaintAt <= releaseAt,
            ),
          },
          frameGaps,
          droppedFrames: frameGaps.reduce((sum, gap) => sum + Math.max(0, Math.round(gap / frameMs) - 1), 0),
        });
      };
      const onMove = (event: PointerEvent) => {
        if (finished || event.buttons === 0) return;
        for (const sample of samples)
          if (sample.state === "pending") {
            sample.state = "superseded";
            sample.status = "superseded";
          }
        const rect = list.getBoundingClientRect();
        const tick = Math.max(
          0,
          Math.min(
            Number(list.querySelector("[aria-setsize]")?.getAttribute("aria-setsize") ?? targetIndex + 1) - 1,
            Math.floor((event.clientY - rect.top + list.scrollTop) / 10),
          ),
        );
        const rowId = tick === targetIndex ? targetRowId : null;
        const inputAt = performance.now();
        samples.push({
          targetTick: tick,
          targetRowId: rowId,
          inputAt,
          firstPaintAt: null,
          latencyMs: null,
          status: "deadline",
          state: "pending",
        });
      };
      const onUp = () => {
        if (releaseAt === null) releaseAt = performance.now();
      };
      const stopPaint = window.cmuxAfterPaint((frame) => {
        if (finished) return false;
        if (previousFrame !== undefined) frameGaps.push(frame - previousFrame);
        previousFrame = frame;
        const paintAt = performance.now();
        for (const sample of samples)
          if (sample.state === "pending" && sample.targetRowId && painted(sample.targetRowId)) {
            sample.state = "painted";
            sample.status = "painted";
            sample.firstPaintAt = paintAt;
            sample.latencyMs = paintAt - sample.inputAt;
          }
        if (releaseAt !== null && releasePaintAt === null && painted(targetRowId)) releasePaintAt = paintAt;
        if (releaseAt !== null && releasePaintAt !== null) {
          finish();
          return false;
        }
        if (paintAt - startedAt >= timeoutMs) {
          finish();
          return false;
        }
        return true;
      });
      const stop = () => {
        stopPaint();
        window.removeEventListener("pointermove", onMove, true);
        window.removeEventListener("pointerup", onUp, true);
        if (!finished) finish();
      };
      window.addEventListener("pointermove", onMove, true);
      window.addEventListener("pointerup", onUp, true);
      window.__railDragSampler = { done, stop };
    },
    {
      targetIndex: options.targetIndex,
      targetRowId: options.targetRowId,
      frameMs,
      timeoutMs,
      selectors: {
        list: RAIL_DRAG_CASE.selectors.list,
        transcript: RAIL_DRAG_CASE.selectors.transcript,
        targetRow: RAIL_DRAG_CASE.selectors.row(options.targetRowId),
        bubble: RAIL_DRAG_CASE.selectors.bubble,
      },
    },
  );
  let result: RailDragInPageResult;
  try {
    await page.mouse.move(sourceBox.x + sourceBox.width / 2, sourceBox.y + sourceBox.height / 2);
    await page.mouse.down();
    await page.mouse.move(targetBox.x + targetBox.width / 2, targetBox.y + targetBox.height / 2, {
      steps: 2,
    });
    await page.mouse.up();
    result = await page.evaluate(() => window.__railDragSampler!.done);
  } finally {
    await page.mouse.up().catch(() => undefined);
    await page.evaluate(() => window.__railDragSampler?.stop());
  }
  return {
    id: RAIL_DRAG_CASE.id,
    metric: RAIL_DRAG_CASE.metric,
    ...result!,
    unsupported: ["EventTiming interactionId, long tasks, React commits, paint duration, idle wakeups"],
  };
}
