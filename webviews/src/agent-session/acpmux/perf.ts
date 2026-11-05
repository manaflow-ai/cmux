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

/** Pixel extent [top, bottom) of one run of mounted rows. */
export type MountedSpan = readonly [top: number, bottom: number];

/** True when the mounted rows (separate runs, as a fast scroll mounts them) leave part of the viewport empty. */
export function isBlank(
  mounted: readonly MountedSpan[],
  scrollTop: number,
  viewportHeight: number,
  contentHeight: number,
): boolean {
  const viewTop = Math.max(0, scrollTop);
  const viewBottom = Math.min(contentHeight, scrollTop + viewportHeight);
  if (viewBottom <= viewTop) return false;
  // Runs are separated by rows that are not mounted, so one run has to hold the whole view.
  return !mounted.some(([top, bottom]) => top <= viewTop + 0.5 && bottom >= viewBottom - 0.5);
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
/**
 * The page's connect path on the wall clock (`Date.now()`), the first time of each since the page
 * loaded: the relaunch-reconnect bench lines them up with the app's launch marks
 * (scripts/cmux-next/bench_relaunch_reconnect.py). `handshakeStart` is the first ask (a retry
 * keeps it), `connectStart` and `connected` bracket the client's connect (transport open,
 * `initialize`, the first read; `socketOpen`, `initialized` and `attached` inside it), `chatDrawn`
 * the first render that drew what the pane is and `paintPosted` its `pane.painted`, `firstEvent` is the first event of the shown chat to arrive, and
 * `liveEvent` the first that arrives within LIVE_EVENT_LAG_MS of when acpmux recorded it: the chat
 * is live, past any backlog.
 */
type LaunchMark =
  | "handshakeStart"
  | "handshakeReady"
  | "connectStart"
  | "socketOpen"
  | "initialized"
  | "attached"
  | "connected"
  | "chatDrawn"
  | "paintPosted"
  | "firstEvent"
  | "liveEvent";
/** An event that arrives this soon after acpmux recorded it is live, not backlog. */
export const LIVE_EVENT_LAG_MS = 1000;

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
  /** Named spans since the last frame mark (`span`), and each recorded frame's, oldest first. */
  private spansSinceMark = new Map<string, number>();
  private spanFrames: Map<string, number>[] = [];
  private lastMark: number | undefined;
  /** Pixel extent of each run of mounted rows at the last commit. */
  mounted: MountedSpan[] = [];
  private commitWaiters: ((now: number) => void)[] = [];
  readonly typing: TypingSample[] = [];
  private agentMarks: Partial<Record<AgentMark, number>> = {};
  /// A new chat's start state as its frames show it (the New Tab chip's folder, the hero's project
  /// and its Do not work in a project check): the first one drawn, and when it last changed.
  private startState: { shown: string; first: number; final: number; changes: number } | undefined;
  private launchMarks: Partial<Record<LaunchMark, number>> = {};
  private handshakeAttempts = 0;
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

  /** The start state a frame shows (`shown`, any stable text); recorded always, a string compare per change. */
  noteStartState(shown: string, now = performance.now()): void {
    const state = this.startState;
    if (!state) this.startState = { shown, first: now, final: now, changes: 0 };
    else if (state.shown !== shown)
      this.startState = { shown, first: state.first, final: now, changes: state.changes + 1 };
  }

  /** The start the frames show now (`noteStartState`), for a bench to compare runs. */
  startStateShown(): string | undefined {
    return this.startState?.shown;
  }

  /** A New Tab page adopted again (Cmd-T on a spare): its start state is measured from there. */
  resetStartState(): void {
    this.startState = undefined;
  }

  /** Records `stage` on the wall clock once per page (`LaunchMark`). */
  markLaunch(stage: LaunchMark, now = Date.now()): void {
    if (stage === "handshakeStart") this.handshakeAttempts += 1;
    if (this.launchMarks[stage] === undefined) this.launchMarks[stage] = now;
  }

  /** An event of the shown chat arrived; `at` is when acpmux recorded it (ms since 1970). */
  markEvent(at: unknown, now = Date.now()): void {
    if (this.launchMarks.liveEvent !== undefined) return;
    this.markLaunch("firstEvent", now);
    if (typeof at === "number" && Number.isFinite(at) && at > 0 && now - at <= LIVE_EVENT_LAG_MS)
      this.launchMarks.liveEvent = now;
  }

  /** The page's launch marks (ms since 1970) and how many handshakes it asked for. */
  launchTimeline(): Record<string, number> {
    const value: Record<string, number> = { handshake_attempts: this.handshakeAttempts };
    if (typeof performance !== "undefined" && Number.isFinite(performance.timeOrigin))
      value.page_origin_epoch_ms = Math.round(performance.timeOrigin);
    for (const [name, at] of Object.entries(this.launchMarks)) if (at !== undefined) value[`${name}_epoch_ms`] = at;
    return value;
  }

  agentLatency(): Record<string, number> {
    const start = this.agentMarks.handshakeStart;
    const value: Record<string, number> = {};
    // First frame to the frame whose start state stayed (0: the first frame was final).
    if (this.startState) {
      value.start_state_final_ms = round2(this.startState.final - this.startState.first);
      value.start_state_changes = this.startState.changes;
      // Wall-clock time of the final one, so a bench on the same Mac times it from its own key press.
      value.start_state_final_epoch_ms = round2(performance.timeOrigin + this.startState.final);
    }
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

  /** Adds `ms` to the named span of the current frame (client reduce, row derivation, a flush). */
  /** Renders per component since `resetRenders` (tests: a streamed chunk renders only its row). */
  readonly renders = new Map<string, number>();

  /** Counts one render of `name` while measuring. */
  render(name: string): void {
    if (!this.enabled) return;
    this.renders.set(name, (this.renders.get(name) ?? 0) + 1);
  }

  resetRenders(): void {
    this.renders.clear();
  }

  span(name: string, ms: number): void {
    if (!this.enabled) return;
    this.spansSinceMark.set(name, (this.spansSinceMark.get(name) ?? 0) + ms);
  }

  /** Runs `body`, adding its time to the named span when measuring. */
  timed<T>(name: string, body: () => T): T {
    if (!this.enabled) return body();
    const start = performance.now();
    try {
      return body();
    } finally {
      this.span(name, performance.now() - start);
    }
  }

  addLayout(ms: number): void {
    this.layoutSinceMark += ms;
  }

  /** A VirtualTranscript commit: render-start to commit took `ms`, `layoutMs` of it in geometry. */
  commit(ms: number, layoutMs: number, mounted: MountedSpan[], now: number): void {
    this.reactSinceMark += Math.max(0, ms - layoutMs);
    this.mounted = mounted;
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
    this.spansSinceMark = new Map();
    this.spanFrames = [];
  }

  /** One display frame at `now`; `blank` is whether the viewport shows past the mounted rows. */
  markFrame(now: number, blank: boolean): void {
    if (this.lastMark !== undefined) {
      this.ring.push(now - this.lastMark, this.layoutSinceMark, this.reactSinceMark, blank);
      this.spanFrames.push(this.spansSinceMark);
      if (this.spanFrames.length > this.ring.capacity) this.spanFrames.shift();
    }
    this.lastMark = now;
    this.layoutSinceMark = 0;
    this.reactSinceMark = 0;
    this.spansSinceMark = new Map();
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
    const spanFrames = this.spanFrames.slice(-samples.length);
    const names = new Set(spanFrames.flatMap((frame) => [...frame.keys()]));
    result.spans = Object.fromEntries(
      [...names].map((name) => [name, summary(spanFrames.map((frame) => frame.get(name) ?? 0))]),
    );
    if (raw)
      result.samples = samples.map((sample, index) => ({
        spans: Object.fromEntries([...(spanFrames[index] ?? new Map())].map(([name, ms]) => [name, round2(ms)])),
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
