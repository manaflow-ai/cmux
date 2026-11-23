// Debug-only performance measurement for the agent pane, driven by the
// DEBUG `debug.agent_pane` socket method through `window.cmuxAcpmuxDebug`.
// Everything here is inert until the first debug call sets `acpmuxPerf.enabled`:
// the render path then pays one boolean check per render.

import { type KeyPresentation, KeyPresentationMarks } from "./keyPresentation";

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
export function summary(values: number[]): { p50_ms: number; p95_ms: number; p99_ms: number; max_ms: number } {
  const sorted = [...values].sort((a, b) => a - b);
  return {
    p50_ms: round2(percentile(sorted, 0.5)),
    p95_ms: round2(percentile(sorted, 0.95)),
    // The tail the under-load harnesses report beside p95 (cmuxterm-hq docs/design/chat-instant-under-load.md,
    // "The bench": "key to frame p50, p95, p99 and max").
    p99_ms: round2(percentile(sorted, 0.99)),
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
    const out: {
      interval: number;
      layout: number;
      react: number;
      other: number;
      blank: boolean;
    }[] = [];
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

/// One key, ms from its keydown event's time: `listener` when the page's first keydown listener ran (the
/// wait for the key to reach the page: the app, its web view and the page's main thread), `work` when the
/// key's edit and its render were done (a task queued from its `input` event, after the microtasks
/// ProseMirror and React run it in), `frame` the next frame's start and `paint` after that frame.
/// `submitted` when Chromium presented the frame that draws it, `submittedFloor` the earliest that can
/// be under Chromium's 4 ms rounding (keyPresentation.ts).
export type TypingSample = {
  frame: number;
  paint: number;
  listener?: number;
  work?: number;
  key?: string;
  /** Same-host epoch clock, for joining the native bench's dispatch to this after-frame callback. */
  paint_epoch_ms?: number;
  /** Shared rAF timestamp identifies keys delivered in the same display-frame callback batch. */
  frame_timestamp_ms?: number;
  /** The prompt's length in characters once the key painted (a key into a 5,000-character draft is its own row). */
  chars?: number;
  /** The key's frame to the frame after it (one more rAF, then none): a long one is a frame the key's work dropped. */
  next_frame_ms?: number;
} & Partial<KeyPresentation>;

/// The display's frame interval as the keys' own frames show it: the fastest tenth of `next_frame_ms`
/// (a frame is never shorter than the refresh; under load most are longer), never longer than a 60 Hz frame: under
/// CPU load even the fastest tenth stretch, and counting against a stretched interval would hide the frames it dropped.
export function typingFrameInterval(samples: readonly TypingSample[]): number {
  const intervals = samples.flatMap((sample) =>
    sample.next_frame_ms !== undefined && sample.next_frame_ms > 1 ? [sample.next_frame_ms] : [],
  );
  if (!intervals.length) return 1000 / 60;
  return Math.min(
    1000 / 60,
    percentile(
      intervals.sort((a, b) => a - b),
      0.1,
    ),
  );
}

/// Frames one key dropped against `nominal`: each vsync that passed between the keydown and the frame that
/// began drawing it (`frame`), and each the key's own frame ran over (`next_frame_ms`).
export function keyDroppedFrames(sample: TypingSample, nominal: number): number {
  if (!(nominal > 0)) return 0;
  const waited = Math.max(0, Math.floor(sample.frame / nominal));
  const ranOver = sample.next_frame_ms === undefined ? 0 : Math.max(0, Math.round(sample.next_frame_ms / nominal) - 1);
  return waited + ranOver;
}
/// `promptSent`: the first prompt the page sent since its handshake (direct.ts, as `session/prompt` goes out).
export type AgentMark =
  | "handshakeStart"
  | "handshakeReady"
  | "composerReady"
  | "snapshotPaint"
  | "promptSent"
  | "firstToken";
/**
 * The page's connect path on the wall clock (`Date.now()`), the first time of each since the page
 * loaded: the relaunch-reconnect bench lines them up with the app's launch marks
 * (scripts/cmux-next/bench_relaunch_reconnect.py). `handshakeStart` is the first ask (a retry
 * keeps it), `connectStart` and `connected` bracket the client's connect (transport open,
 * `initialize`, the first read), `firstEvent` is the first event of the shown chat to arrive, and
 * `liveEvent` the first that arrives within LIVE_EVENT_LAG_MS of when acpmux recorded it: the chat
 * is live, past any backlog. `painted` is the page's first `pane.painted` (it shows what it is) and
 * `transcriptMount` the transcript root's first mount: the perf watch's page-load span (perfReporter.ts).
 */
export type LaunchMark =
  | "handshakeStart"
  | "handshakeReady"
  | "connectStart"
  | "connected"
  | "firstEvent"
  | "liveEvent"
  | "painted"
  | "transcriptMount";
/** An event that arrives this soon after acpmux recorded it is live, not backlog. */
export const LIVE_EVENT_LAG_MS = 1000;

/** Typing latency: keydown event time to the next frame and to after that frame paints. */
export function typingSummary(samples: TypingSample[]) {
  const stages = (values: number[]) => ({
    ...summary(values),
    p99_ms: round2(
      percentile(
        [...values].sort((a, b) => a - b),
        0.99,
      ),
    ),
  });
  const nominal = typingFrameInterval(samples);
  const dropped = samples.map((sample) => keyDroppedFrames(sample, nominal));
  return {
    keys: samples.length,
    to_frame: stages(samples.map((sample) => sample.frame)),
    to_paint: stages(samples.map((sample) => sample.paint)),
    to_submitted: stages(samples.flatMap((sample) => (sample.submitted === undefined ? [] : [sample.submitted]))),
    to_submitted_floor: stages(
      samples.flatMap((sample) => (sample.submittedFloor === undefined ? [] : [sample.submittedFloor])),
    ),
    submitted_keys: samples.filter((sample) => sample.submitted !== undefined).length,
    to_listener: stages(samples.flatMap((sample) => (sample.listener === undefined ? [] : [sample.listener]))),
    to_work: stages(samples.flatMap((sample) => (sample.work === undefined ? [] : [sample.work]))),
    frame_interval_ms: round2(nominal),
    dropped_frames: dropped.reduce((total, frames) => total + frames, 0),
    keys_with_drops: dropped.filter((frames) => frames > 0).length,
    max_chars: samples.reduce((most, sample) => Math.max(most, sample.chars ?? 0), 0),
    samples: samples.map((sample) => ({ ...sample })),
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
  /** Typing samples pushed since the page loaded (`typing` keeps the newest 4,096): the perf watch reads past its last count. */
  typingPushed = 0;
  private agentMarks: Partial<Record<AgentMark, number>> = {};
  /// A new chat's start state as its frames show it (the New Tab chip's folder, the hero's project
  /// and its Do not work in a project check): the first one drawn, and when it last changed.
  private startState: { shown: string; first: number; final: number; changes: number } | undefined;
  private launchMarks: Partial<Record<LaunchMark, number>> = {};
  private handshakeAttempts = 0;
  private keyListener: ((event: KeyboardEvent) => void) | undefined;
  private keyTarget: Pick<Document, "addEventListener" | "removeEventListener"> | undefined;
  /// Told each agent mark as it is kept (the perf watch's new-chat span, perfReporter.ts); unset while it is off.
  markListener: ((stage: AgentMark, at: number) => void) | undefined;

  /** The typing samples pushed after the first `count` (`typingPushed`) that `typing` still holds, oldest first. */
  typingAfter(count: number): TypingSample[] {
    const fresh = Math.min(this.typing.length, Math.max(0, this.typingPushed - count));
    return fresh ? this.typing.slice(this.typing.length - fresh) : [];
  }

  /** Turns measurement on; installs the composer key listener once (the chat's and New Tab's). */
  enable(
    target: Pick<Document, "addEventListener" | "removeEventListener"> | undefined = typeof document === "undefined"
      ? undefined
      : document,
  ): void {
    this.enabled = true;
    if (this.keyListener || !target) return;
    const page = target;
    // The frame-presented mark needs a real document (tests pass a bare event target).
    const presented =
      typeof Document !== "undefined" && target instanceof Document ? new KeyPresentationMarks(target) : undefined;
    this.keyListener = (event) => {
      const element = event.target as Element | null;
      // The chat's composer and the New Tab page's (its omnibar's keys, Lawrence 2026-11-13).
      if (!element?.closest?.(".acpmux-composer, .nt-composer")) return;
      const start = event.timeStamp;
      const sample: TypingSample = {
        frame: 0,
        paint: 0,
        listener: performance.now() - start,
        key: event.key,
      };
      presented?.mark(start, (presentation) => Object.assign(sample, presentation));
      // The key's edit: its `input` event, then the microtasks the field and React run it in.
      const input = () => {
        const done = new MessageChannel();
        done.port1.onmessage = () => {
          sample.work ??= performance.now() - start;
          done.port1.close();
        };
        done.port2.postMessage(0);
      };
      page.addEventListener("input", input, { capture: true, once: true });
      requestAnimationFrame((timestamp) => {
        const frame = performance.now();
        sample.frame_timestamp_ms = timestamp;
        page.removeEventListener("input", input, { capture: true });
        const channel = new MessageChannel();
        channel.port1.onmessage = () => {
          sample.frame = frame - start;
          const painted = performance.now();
          sample.paint = painted - start;
          sample.paint_epoch_ms = performance.timeOrigin + painted;
          // Read after the paint mark, so the read is not in the key's time.
          const field = element.closest?.('[contenteditable="true"], textarea, input') ?? element;
          const value = (field as { value?: unknown }).value;
          sample.chars = typeof value === "string" ? value.length : (field.textContent?.length ?? 0);
          this.typing.push(sample);
          this.typingPushed += 1;
          if (this.typing.length > 4096) this.typing.shift();
          channel.port1.close();
          // One more frame, then none: whether the key's own frame ran long.
          requestAnimationFrame((next) => {
            sample.next_frame_ms = next - timestamp;
          });
        };
        channel.port2.postMessage(0);
      });
    };
    this.keyTarget = target;
    target.addEventListener("keydown", this.keyListener as EventListener, true);
  }

  /** Turns measurement off and removes the composer key listener (the perf watch turned off). */
  disable(): void {
    this.enabled = false;
    if (this.keyListener && this.keyTarget)
      this.keyTarget.removeEventListener("keydown", this.keyListener as EventListener, true);
    this.keyListener = undefined;
    this.keyTarget = undefined;
  }

  /** Lifecycle marks used by the warm-chat before/after capture. */
  markAgent(stage: AgentMark): void {
    if (stage === "handshakeStart") {
      delete this.agentMarks.handshakeReady;
      delete this.agentMarks.composerReady;
      delete this.agentMarks.promptSent;
      delete this.agentMarks.firstToken;
    }
    if ((stage === "firstToken" || stage === "promptSent") && this.agentMarks[stage] !== undefined) return;
    const at = performance.now();
    this.agentMarks[stage] = at;
    this.markListener?.(stage, at);
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

  /** The agent marks since the last handshake, on `performance.now()`'s clock. */
  agentMarkTimes(): Partial<Record<AgentMark, number>> {
    return { ...this.agentMarks };
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

  /// Rows unmounted in the commit now running: a row mounted again in the same commit was remounted
  /// in place (its key or its type changed), which redraws it from nothing.
  private unmountedNow = new Set<string>();

  /** A transcript row mounted (`mount:<id>`); one unmounted in this same commit counts `remount:<id>`. */
  rowMounted(id: string): void {
    if (!this.enabled) return;
    this.render(`mount:${id}`);
    if (this.unmountedNow.has(id)) this.render(`remount:${id}`);
  }

  /** A transcript row unmounted; the set clears once the commit's synchronous work ends. */
  rowUnmounted(id: string): void {
    if (!this.enabled) return;
    if (this.unmountedNow.size === 0) queueMicrotask(() => this.unmountedNow.clear());
    this.unmountedNow.add(id);
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
