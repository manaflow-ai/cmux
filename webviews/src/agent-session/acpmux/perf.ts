// Debug-only performance measurement for the agent pane, driven by the
// DEBUG `debug.agent_pane` socket method through `window.cmuxAcpmuxDebug`.
// Everything here is inert until the first debug call sets `acpmuxPerf.enabled`:
// the render path then pays one boolean check per render.

/** Rounds to hundredths, as the native pane's stats do. */
export function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

/** The value at fraction `p` of `sorted` (ascending), index round((n-1)*p); 0 when empty. */
export function percentile(sorted: ArrayLike<number>, p: number): number {
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * p)))];
}

/** The median of `values` (unsorted); 0 when empty. */
export function median(values: number[]): number {
  return percentile(
    [...values].sort((a, b) => a - b),
    0.5,
  );
}

/** Intervals between consecutive timestamps. */
export function intervalsOf(timestamps: number[]): number[] {
  const intervals: number[] = [];
  for (let index = 1; index < timestamps.length; index += 1) intervals.push(timestamps[index] - timestamps[index - 1]);
  return intervals;
}

/** Frames missed against `nominal`: Σ max(0, round(interval / nominal) − 1). */
export function droppedFrames(intervals: number[], nominal: number): number {
  if (!(nominal > 0)) return 0;
  let dropped = 0;
  for (const interval of intervals) dropped += Math.max(0, Math.round(interval / nominal) - 1);
  return dropped;
}

export type FrameStats = {
  frames: number;
  nominal_ms: number;
  p50_ms: number;
  p95_ms: number;
  p99_ms: number;
  max_ms: number;
  dropped_frames: number;
};

/** Frame timing from display-frame timestamps, the shape of the native pane's `fling_stats`. */
export function frameStats(timestamps: number[], nominal: number): FrameStats {
  const intervals = intervalsOf(timestamps).sort((a, b) => a - b);
  return {
    frames: timestamps.length,
    nominal_ms: round2(nominal),
    p50_ms: round2(percentile(intervals, 0.5)),
    p95_ms: round2(percentile(intervals, 0.95)),
    p99_ms: round2(percentile(intervals, 0.99)),
    max_ms: round2(intervals.at(-1) ?? 0),
    dropped_frames: droppedFrames(intervals, nominal),
  };
}

/** p50/p95/max of `values` (unsorted), rounded. */
export function summary(values: number[]): { p50_ms: number; p95_ms: number; max_ms: number } {
  const sorted = [...values].sort((a, b) => a - b);
  return {
    p50_ms: round2(percentile(sorted, 0.5)),
    p95_ms: round2(percentile(sorted, 0.95)),
    max_ms: round2(sorted.at(-1) ?? 0),
  };
}

/** True when the mounted rows [mountedTop, mountedBottom) leave part of the viewport empty. */
export function isBlank(
  mountedTop: number,
  mountedBottom: number,
  scrollTop: number,
  viewportHeight: number,
  contentHeight: number,
): boolean {
  const viewTop = Math.max(0, scrollTop);
  const viewBottom = Math.min(contentHeight, scrollTop + viewportHeight);
  if (viewBottom <= viewTop) return false;
  return mountedTop > viewTop + 0.5 || mountedBottom < viewBottom - 0.5;
}

/** A fixed-capacity ring of per-frame samples; the oldest is overwritten. */
export class FrameRing {
  readonly capacity: number;
  private readonly interval: Float64Array;
  private readonly layout: Float64Array;
  private readonly react: Float64Array;
  private readonly blank: Uint8Array;
  private next = 0;
  private count = 0;

  constructor(capacity = 2048) {
    this.capacity = capacity;
    this.interval = new Float64Array(capacity);
    this.layout = new Float64Array(capacity);
    this.react = new Float64Array(capacity);
    this.blank = new Uint8Array(capacity);
  }

  get size(): number {
    return this.count;
  }

  clear(): void {
    this.next = 0;
    this.count = 0;
  }

  push(interval: number, layout: number, react: number, blank: boolean): void {
    this.interval[this.next] = interval;
    this.layout[this.next] = layout;
    this.react[this.next] = react;
    this.blank[this.next] = blank ? 1 : 0;
    this.next = (this.next + 1) % this.capacity;
    this.count = Math.min(this.capacity, this.count + 1);
  }

  /** Samples oldest first. `other` is the interval not spent in layout or React. */
  samples(): { interval: number; layout: number; react: number; other: number; blank: boolean }[] {
    const out: { interval: number; layout: number; react: number; other: number; blank: boolean }[] = [];
    const start = (this.next - this.count + this.capacity) % this.capacity;
    for (let offset = 0; offset < this.count; offset += 1) {
      const index = (start + offset) % this.capacity;
      out.push({
        interval: this.interval[index],
        layout: this.layout[index],
        react: this.react[index],
        other: Math.max(0, this.interval[index] - this.layout[index] - this.react[index]),
        blank: this.blank[index] === 1,
      });
    }
    return out;
  }
}

export type TypingSample = { frame: number; paint: number };
type AgentMark = "handshakeStart" | "handshakeReady" | "composerReady" | "snapshotPaint" | "firstToken";

/** Typing latency: keydown event time to the next frame and to after that frame paints. */
export function typingSummary(samples: TypingSample[]) {
  return {
    keys: samples.length,
    to_frame: summary(samples.map((sample) => sample.frame)),
    to_paint: summary(samples.map((sample) => sample.paint)),
  };
}

/**
 * Process-wide recorder. VirtualTranscript reports layout and render time and
 * the mounted range; the fling marks one frame per display frame.
 */
export class AcpmuxPerf {
  enabled = false;
  readonly ring = new FrameRing();
  /** Layout and React time since the last frame mark. */
  private layoutSinceMark = 0;
  private reactSinceMark = 0;
  private lastMark: number | undefined;
  /** Pixel extent of the mounted rows at the last commit. */
  mountedTop = 0;
  mountedBottom = 0;
  private commitWaiters: ((now: number) => void)[] = [];
  readonly typing: TypingSample[] = [];
  private agentMarks: Partial<Record<AgentMark, number>> = {};
  private keyListener: ((event: KeyboardEvent) => void) | undefined;

  /** Turns measurement on; installs the composer key listener once. */
  enable(
    target: Pick<Document, "addEventListener"> | undefined = typeof document === "undefined" ? undefined : document,
  ): void {
    this.enabled = true;
    if (this.keyListener || !target) return;
    this.keyListener = (event) => {
      const element = event.target as Element | null;
      if (!element?.closest?.(".acpmux-composer")) return;
      const start = event.timeStamp;
      requestAnimationFrame(() => {
        const frame = performance.now();
        const channel = new MessageChannel();
        channel.port1.onmessage = () => {
          this.typing.push({ frame: frame - start, paint: performance.now() - start });
          if (this.typing.length > 4096) this.typing.shift();
          channel.port1.close();
        };
        channel.port2.postMessage(0);
      });
    };
    target.addEventListener("keydown", this.keyListener as EventListener, true);
  }

  /** Lifecycle marks used by the warm-chat before/after capture. */
  markAgent(stage: AgentMark): void {
    if (stage === "handshakeStart") {
      delete this.agentMarks.handshakeReady;
      delete this.agentMarks.composerReady;
      delete this.agentMarks.firstToken;
    }
    if (stage === "firstToken" && this.agentMarks.firstToken !== undefined) return;
    this.agentMarks[stage] = performance.now();
  }

  agentLatency(): Record<string, number> {
    const start = this.agentMarks.handshakeStart;
    const value: Record<string, number> = {};
    for (const [name, at] of Object.entries(this.agentMarks)) {
      if (at === undefined) continue;
      value[`${name}_ms`] = round2(start === undefined ? at : at - start);
    }
    if (start !== undefined && this.agentMarks.composerReady !== undefined)
      value.composer_ready_ms = round2(this.agentMarks.composerReady - start);
    if (start !== undefined && this.agentMarks.firstToken !== undefined)
      value.first_token_ms = round2(this.agentMarks.firstToken - start);
    return value;
  }

  addLayout(ms: number): void {
    this.layoutSinceMark += ms;
  }

  /** A VirtualTranscript commit: render-start to commit took `ms`, `layoutMs` of it in geometry. */
  commit(ms: number, layoutMs: number, mountedTop: number, mountedBottom: number, now: number): void {
    this.reactSinceMark += Math.max(0, ms - layoutMs);
    this.mountedTop = mountedTop;
    this.mountedBottom = mountedBottom;
    const waiters = this.commitWaiters;
    this.commitWaiters = [];
    for (const resolve of waiters) resolve(now);
  }

  /** Resolves with the time of the next VirtualTranscript commit, or undefined after `timeoutMs`. */
  nextCommit(timeoutMs = 10_000): Promise<number | undefined> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.commitWaiters = this.commitWaiters.filter((waiter) => waiter !== done);
        resolve(undefined);
      }, timeoutMs);
      const done = (now: number) => {
        clearTimeout(timer);
        resolve(now);
      };
      this.commitWaiters.push(done);
    });
  }

  /** Starts a new frame recording. */
  resetFrames(): void {
    this.ring.clear();
    this.lastMark = undefined;
    this.layoutSinceMark = 0;
    this.reactSinceMark = 0;
  }

  /** One display frame at `now`; `blank` is whether the viewport shows past the mounted rows. */
  markFrame(now: number, blank: boolean): void {
    if (this.lastMark !== undefined)
      this.ring.push(now - this.lastMark, this.layoutSinceMark, this.reactSinceMark, blank);
    this.lastMark = now;
    this.layoutSinceMark = 0;
    this.reactSinceMark = 0;
  }

  /** The per-frame breakdown of the last recording. */
  stats(raw = false): Record<string, unknown> {
    const samples = this.ring.samples();
    const result: Record<string, unknown> = {
      frames: samples.length,
      blank_frames: samples.filter((sample) => sample.blank).length,
      interval: summary(samples.map((sample) => sample.interval)),
      layout: summary(samples.map((sample) => sample.layout)),
      react: summary(samples.map((sample) => sample.react)),
      other: summary(samples.map((sample) => sample.other)),
    };
    if (raw)
      result.samples = samples.map((sample) => ({
        interval_ms: round2(sample.interval),
        layout_ms: round2(sample.layout),
        react_ms: round2(sample.react),
        other_ms: round2(sample.other),
        blank: sample.blank,
      }));
    return result;
  }
}

export const acpmuxPerf = new AcpmuxPerf();
