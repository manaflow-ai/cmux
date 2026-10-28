import type { Page } from "playwright";
import {
  BUDGET_60HZ,
  BUDGET_120HZ,
  distribution,
  type ActionResult,
  type AdapterRun,
  type LatencyAction,
} from "./measure";
import {
  beginAdapterInstrumentation,
  endAdapterInstrumentation,
  type AdapterInstrumentation,
} from "./adapter-instrumentation";

const missing = (status: "timeout" | "unsupported", reason: string): AdapterRun => ({
  status,
  reason,
  observations: [{ status, latencyMs: null, inputAt: null, targetPaintAt: null, raw: { reason } }],
  frameGaps: null,
  longTasks: null,
  reactCommits: null,
  unsupportedReasons: {
    longTasks: reason,
    reactCommits: reason,
    frameCadence: reason,
    trace: reason,
    eventTiming: reason,
  },
});

export async function measureAdapterOnce(
  page: Page,
  action: LatencyAction,
  frameMs: number,
  timeoutMs = 10_500,
): Promise<AdapterRun> {
  const controller = new AbortController();
  const cleanup: (() => void | Promise<void>)[] = [];
  let timer: ReturnType<typeof setTimeout> | undefined;
  let expired = false;
  let result: AdapterRun;
  let instrumentation: AdapterInstrumentation | undefined;
  try {
    await page.evaluate(() => window.__latency?.stop());
    await page.evaluate(beginAdapterInstrumentation);
    result = await Promise.race([
      action.measureRun!(page, {
        frameMs,
        timeoutMs,
        signal: controller.signal,
        onCleanup: (dispose) => cleanup.push(dispose),
      }),
      new Promise<AdapterRun>((resolve) => {
        // fixed-wait: an independent deadline rejects a sampler that never produces its terminal event
        timer = setTimeout(() => {
          expired = true;
          controller.abort();
          resolve(missing("timeout", `adapter exceeded ${timeoutMs} ms deadline`));
        }, timeoutMs);
      }),
    ]);
  } catch (error) {
    result = missing("unsupported", `adapter failed: ${String(error)}`);
  } finally {
    if (timer) clearTimeout(timer);
    controller.abort();
    if (expired) await page.close();
    let cleanupTimer: ReturnType<typeof setTimeout> | undefined;
    const failures = await Promise.race([
      Promise.allSettled([
        ...(page.isClosed()
          ? []
          : [
              page.evaluate(endAdapterInstrumentation).then((value) => {
                instrumentation = value;
              }),
            ]),
        ...cleanup.reverse().map(async (dispose) => dispose()),
      ]),
      new Promise<PromiseSettledResult<void>[]>((resolve) => {
        // fixed-wait: cleanup has its own deadline so a failed disposer cannot block page destruction
        cleanupTimer = setTimeout(
          () => resolve([{ status: "rejected", reason: "adapter cleanup deadline exceeded" }]),
          Math.min(timeoutMs, 1000),
        );
      }),
    ]);
    if (cleanupTimer) clearTimeout(cleanupTimer);
    const cleanupFailed = failures.some((failure) => failure.status === "rejected");
    const invalidate = (reason: string) => {
      result = result!
        ? { ...result, status: result.status === "timeout" ? "timeout" : "unsupported", reason }
        : missing("unsupported", reason);
    };
    if (cleanupFailed) invalidate("adapter cleanup failed or exceeded its deadline");
    // A sampler that ignored cancellation cannot survive its deadline in a reused page.
    if (expired || cleanupFailed) {
      if (!page.isClosed()) await page.close();
    } else if (!page.isClosed()) {
      try {
        await page.evaluate(() => window.__latency?.stop());
        await action.settle?.(page);
      } catch (error) {
        invalidate(`adapter settle failed: ${String(error)}`);
        await page.close();
      }
    }
  }
  // Adapter-local unsupported fields remain true for its standalone runner. This wrapper
  // supplies values only from an actual observer and the profiling fixture's monotonic counter.
  result!.longTasks = instrumentation?.longTasks ?? null;
  result!.reactCommits = instrumentation?.reactCommits ?? null;
  if (instrumentation) result!.instrumentationWindow = instrumentation.instrumentationWindow;
  for (const field of ["longTasks", "reactCommits"] as const) {
    if (result![field] !== null) delete result!.unsupportedReasons[field];
    else
      result!.unsupportedReasons[field] =
        field === "longTasks"
          ? "Long Tasks API unavailable or adapter instrumentation window could not be finalized"
          : "React Profiler commit counter unavailable or adapter instrumentation window could not be finalized";
  }
  return result!;
}

export function aggregateAdapterAction(
  spec: { page: string; engine: string },
  action: LatencyAction,
  adapterRuns: AdapterRun[],
  runs: number,
  budget: number,
): ActionResult {
  const errors: string[] = [];
  const metricType = action.metricType ?? "target_painted";
  const complete = adapterRuns.filter((run) => run.status === "complete");
  const painted = complete.flatMap((run) => run.observations.filter((entry) => entry.status === "painted"));
  const validNumber = (value: number | null): value is number => value !== null && Number.isFinite(value) && value >= 0;
  for (const run of adapterRuns) {
    if (run.status !== "complete") errors.push(run.reason ?? `adapter run ${run.status}`);
    if (!run.observations.length) errors.push("adapter run has no raw observations");
    for (const entry of run.observations) {
      if (entry.status !== "painted") {
        if (entry.latencyMs !== null) errors.push("unpainted adapter observation has a latency");
        if (entry.status !== "superseded") errors.push(`adapter observation ${entry.status}`);
      } else if (
        !validNumber(entry.latencyMs) ||
        !validNumber(entry.inputAt) ||
        !validNumber(entry.targetPaintAt) ||
        entry.targetPaintAt < entry.inputAt ||
        Math.abs(entry.latencyMs - (entry.targetPaintAt - entry.inputAt)) > 0.1
      )
        errors.push("adapter paint lacks valid causal input/postpaint timestamps");
    }
    if (!run.observations.some((entry) => entry.status === "painted")) errors.push("adapter run has no painted target");
    if (run.frameGaps !== null && (!run.frameGaps.length || !distribution(run.frameGaps)))
      errors.push("invalid adapter frame cadence");
    if (run.longTasks !== null && run.longTasks.some((value) => !validNumber(value)))
      errors.push("invalid adapter long tasks");
    if (run.reactCommits !== null && (!Number.isInteger(run.reactCommits) || run.reactCommits < 0))
      errors.push("invalid adapter React commit count");
  }
  if (adapterRuns.length !== runs || complete.length !== runs)
    errors.push(`expected ${runs} complete adapter runs, received ${complete.length}`);
  const cadence =
    adapterRuns.length > 0 && adapterRuns.every((run) => run.frameGaps !== null)
      ? adapterRuns.flatMap((run) => run.frameGaps!)
      : null;
  const latencyMs = distribution(
    metricType === "frame_time" || metricType === "scroll_frame_time"
      ? (cadence ?? [])
      : painted.map((entry) => entry.latencyMs!),
  );
  if (!latencyMs) errors.push("adapter has no valid latency distribution");
  const unsupportedReasons = Object.assign({}, ...adapterRuns.map((run) => run.unsupportedReasons));
  if (cadence === null) unsupportedReasons.frameCadence ??= "adapter did not record frame cadence";
  const tasks =
    adapterRuns.length > 0 && adapterRuns.every((run) => run.longTasks !== null)
      ? adapterRuns.flatMap((run) => run.longTasks!)
      : null;
  if (tasks === null) unsupportedReasons.longTasks ??= "adapter did not record Long Tasks API entries";
  const commits =
    adapterRuns.length > 0 && adapterRuns.every((run) => run.reactCommits !== null)
      ? adapterRuns.reduce((n, run) => n + run.reactCommits!, 0)
      : null;
  if (commits === null) unsupportedReasons.reactCommits ??= "adapter did not record React Profiler commits";
  unsupportedReasons.trace ??= "adapter did not record a trace";
  const fits = (frame: number) => errors.length === 0 && latencyMs !== null && latencyMs.p95 <= 2 * frame;
  return {
    ...spec,
    id: `${spec.engine}/${spec.page}/${action.id ?? action.name}`,
    action: action.name,
    metricType,
    samples: [],
    adapterRuns,
    latencyMs,
    errors,
    timeouts: adapterRuns.filter((run) => run.status === "timeout").length,
    work: null,
    paint: null,
    frames: null,
    maxWork: null,
    maxPaint: null,
    frameGap: null,
    longTaskRuns: null,
    budget,
    pass60: fits(BUDGET_60HZ),
    pass120: fits(BUDGET_120HZ),
    pass: fits(BUDGET_60HZ),
    longTasks:
      tasks === null
        ? null
        : {
            count: tasks.length,
            totalMs: tasks.reduce((a, b) => a + b, 0),
            maxMs: Math.max(0, ...tasks),
            source: "PerformanceObserver longtask around measureRun",
          },
    reactCommits: commits,
    framesSummary: {
      count: cadence?.length ?? null,
      dropped: cadence?.reduce((n, gap) => n + Math.max(0, Math.round(gap / budget) - 1), 0) ?? null,
      maxGapMs: cadence?.length ? Math.max(...cadence) : null,
      droppedSource: "estimated from adapter rAF cadence; not compositor dropped frames",
    },
    trace: null,
    unsupportedReasons,
  };
}

export async function measureAdapterAction(
  page: Page,
  spec: { page: string; engine: string },
  action: LatencyAction,
  runs: number,
  budget: number,
): Promise<ActionResult> {
  const observations: AdapterRun[] = [];
  for (let index = 0; index < runs; index += 1) {
    // fixed-wait: the helper waits on sampler completion and only its independent failure deadlines
    observations.push(await measureAdapterOnce(page, action, budget));
    if (page.isClosed()) break;
  }
  return aggregateAdapterAction(spec, action, observations, runs, budget);
}
