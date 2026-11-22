// Test helper of the interaction-latency harness: measures one named action in a Playwright page
// that has the probe installed (probe.ts), and judges it against the display's frame budget.
// scripts/latency/run.ts drives every page's actions with it; tests can call it directly.
import type { Page } from "playwright";
import type { LatencySample } from "./probe";

export type { LatencySample } from "./probe";

export interface LatencyAction {
  name: string;
  /**
   * Brings the page to the state the input acts on (not measured) and returns the predicate: a JS
   * expression, evaluated in the page, that is false now and true once the response is visible.
   */
  prepare(page: Page): Promise<string>;
  /** The user input. */
  input(page: Page): Promise<void>;
  /** After a run (not measured): lets the page settle before the next one. */
  settle?(page: Page): Promise<void>;
}

export interface LatencyPageSpec {
  name: string;
  /** Path on the webviews dev server. */
  path: string;
  /** A JS expression that holds once the page is ready for input. */
  ready: string;
  actions: LatencyAction[];
}

export interface ActionResult {
  page: string;
  action: string;
  engine: string;
  samples: LatencySample[];
  /** Runs that never showed a response. */
  timeouts: number;
  errors: string[];
  /** Medians over the samples, ms. */
  work: number;
  paint: number;
  frames: number;
  maxWork: number;
  maxPaint: number;
  /** Median of each run's longest frame interval in the window, ms. */
  frameGap: number;
  /** Runs with a long task on the input path. */
  longTaskRuns: number;
  /** The page's measured frame interval (headless Chromium ticks near 120 Hz, WebKit at 60 Hz), ms. */
  budget: number;
  pass60: boolean;
  pass120: boolean;
  pass: boolean;
}

export const BUDGET_120HZ = 1000 / 120;
export const BUDGET_60HZ = 1000 / 60;

function median(values: number[]): number {
  if (values.length === 0) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

/** The display's frame interval as the page measures it, snapped to 60/120 Hz when close. */
export async function frameBudget(page: Page): Promise<number> {
  const interval = await page.evaluate(() => window.__latency?.frameInterval() ?? 16.7);
  if (Math.abs(interval - 1000 / 120) < 1.5) return 1000 / 120;
  if (Math.abs(interval - 1000 / 60) < 3) return 1000 / 60;
  return interval;
}

/** One run of `action`: prepare, arm, input, wait for the response and its paint. */
export async function measureOnce(
  page: Page,
  action: LatencyAction,
  timeoutMs = 5000,
): Promise<{ sample: LatencySample | null; error?: string }> {
  let predicate: string;
  try {
    predicate = await action.prepare(page);
  } catch (error) {
    return { sample: null, error: `prepare failed: ${String((error as Error).message ?? error).split("\n")[0]}` };
  }
  await page.evaluate(`window.__latencyCheck = () => (${predicate});`);
  await page.evaluate((source) => window.__latency!.arm(source), predicate);
  const armError = await page.evaluate(() => window.__latency!.error);
  if (armError) return { sample: null, error: armError };
  try {
    await action.input(page);
  } catch (error) {
    return { sample: null, error: `input failed: ${String((error as Error).message ?? error).split("\n")[0]}` };
  }
  try {
    await page.waitForFunction(() => window.__latency?.state === "done", undefined, { timeout: timeoutMs });
  } catch {
    return { sample: null, error: `no response within ${timeoutMs} ms (predicate: ${predicate})` };
  } finally {
    await action.settle?.(page);
  }
  return { sample: await page.evaluate(() => window.__latency!.result()) };
}

/**
 * Measures `action` `runs` times. Judged on the medians, against a 60 Hz frame (the gate):
 * - the response paints in the frame the input arrived in or the next one (paint <= 2 frames);
 * - no frame is dropped on the way (the longest frame interval in the window <= 1.5 frames);
 * - no more than half of the runs had a long task (over 50 ms) between the input and the paint.
 * The 120 Hz verdict also needs the input-to-response work to fit one 120 Hz frame (the runner's
 * display is 60 Hz, so this is the part of 120 Hz that can be measured there).
 */
export async function measureAction(
  page: Page,
  spec: { page: string; engine: string },
  action: LatencyAction,
  runs = 5,
): Promise<ActionResult> {
  const budget = await frameBudget(page);
  const samples: LatencySample[] = [];
  const errors: string[] = [];
  let timeouts = 0;
  for (let run = 0; run < runs; run += 1) {
    const { sample, error } = await measureOnce(page, action);
    if (sample) samples.push(sample);
    else {
      timeouts += 1;
      if (error) errors.push(error);
    }
  }
  const work = median(samples.map((sample) => sample.work));
  const paint = median(samples.map((sample) => sample.paint));
  const frameGap = median(samples.map((sample) => sample.maxFrameGap));
  const longTaskRuns = samples.filter((sample) => sample.longTasks.length > 0).length;
  const healthy = timeouts === 0 && samples.length > 0 && longTaskRuns * 2 <= samples.length;
  const fits = (frame: number) => healthy && paint <= 2 * frame && frameGap <= 1.5 * frame;
  return {
    page: spec.page,
    action: action.name,
    engine: spec.engine,
    samples,
    timeouts,
    errors,
    work,
    paint,
    frameGap,
    frames: median(samples.map((sample) => sample.frames)),
    maxWork: Math.max(...samples.map((sample) => sample.work)),
    maxPaint: Math.max(...samples.map((sample) => sample.paint)),
    longTaskRuns,
    budget,
    pass60: fits(BUDGET_60HZ),
    pass120: budget < 12 ? fits(BUDGET_120HZ) : fits(BUDGET_60HZ) && work <= BUDGET_120HZ,
    // The gate is the 60 Hz verdict (one 16.7 ms frame); the measured refresh only decides whether
    // the 120 Hz verdict was measured (a 120 Hz runner) or estimated from `work`.
    pass: fits(BUDGET_60HZ),
  };
}
