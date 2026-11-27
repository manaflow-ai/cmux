/** Deterministic browser motion evidence for gallery plays.
 *
 * A probe samples the real DOM on animation frames while a play drives an interaction. It is
 * separate from screenshots: frame samples and derived metrics are stable enough to gate, while
 * video remains an opt-in reviewer artifact in the matrix runner.
 */

export type MotionProbeKind = "streaming-follow" | "scroll-thumb" | "reasoning-slider";

export type MotionProbeSpec = {
  kind: MotionProbeKind;
  target: string;
  visual?: string;
  viewport?: string;
  maxMs?: number;
};

export type MotionSample = { t: number; value: number; secondary?: number; width?: number; height?: number };
export type MotionMetrics = {
  frames: number;
  durationMs: number;
  travel: number;
  maxStep: number;
  maxAbsSecondary: number;
  signChanges: number;
  settledMs: number | null;
};
export type MotionEvidence = {
  kind: MotionProbeKind;
  target: string;
  visual?: string;
  samples: MotionSample[];
  metrics: MotionMetrics;
  status: "pass" | "warn" | "fail";
  problems: string[];
};
export type MotionController = {
  start(spec: MotionProbeSpec): void;
  stop(): MotionEvidence | undefined;
  read(): MotionEvidence | undefined;
};

// A followed transcript is allowed a few pixels of measured give between layout commits. This
// matches VirtualTranscript's bottom-follow deadband: the evidence should catch a visible loss of
// the newest line without turning sub-line rounding into a flaky failure.
export const STREAMING_FOLLOW_MAX_GAP_PX = 4;

const finite = (value: number) => (Number.isFinite(value) ? value : 0);

function sampleFor(spec: MotionProbeSpec, started: number): MotionSample | undefined {
  const target = document.querySelector<HTMLElement>(spec.target);
  if (!target) return undefined;
  const t = finite(performance.now() - started);
  if (spec.kind === "streaming-follow") {
    const max = Math.max(0, target.scrollHeight - target.clientHeight);
    return { t, value: finite(target.scrollTop), secondary: finite(max - target.scrollTop) };
  }
  const visual = document.querySelector<HTMLElement>(spec.visual ?? spec.target);
  const viewport = document.querySelector<HTMLElement>(spec.viewport ?? spec.target);
  if (!visual || !viewport) return undefined;
  const visualRect = visual.getBoundingClientRect();
  const viewportRect = viewport.getBoundingClientRect();
  return {
    t,
    value: spec.kind === "scroll-thumb" ? finite(visualRect.height) : finite(visualRect.left),
    secondary: finite(visualRect.top - viewportRect.top),
    width: finite(visualRect.width),
    height: finite(visualRect.height),
  };
}

export function motionMetrics(samples: MotionSample[]): MotionMetrics {
  if (samples.length < 2)
    return {
      frames: samples.length,
      durationMs: samples.at(-1)?.t ?? 0,
      travel: 0,
      maxStep: 0,
      maxAbsSecondary: 0,
      signChanges: 0,
      settledMs: null,
    };
  const first = samples[0]!;
  const last = samples.at(-1)!;
  const deltas = samples.slice(1).map((sample, index) => sample.value - samples[index]!.value);
  let signChanges = 0;
  let previous = 0;
  for (const delta of deltas) {
    if (Math.abs(delta) < 0.01) continue;
    const sign = Math.sign(delta);
    if (previous && sign !== previous) signChanges += 1;
    previous = sign;
  }
  const settledIndex = samples.findIndex(
    (sample, index) =>
      index >= 2 && samples.slice(index - 2, index + 1).every((entry) => Math.abs(entry.value - last.value) < 0.5),
  );
  return {
    frames: samples.length,
    durationMs: finite(last.t),
    travel: finite(last.value - first.value),
    maxStep: finite(Math.max(...deltas.map(Math.abs))),
    maxAbsSecondary: finite(Math.max(...samples.map((sample) => Math.abs(sample.secondary ?? 0)))),
    signChanges,
    settledMs: settledIndex < 0 ? null : finite(samples[settledIndex]!.t),
  };
}

export function judgeMotionProbe(
  spec: MotionProbeSpec,
  samples: MotionSample[],
  result = motionMetrics(samples),
): Pick<MotionEvidence, "status" | "problems"> {
  const problems: string[] = [];
  if (samples.length < 3) problems.push("fewer than three animation frames were sampled");
  if (spec.kind === "streaming-follow" && result.maxAbsSecondary > STREAMING_FOLLOW_MAX_GAP_PX)
    problems.push(
      `bottom gap reached ${result.maxAbsSecondary.toFixed(2)} px (limit ${STREAMING_FOLLOW_MAX_GAP_PX} px)`,
    );
  if (spec.kind === "streaming-follow" && result.signChanges > Math.max(2, Math.floor(samples.length / 8)))
    problems.push(`bottom follow changed direction ${result.signChanges} times`);
  if (spec.kind !== "streaming-follow" && result.settledMs === null) problems.push("motion did not settle");
  return { status: problems.length ? "fail" : "pass", problems };
}

export function createMotionController(): MotionController {
  let active:
    | { spec: MotionProbeSpec; started: number; samples: MotionSample[]; frame: number; timer?: number }
    | undefined;
  let last: MotionEvidence | undefined;
  const stop = (): MotionEvidence | undefined => {
    if (!active) return last;
    cancelAnimationFrame(active.frame);
    if (active.timer !== undefined) clearTimeout(active.timer);
    const result = motionMetrics(active.samples);
    last = {
      kind: active.spec.kind,
      target: active.spec.target,
      visual: active.spec.visual,
      samples: active.samples,
      metrics: result,
      ...judgeMotionProbe(active.spec, active.samples, result),
    };
    active = undefined;
    return last;
  };
  const tick = () => {
    if (!active) return;
    const sample = sampleFor(active.spec, active.started);
    if (sample) active.samples.push(sample);
    active.frame = requestAnimationFrame(tick);
  };
  return {
    start(spec) {
      stop();
      const maxMs = Math.max(250, Math.min(spec.maxMs ?? 3_000, 15_000));
      active = { spec, started: performance.now(), samples: [], frame: 0 };
      active.frame = requestAnimationFrame(tick);
      active.timer = window.setTimeout(stop, maxMs);
    },
    stop,
    read: () => last,
  };
}
