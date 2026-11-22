import { measureRailDrag, RAIL_DRAG_CASE, type RailDragResult } from "../../bench/thread-rail-drag.adapter";
import type { AdapterContext, AdapterRun } from "./measure";
import type { Page } from "playwright";

const adapterHead = "308f5d9a8812d1d7b1270432896bb36f3ac73281";

export function railObservation(result: RailDragResult): AdapterRun {
  const last = result.samples.at(-1);
  const releaseComplete = result.release.inputAt !== null && result.release.firstPaintAt !== null;
  const timedOut =
    result.samples.some((sample) => sample.status === "deadline") || (result.samples.length > 0 && !releaseComplete);
  const status = result.samples.length === 0 ? "unsupported" : timedOut ? "timeout" : "complete";
  const reason =
    status === "unsupported"
      ? result.unsupported.join("; ") || "rail adapter returned no samples"
      : timedOut
        ? "rail drag did not paint every unsuperseded target and release before the deadline"
        : undefined;
  return {
    status,
    ...(reason ? { reason } : {}),
    observations: result.samples.length
      ? result.samples.map((sample) => ({
          status: sample.status === "deadline" ? "timeout" : sample.status,
          latencyMs: sample.latencyMs,
          inputAt: sample.inputAt,
          targetPaintAt: sample.firstPaintAt,
          raw: {
            ...sample,
            adapterHead,
            release: result.release,
            releaseToPaintMs: result.release.latencyMs,
            lastMoveToPaintMs: last?.latencyMs ?? null,
            alreadyPaintedBeforeRelease: result.release.alreadyPaintedBeforeRelease,
            standaloneUnsupported: result.unsupported,
          },
        }))
      : [
          {
            status: "unsupported",
            latencyMs: null,
            inputAt: null,
            targetPaintAt: null,
            raw: { adapterHead, release: result.release, reason },
          },
        ],
    frameGaps: result.frameGaps.length ? result.frameGaps : null,
    longTasks: null,
    reactCommits: null,
    unsupportedReasons: {
      eventTiming: "drag target paint and frame cadence are not EventTiming INP",
      trace: "rail adapter does not record a complete trace or paint duration",
      ...(!result.frameGaps.length ? { frameCadence: "rail adapter did not record any frame interval" } : {}),
    },
  };
}

/** Both stable case IDs invoke the owner's real pointer sampler; only aggregation differs. */
export async function measureRailFlow(page: Page, context: AdapterContext): Promise<AdapterRun> {
  let stopping: Promise<void> | undefined;
  const stop = () =>
    (stopping ??= (async () => {
      if (page.isClosed()) return;
      await page.mouse.up().catch(() => undefined);
      await page.evaluate(() => {
        window.__railDragSampler?.stop();
        delete window.__railDragSampler;
      });
    })());
  const abort = () => {
    void stop().catch(() => undefined);
  };
  context.signal.addEventListener("abort", abort, { once: true });
  context.onCleanup(async () => {
    context.signal.removeEventListener("abort", abort);
    await stop();
  });
  if (context.signal.aborted) throw new Error("rail measurement cancelled");
  await page.evaluate(async () => {
    const transcript = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const rail = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    transcript.scrollTop = transcript.scrollHeight;
    rail.scrollTop = rail.scrollHeight;
    await window.cmuxPaintFrame();
    await window.cmuxPaintFrame();
  });
  const options = await page.evaluate(() => {
    const rail = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const box = rail.getBoundingClientRect();
    const visible = [...rail.querySelectorAll<HTMLElement>("[data-tick]")].filter((tick) => {
      const rect = tick.getBoundingClientRect();
      return rect.width > 0 && rect.top >= Math.max(0, box.top) && rect.bottom <= Math.min(innerHeight, box.bottom);
    });
    if (visible.length < 4) throw new Error("rail fixture has fewer than four fully visible ticks");
    const targetIndex = Number(visible[Math.floor(visible.length / 4)].dataset.tick);
    const startIndex = Number(visible[Math.floor((visible.length * 3) / 4)].dataset.tick);
    // The resident fixture uses the existing syntheticRows IDs: one prompt per data-tick.
    return { startIndex, targetIndex, targetRowId: `synthetic-user-${targetIndex}` };
  });
  if (context.signal.aborted) throw new Error("rail measurement cancelled");
  const result = await measureRailDrag(page, {
    ...options,
    frameMs: context.frameMs,
    timeoutMs: Math.max(1, context.timeoutMs - 500),
  });
  return railObservation(result);
}

export { RAIL_DRAG_CASE };
