// Shared schema and measurement lifecycle for the existing interaction latency harness.
import type { Page } from "playwright";
import type { LatencySample } from "./probe";
export type { LatencySample } from "./probe";
export type MetricType = "target_painted" | "frame_time" | "scroll_frame_time" | "drag_target_painted";
export type Instrumentation = "longTasks" | "reactCommits" | "cpu" | "wakeups" | "trace";
export interface Distribution {
  p50: number;
  p95: number;
  max: number;
}
export interface TraceBreakdown {
  scriptMs: number;
  styleMs: number;
  layoutMs: number;
  paintMs: null;
  source: string;
  unsupportedReason: string;
}
export interface IdleResult {
  sampleDurationMs: number;
  cpuDurationMs: number | null;
  cpuPercent: number | null;
  wakeups: number | null;
  dataSource: string | null;
  unsupportedReasons: { cpu?: string; wakeups: string };
}
/** Autonomous samplers retain their own observations; these are never converted to probe samples. */
export interface AdapterObservation {
  status: "painted" | "superseded" | "timeout" | "unsupported";
  latencyMs: number | null;
  inputAt: number | null;
  targetPaintAt: number | null;
  raw: Record<string, unknown>;
}
export interface AdapterRun {
  status: "complete" | "timeout" | "unsupported";
  observations: AdapterObservation[];
  frameGaps: number[] | null;
  longTasks: number[] | null;
  reactCommits: number | null;
  instrumentationWindow?: { startAt: number; endAt: number; source: string };
  unsupportedReasons: Partial<Record<Instrumentation | "eventTiming" | "frameCadence", string>>;
  reason?: string;
}
export interface AdapterContext {
  frameMs: number;
  timeoutMs: number;
  signal: AbortSignal;
  /** Register owned sampler/listener cleanup before awaiting work that can fail or time out. */
  onCleanup(cleanup: () => void | Promise<void>): void;
}
export interface LatencyAction {
  name: string;
  id?: string;
  metricType?: MetricType;
  /** Restrict capture to an adapter's event, e.g. pointermove for drag. */
  inputEvent?: string;
  requiredInstrumentation?: Instrumentation[] | ((engine: string) => Instrumentation[]);
  /** Prepare outside the window; return an expression false now and true at the visible target. */
  prepare?(page: Page): Promise<string>;
  input?(page: Page): Promise<void>;
  /** Owns its measured window and raw statuses, independently of the DOM predicate probe. */
  measureRun?(page: Page, context: AdapterContext): Promise<AdapterRun>;
  settle?(page: Page): Promise<void>;
}
export interface LatencyPageSpec {
  name: string;
  path: string;
  ready: string;
  actions: LatencyAction[];
}
export interface ActionResult {
  id: string;
  page: string;
  action: string;
  engine: string;
  metricType: MetricType;
  samples: LatencySample[];
  adapterRuns?: AdapterRun[];
  latencyMs: Distribution | null;
  timeouts: number;
  errors: string[];
  work: number | null;
  paint: number | null;
  frames: number | null;
  maxWork: number | null;
  maxPaint: number | null;
  frameGap: number | null;
  /** Legacy estimate: runs with an API long task OR a >50ms frame stall. Use longTasks for API counts. */
  longTaskRuns: number | null;
  budget: number;
  pass60: boolean;
  pass120: boolean;
  pass: boolean;
  longTasks: { count: number; totalMs: number; maxMs: number; source: string } | null;
  reactCommits: number | null;
  framesSummary: { count: number | null; dropped: number | null; maxGapMs: number | null; droppedSource: string };
  trace: TraceBreakdown | null;
  idle?: IdleResult;
  unsupportedReasons: Partial<Record<Instrumentation | "eventTiming" | "frameCadence", string>>;
}
export const BUDGET_120HZ = 1000 / 120;
export const BUDGET_60HZ = 1000 / 60;

/** Linearly interpolated sample quantiles; empty or invalid input has no distribution. */
export function distribution(values: number[]): Distribution | null {
  if (!values.length || values.some((value) => !Number.isFinite(value) || value < 0)) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const quantile = (q: number) => {
    const index = (sorted.length - 1) * q;
    const lower = Math.floor(index);
    return sorted[lower] + (sorted[Math.ceil(index)] - sorted[lower]) * (index - lower);
  };
  return { p50: quantile(0.5), p95: quantile(0.95), max: sorted[sorted.length - 1] };
}

export async function frameBudget(page: Page): Promise<number> {
  const interval = await page.evaluate(() => window.__latency!.calibrate());
  if (Math.abs(interval - BUDGET_120HZ) < 1.5) return BUDGET_120HZ;
  if (Math.abs(interval - BUDGET_60HZ) < 3) return BUDGET_60HZ;
  if (!Number.isFinite(interval) || interval <= 0) throw new Error("invalid frame calibration");
  return interval;
}

export type MetricReader = () => Promise<Record<string, number>>;
export async function measureOnce(
  page: Page,
  action: LatencyAction,
  timeoutMs = 5000,
  metrics?: MetricReader,
): Promise<{ sample: LatencySample | null; error?: string; trace?: TraceBreakdown }> {
  try {
    if (!action.prepare || !action.input) throw new Error("predicate action requires prepare and input");
    const predicate = await action.prepare(page);
    await page.evaluate(`window.__latencyCheck = () => (${predicate});`);
    const before = await metrics?.();
    await page.evaluate(({ predicate, inputEvent }) => window.__latency!.arm(predicate, inputEvent), {
      predicate,
      inputEvent: action.inputEvent,
    });
    const armError = await page.evaluate(() => window.__latency!.error);
    if (armError) return { sample: null, error: armError };
    await action.input(page);
    await page.waitForFunction(() => window.__latency?.state === "done", undefined, { timeout: timeoutMs });
    const sample = await page.evaluate(() => window.__latency!.result());
    const after = await metrics?.();
    const delta = (name: string) => 1000 * (after![name] - before![name]);
    const trace =
      before && after
        ? ({
            scriptMs: delta("ScriptDuration"),
            styleMs: delta("RecalcStyleDuration"),
            layoutMs: delta("LayoutDuration"),
            paintMs: null,
            source: "CDP Performance.getMetrics threadTicks CPU (input window plus control round trips)",
            unsupportedReason: "CDP Performance metrics do not expose paint duration; this is not a full trace",
          } as const)
        : undefined;
    return { sample, trace };
  } catch (error) {
    return { sample: null, error: String((error as Error).message ?? error).split("\n")[0] };
  } finally {
    // Includes prepare/input/arm/wait failures. Settle and idle never inherit probe work.
    await page.evaluate(() => {
      window.__latency?.stop();
      delete window.__latencyCheck;
    });
    await action.settle?.(page);
  }
}

export function aggregateAction(
  spec: { page: string; engine: string },
  action: LatencyAction,
  samples: LatencySample[],
  errors: string[],
  runs: number,
  budget: number,
  traces: TraceBreakdown[] = [],
): ActionResult {
  const metricType = action.metricType ?? "target_painted";
  const latencyMs = distribution(
    samples.flatMap((sample) =>
      metricType === "scroll_frame_time" || metricType === "frame_time" ? sample.frameGaps : [sample.paint],
    ),
  );
  const stats = (read: (sample: LatencySample) => number) => distribution(samples.map(read));
  const work = stats((sample) => sample.work)?.p50 ?? 0;
  const paint = stats((sample) => sample.paint)?.p50 ?? 0;
  const frameGap = stats((sample) => sample.maxFrameGap)?.p50 ?? 0;
  const unsupportedReasons: ActionResult["unsupportedReasons"] = {};
  const longTaskRuns = samples.filter((sample) => sample.longTasks.length > 0 || sample.maxFrameGap > 50).length;
  const longTasksSupported = samples.length > 0 && samples.every((sample) => sample.instrumentation.longTasks);
  if (!longTasksSupported) unsupportedReasons.longTasks = "Long Tasks API unavailable";
  if (samples.some((sample) => sample.eventTiming === null))
    unsupportedReasons.eventTiming = "Event Timing API unavailable";
  if (!samples.length || samples.some((sample) => sample.reactCommits === null))
    unsupportedReasons.reactCommits = "fixture did not supply a React Profiler commit counter";
  if (!traces.length) unsupportedReasons.trace = "CDP Performance metrics unavailable for this engine";
  const tasks = samples.flatMap((sample) => sample.longTasks);
  if (samples.length !== runs || !latencyMs) errors.push(`expected ${runs} valid samples, received ${samples.length}`);
  if (
    samples.some(
      (sample) =>
        !distribution([
          sample.work,
          sample.paint,
          sample.maxFrameGap,
          sample.frames,
          ...sample.frameGaps,
          ...sample.longTasks,
        ]) ||
        sample.paint < sample.work ||
        !Number.isInteger(sample.frames) ||
        sample.frames !== sample.frameGaps.length ||
        sample.eventTiming?.some(
          (entry) => !distribution([entry.durationMs, entry.interactionId]) || !Number.isInteger(entry.interactionId),
        ) ||
        (sample.reactCommits !== null && (!Number.isInteger(sample.reactCommits) || sample.reactCommits < 0)),
    )
  )
    errors.push("invalid sample metrics");
  const trace =
    traces.length === samples.length && traces.length > 0
      ? {
          ...traces[0],
          scriptMs: traces.reduce((n, t) => n + t.scriptMs, 0),
          styleMs: traces.reduce((n, t) => n + t.styleMs, 0),
          layoutMs: traces.reduce((n, t) => n + t.layoutMs, 0),
        }
      : null;
  if (trace && !distribution([trace.scriptMs, trace.styleMs, trace.layoutMs])) errors.push("invalid trace metrics");
  if (trace) unsupportedReasons.trace = trace.unsupportedReason;
  const fits = (frame: number) =>
    errors.length === 0 && longTaskRuns * 2 <= samples.length && paint <= 2 * frame && frameGap <= 1.5 * frame;
  return {
    ...spec,
    id: `${spec.engine}/${spec.page}/${action.id ?? action.name}`,
    action: action.name,
    metricType,
    samples,
    latencyMs,
    errors,
    timeouts: runs - samples.length,
    work,
    paint,
    frameGap,
    frames: stats((sample) => sample.frames)?.p50 ?? 0,
    maxWork: stats((sample) => sample.work)?.max ?? 0,
    maxPaint: stats((sample) => sample.paint)?.max ?? 0,
    longTaskRuns,
    budget,
    pass60: fits(BUDGET_60HZ),
    pass120: budget < 12 ? fits(BUDGET_120HZ) : fits(BUDGET_60HZ) && work <= BUDGET_120HZ,
    pass: fits(BUDGET_60HZ),
    longTasks: longTasksSupported
      ? {
          count: tasks.length,
          totalMs: tasks.reduce((a, b) => a + b, 0),
          maxMs: Math.max(0, ...tasks),
          source: "PerformanceObserver longtask",
        }
      : null,
    reactCommits: unsupportedReasons.reactCommits
      ? null
      : samples.reduce((n, sample) => n + (sample.reactCommits ?? 0), 0),
    framesSummary: {
      count: samples.reduce((n, sample) => n + sample.frames, 0),
      dropped: samples
        .flatMap((sample) => sample.frameGaps)
        .reduce((n, gap) => n + Math.max(0, Math.round(gap / budget) - 1), 0),
      maxGapMs: stats((sample) => sample.maxFrameGap)?.max ?? 0,
      droppedSource: "estimated from calibrated rAF cadence; not compositor dropped frames",
    },
    trace,
    unsupportedReasons,
  };
}

export async function measureAction(
  page: Page,
  spec: { page: string; engine: string },
  action: LatencyAction,
  runs = 5,
  metrics?: MetricReader,
): Promise<ActionResult> {
  const budget = await frameBudget(page);
  if (action.measureRun) {
    const { measureAdapterAction } = await import("./adapter-measure");
    return measureAdapterAction(page, spec, action, runs, budget);
  }
  const samples: LatencySample[] = [];
  const errors: string[] = [];
  const traces: TraceBreakdown[] = [];
  for (let run = 0; run < runs; run += 1) {
    const result = await measureOnce(page, action, 5000, metrics);
    if (result.sample) samples.push(result.sample);
    else errors.push(result.error ?? "measurement returned no sample");
    if (result.trace) traces.push(result.trace);
  }
  return aggregateAction(spec, action, samples, errors, runs, budget, traces);
}
