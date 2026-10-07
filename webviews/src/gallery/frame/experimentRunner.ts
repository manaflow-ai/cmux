// A stage frame's experiment harness (frame.html with `exp` and `arm` in its query): the page under
// test runs the arm the query names (experiments/experiment.ts reads `globalThis.cmuxExperiments`),
// and every Web Animation it starts is under the harness's control:
//   - instant: finished at once (the setup and the fast-forward to `step=N`);
//   - live: at the compare view's speed (0.1x to 1x), tracked until it ends;
//   - freeze: paused `atMs` after it starts (the matrix runner's frame strips).
// The compare view sends `{ op: "step", index, speed }` to every cell at the same time and waits
// for each cell's `step-done`; the frame measures its own frames while a step runs.
// `measure=1` (the matrix runner) runs the whole script at 1x before the stage is ready and puts
// the numbers in `window.cmuxGalleryExperimentReport`. `freeze=<step>:<ms>` shows the frame `ms`
// after step `<step>`'s input (1-based), for a frame strip.
import { frameStats, type CompareFrameCommand, type CompareFrameEvent, type StepStats } from "../compare";
import type { GalleryExperiment } from "../format";
import { runPlay } from "./playRunner";

type Mode = { kind: "instant" } | { kind: "live"; speed: number } | { kind: "freeze"; atMs: number };

export type ExperimentReport = {
  experiment: string;
  arm: string;
  steps: { name: string; stats: StepStats; problems: string[] }[];
  /** Every step's frames together. */
  total: StepStats;
};

declare global {
  interface Window {
    cmuxGalleryExperimentReport?: ExperimentReport;
  }
}

let mode: Mode = { kind: "instant" };
const running = new Set<Animation>();
/** Ambient animations (a hover marquee) never hold a step; their id starts with this. */
const AMBIENT = "cmux-ambient";

/** Puts every Web Animation the page starts under the harness (call before the page mounts). */
export function installAnimationControl(): void {
  const original = Element.prototype.animate;
  Element.prototype.animate = function animate(this: Element, keyframes, options) {
    const animation = original.call(this, keyframes, options);
    if (mode.kind === "instant") {
      animation.finish();
      return animation;
    }
    if (mode.kind === "freeze") {
      animation.pause();
      animation.currentTime = mode.atMs;
      return animation;
    }
    animation.playbackRate = mode.speed;
    // The id is set after `animate` returns, so it is read when the step waits.
    running.add(animation);
    const done = () => running.delete(animation);
    animation.finished.then(done, done);
    return animation;
  };
}

const nextFrame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

/** Resolves when every non-ambient animation the step started has ended (new ones included). */
async function animationsDone(): Promise<void> {
  for (;;) {
    const waiting = [...running].filter((animation) => !animation.id.startsWith(AMBIENT));
    if (!waiting.length) return;
    await Promise.allSettled(waiting.map((animation) => animation.finished));
    await nextFrame();
  }
}

/** Runs one step at `speed` and measures its frames (rAF intervals) and the arm's planning time. */
async function measuredStep(
  experiment: GalleryExperiment,
  index: number,
  speed: number,
): Promise<{ stats: StepStats; problems: string[] }> {
  mode = { kind: "live", speed };
  const intervals: number[] = [];
  let planMs = 0;
  const measures = new PerformanceObserver((list) => {
    for (const entry of list.getEntries())
      if (entry.name.startsWith("cmux-motion:")) planMs = Math.max(planMs, entry.duration);
  });
  measures.observe({ type: "measure", buffered: false });
  let sampling = true;
  const sampler = (async () => {
    let last = await nextFrame();
    while (sampling) {
      const now = await nextFrame();
      intervals.push(now - last);
      last = now;
    }
  })();
  const started = performance.now();
  const report = await runPlay(experiment.script[index]!.run, {});
  await animationsDone();
  const durationMs = performance.now() - started;
  await nextFrame();
  sampling = false;
  await sampler;
  measures.takeRecords();
  measures.disconnect();
  const problems = report.error ? [report.error] : report.steps.flatMap((step) => step.problems);
  return {
    stats: { durationMs: Math.round(durationMs), ...frameStats(intervals), planMs: Math.round(planMs * 100) / 100 },
    problems,
  };
}

async function runInstant(experiment: GalleryExperiment, steps: number): Promise<void> {
  mode = { kind: "instant" };
  if (experiment.setup) await runPlay(experiment.setup, {});
  for (let index = 0; index < steps; index += 1) await runPlay(experiment.script[index]!.run, {});
  await nextFrame();
}

const post = (event: CompareFrameEvent) => parent.postMessage(event, "*");

/**
 * Brings the stage to the state the query names before it reports ready: the setup, then `step`
 * steps (all instant), or the measured script (`measure=1`), or one frozen frame (`freeze`).
 */
export async function prepareExperiment(
  experiment: GalleryExperiment,
  params: URLSearchParams,
  arm: string,
): Promise<void> {
  const steps = experiment.script.length;
  const freeze = /^(\d+):(\d+)$/.exec(params.get("freeze") ?? "");
  if (freeze) {
    const step = Math.max(1, Math.min(steps, Number(freeze[1])));
    await runInstant(experiment, step - 1);
    mode = { kind: "freeze", atMs: Number(freeze[2]) };
    await runPlay(experiment.script[step - 1]!.run, {});
    await nextFrame();
    return;
  }
  if (params.get("measure") === "1") {
    await runInstant(experiment, 0);
    const results: ExperimentReport["steps"] = [];
    for (let index = 0; index < steps; index += 1)
      results.push({ name: experiment.script[index]!.name, ...(await measuredStep(experiment, index, 1)) });
    const all = results.map((result) => result.stats);
    window.cmuxGalleryExperimentReport = {
      experiment: experiment.definition.id,
      arm,
      steps: results,
      total: {
        durationMs: all.reduce((sum, stats) => sum + stats.durationMs, 0),
        frames: all.reduce((sum, stats) => sum + stats.frames, 0),
        p50: Math.max(...all.map((stats) => stats.p50)),
        p95: Math.max(...all.map((stats) => stats.p95)),
        max: Math.max(...all.map((stats) => stats.max)),
        over16: all.reduce((sum, stats) => sum + stats.over16, 0),
        planMs: Math.max(...all.map((stats) => stats.planMs)),
      },
    };
    return;
  }
  const at = Number(params.get("step") ?? 0);
  await runInstant(experiment, Number.isInteger(at) ? Math.max(0, Math.min(steps, at)) : 0);
  // The compare view drives the steps from here.
  let queue = Promise.resolve();
  addEventListener("message", (event: MessageEvent) => {
    const data = event.data as CompareFrameCommand | null;
    if (event.source !== parent || data?.type !== "cmux-exp" || data.op !== "step") return;
    queue = queue.then(async () => {
      try {
        const { stats } = await measuredStep(experiment, data.index, data.speed);
        post({ type: "cmux-exp", event: "step-done", index: data.index, stats });
      } catch (error) {
        post({ type: "cmux-exp", event: "error", message: error instanceof Error ? error.message : String(error) });
      }
    });
  });
}

/** Tells the compare view this cell is ready for steps. */
export function announceReady(experiment: GalleryExperiment): void {
  post({ type: "cmux-exp", event: "ready", steps: experiment.script.length });
}
