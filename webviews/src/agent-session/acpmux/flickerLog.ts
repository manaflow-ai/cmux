// The page's half of the always-on flicker detector (Swift AgentPageFlickerLog, which writes the
// ring file under the app's state root): so a flash Leo mentions can be matched to its time (Leo,
// 2026-11-04: "it's because of an entire re-render of the thing ... a flicker across nearly the
// full screen"). It records, with the wall-clock time:
//
// - `page-load`: this document loaded (`type`: navigate, reload, back_forward).
// - `visibility`: the document became hidden or visible (WebKit follows the window's occlusion).
// - `transcript-mount`: the transcript's root mounted; `n` over 1 is a remount on this page.
// - `transcript-replace`: the chat on screen drew a frame with none of its rows from before (an
//   empty transcript, or every row built anew), after a reset of it (direct.ts `noteReplace`):
//   `cause` names the reset, `blank` an empty frame, `n` the chat's count on this page.
// - `long-frame`: a frame over 100 ms while the page is visible, from a `long-animation-frame`
//   observer where the engine has one, else from the frame watch below.
// - `frames`: how smoothly the page drew while it changed, at most once a second: `n` frames that
//   followed a DOM change, their intervals' `p50`, `p95` and `max` in ms, `miss120` and `miss60`
//   (intervals that missed a 120 Hz or a 60 Hz frame), `over50`, and `ms` the span covered (Leo,
//   2026-11-07: "find, like, where we're dropping frames"). `cmux perf record` reads them.
//
// Frames are timed only while the page changes: a DOM mutation arms a frame watch that stops a
// second after the last one, never a loop that runs while the page is still.
//
// No text of the chat goes out: kinds, numbers and short words. Events are sent in batches at
// most once a second, fire and forget: on the shared page host as the `cmux.agent.diag.flicker` op
// (AgentPageProvider), else through the app's own WebKit handler. The gallery's stand-in for that
// handler, and tests that hand it no sender, send nothing. Before the page host sent them (Leo's
// NIGHTLY, 2026-11-11), the ring file held no page line at all, only the app's own.

import { postNative } from "./native";

export type FlickerEvent = { kind: string; at: number } & Record<string, string | number | boolean>;
/// Hands one batch to the app; it may return the host's (ignored) answer.
export type FlickerSend = (events: FlickerEvent[]) => unknown;
type Send = (events: FlickerEvent[]) => void;

export const LONG_FRAME_MS = 100;
/// How long after the last DOM change frames are still timed.
const WATCH_MS = 1000;
const FLUSH_MS = 1000;
/// The most events held between flushes; older ones are dropped and counted.
const MAX_HELD = 64;

export class FlickerLog {
  private held: FlickerEvent[] = [];
  private dropped = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private mounts = 0;

  constructor(
    private readonly send: Send,
    private readonly now: () => number = Date.now,
    // Called through a closure: Chromium refuses `setTimeout` called as this object's method.
    private readonly schedule: (run: () => void, ms: number) => ReturnType<typeof setTimeout> = (run, ms) =>
      setTimeout(run, ms),
  ) {}

  record(kind: string, fields: Record<string, string | number | boolean> = {}): void {
    if (this.held.length >= MAX_HELD) {
      this.held.shift();
      this.dropped += 1;
    }
    this.held.push({ ...fields, kind, at: this.now() });
    this.timer ??= this.schedule(() => this.flush(), FLUSH_MS);
  }

  /// The transcript's root mounted: the first is the page's own, any later one a remount.
  transcriptMounted(): void {
    this.mounts += 1;
    this.record("transcript-mount", { n: this.mounts });
  }

  flush(): void {
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
    if (!this.held.length) return;
    const events = this.held;
    if (this.dropped) events[0] = { ...events[0]!, dropped: this.dropped };
    this.held = [];
    this.dropped = 0;
    this.send(events);
  }
}

/// Interval bounds of the `frames` event: a 120 Hz frame is 8.3 ms and a 60 Hz one 16.7 ms, so an
/// interval past one and a half of either is a frame the page missed.
const MISS_120_MS = 12.5;
const MISS_60_MS = 25;
const OVER_MS = 50;
/// The longest span one `frames` event covers.
const WINDOW_MS = 1000;

export type FrameStats = {
  n: number;
  p50: number;
  p95: number;
  max: number;
  miss120: number;
  miss60: number;
  over50: number;
  ms: number;
};

/// The `frames` fields of one window's intervals (ms, any order); nothing for an empty window.
export function frameStats(intervals: readonly number[], span: number): FrameStats | undefined {
  if (!intervals.length) return undefined;
  const sorted = [...intervals].sort((a, b) => a - b);
  const at = (share: number) => sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
  const round = (ms: number) => Math.round(ms * 10) / 10;
  return {
    n: sorted.length,
    p50: round(at(0.5)),
    p95: round(at(0.95)),
    max: round(sorted.at(-1)!),
    miss120: sorted.filter((ms) => ms > MISS_120_MS).length,
    miss60: sorted.filter((ms) => ms > MISS_60_MS).length,
    over50: sorted.filter((ms) => ms > OVER_MS).length,
    ms: Math.round(span),
  };
}

/// Times frames while `arm` keeps being called; reports each over LONG_FRAME_MS while visible,
/// and the intervals of frames that drew a change as one `frames` summary a second at most.
export class FrameWatch {
  private last: number | undefined;
  private until = 0;
  private running = false;
  /// A change came since the last frame: the next frame draws it.
  private pending = false;
  /// The last frame drew a change: the interval after it is that change's cost.
  private drew = false;
  private intervals: number[] = [];
  /// The span of the counted intervals: the first one's start and the newest one's end.
  private windowStart: number | undefined;
  private windowEnd = 0;

  constructor(
    private readonly report: (ms: number) => void,
    private readonly visible: () => boolean,
    private readonly frame: (run: (time: number) => void) => void,
    private readonly now: () => number,
    private readonly summary: (stats: FrameStats) => void = () => undefined,
  ) {}

  arm(): void {
    this.until = this.now() + WATCH_MS;
    this.pending = true;
    if (this.running) return;
    this.running = true;
    // From the change itself: a frame that the change made long is the first one timed.
    this.last = this.visible() ? this.now() : undefined;
    this.drew = false;
    this.frame((time) => this.tick(time));
  }

  /// The page was hidden: the next gap spans the hidden time, so it is not a frame.
  reset(): void {
    this.last = undefined;
    this.drew = false;
    this.endWindow();
  }

  private tick(time: number): void {
    const visible = this.visible();
    if (visible && this.last !== undefined) {
      const ms = time - this.last;
      if (ms > LONG_FRAME_MS) this.report(Math.round(ms));
      // A change is drawn in the frame after it, so its cost is the interval that starts at that
      // frame: one interval per frame that drew a change, however many changes it drew. The first
      // interval runs from the change, not from a frame, so it is no frame's length.
      if (this.drew) {
        this.windowStart ??= this.last;
        this.windowEnd = time;
        this.intervals.push(ms);
        if (time - this.windowStart >= WINDOW_MS) this.endWindow();
      }
    }
    this.drew = visible && this.pending;
    this.pending = false;
    this.last = visible ? time : undefined;
    if (this.now() >= this.until) {
      this.running = false;
      this.endWindow();
      return;
    }
    this.frame((next) => this.tick(next));
  }

  private endWindow(): void {
    const stats = frameStats(this.intervals, this.windowEnd - (this.windowStart ?? this.windowEnd));
    this.intervals = [];
    this.windowStart = undefined;
    if (stats) this.summary(stats);
  }
}

let log: FlickerLog | undefined;

/// The transcript's root mounted (App.tsx VirtualTranscript); nothing before startFlickerLog.
export function noteTranscriptMount(): void {
  log?.transcriptMounted();
}

/// The chat on screen was replaced whole (direct.ts `noteReplace`); nothing before startFlickerLog.
export function noteTranscriptReplace(cause: string, blank: boolean, n: number): void {
  log?.record("transcript-replace", { cause, blank, n });
}

/// Long frames from the engine's `long-animation-frame` entries; false when it has none or refuses
/// the observer (the frame watch takes over).
function observeLongFrames(
  types: readonly string[] | undefined,
  doc: Document,
  longFrame: (ms: number) => void,
): boolean {
  if (!types?.includes("long-animation-frame")) return false;
  try {
    new PerformanceObserver((list) => {
      if (doc.visibilityState !== "visible") return;
      for (const entry of list.getEntries()) if (entry.duration > LONG_FRAME_MS) longFrame(Math.round(entry.duration));
    }).observe({ type: "long-animation-frame", buffered: false });
    return true;
  } catch {
    return false;
  }
}

/// The shared page host's sender: each batch is the `cmux.agent.diag.flicker` op, which the app
/// writes to the ring file and answers at once (AgentPageProvider, before the pane's model).
export function pageHostFlickerSend(post: typeof postNative = postNative): FlickerSend {
  return (events) => post("diag.flicker", { events });
}

/// Starts the detector once: through `send` (the page host's, pageHostFlickerSend) when given, else
/// through the app's own WebKit handler. A detector that cannot start never stops the pane from
/// mounting.
export function startFlickerLog(win: Window = window, send?: FlickerSend): void {
  try {
    install(win, send);
  } catch {
    // The pane matters more than its flicker record.
  }
}

/// Tests: the page starts again with no detector.
export function resetFlickerLogForTests(): void {
  log?.flush();
  log = undefined;
}

/// `send` that never throws and never waits: a batch the app refuses or loses is dropped.
function quiet(send: FlickerSend): Send {
  return (events) => {
    try {
      void Promise.resolve(send(events)).catch(() => undefined);
    } catch {
      // A page that lost its host has nobody to tell.
    }
  };
}

/// The old host's sender: the app's `agentSession` handler; none for the gallery's stand-in
/// (gallery/frame/agentPane.ts) or a page without the handler.
function webKitSend(win: Window): Send | undefined {
  const handler = win.webkit?.messageHandlers?.agentSession;
  if (!handler || (handler as { standIn?: boolean }).standIn) return undefined;
  return quiet((events) =>
    handler.postMessage({ id: crypto.randomUUID(), method: "diag.flicker", params: { events } }),
  );
}

function install(win: Window, pageHostSend: FlickerSend | undefined): void {
  if (log) return;
  const send = pageHostSend ? quiet(pageHostSend) : webKitSend(win);
  if (!send) return;
  const flicker = new FlickerLog(send);
  log = flicker;
  const doc = win.document;
  const navigation = win.performance?.getEntriesByType?.("navigation")[0] as PerformanceNavigationTiming | undefined;
  flicker.record("page-load", { type: navigation?.type ?? "unknown" });

  const longFrame = (ms: number) => flicker.record("long-frame", { ms });
  const types = (globalThis as { PerformanceObserver?: typeof PerformanceObserver }).PerformanceObserver
    ?.supportedEntryTypes;
  // With the engine's long frames, the watch's own would be the same frames twice.
  const engineLongFrames = observeLongFrames(types, doc, longFrame);
  const watch = new FrameWatch(
    engineLongFrames ? () => undefined : longFrame,
    () => doc.visibilityState === "visible",
    (run) => win.requestAnimationFrame(run),
    () => win.performance.now(),
    (stats) => flicker.record("frames", stats),
  );
  new (win as Window & typeof globalThis).MutationObserver(() => watch.arm()).observe(doc.documentElement, {
    childList: true,
    subtree: true,
    characterData: true,
  });

  doc.addEventListener("visibilitychange", () => {
    flicker.record("visibility", { state: doc.visibilityState });
    watch.reset();
    if (doc.visibilityState === "visible") watch.arm();
  });
  win.addEventListener("pagehide", () => flicker.flush());
}
