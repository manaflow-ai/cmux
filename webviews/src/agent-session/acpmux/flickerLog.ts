// The page's half of the always-on flicker detector (Swift AgentPageFlickerLog, which writes the
// ring file under the app's state root): so a flash Leo mentions can be matched to its time (Leo,
// 2026-11-04: "it's because of an entire re-render of the thing ... a flicker across nearly the
// full screen"). It records, with the wall-clock time:
//
// - `page-load`: this document loaded (`type`: navigate, reload, back_forward).
// - `visibility`: the document became hidden or visible (WebKit follows the window's occlusion).
// - `transcript-mount`: the transcript's root mounted; `n` over 1 is a remount on this page.
// - `long-frame`: a frame over 100 ms while the page is visible. Cheap: a `long-animation-frame`
//   observer where the engine has one; otherwise frames are timed only while the page changes
//   (a DOM mutation arms a frame watch that stops a second after the last one), never in a loop.
//
// No text of the chat goes out: kinds, numbers and short words. Events are sent in batches at
// most once a second, through the pane's own WebKit handler only (gallery and tests send nothing).

export type FlickerEvent = { kind: string; at: number } & Record<string, string | number | boolean>;
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
    private readonly schedule: (run: () => void, ms: number) => ReturnType<typeof setTimeout> = setTimeout,
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

/// Times frames while `armed` keeps being called; reports each over LONG_FRAME_MS while visible.
export class FrameWatch {
  private last: number | undefined;
  private until = 0;
  private running = false;

  constructor(
    private readonly report: (ms: number) => void,
    private readonly visible: () => boolean,
    private readonly frame: (run: (time: number) => void) => void,
    private readonly now: () => number,
  ) {}

  arm(): void {
    this.until = this.now() + WATCH_MS;
    if (this.running) return;
    this.running = true;
    // From the change itself: a frame that the change made long is the first one timed.
    this.last = this.visible() ? this.now() : undefined;
    this.frame((time) => this.tick(time));
  }

  /// The page was hidden: the next gap spans the hidden time, so it is not a frame.
  reset(): void {
    this.last = undefined;
  }

  private tick(time: number): void {
    const visible = this.visible();
    if (visible && this.last !== undefined && time - this.last > LONG_FRAME_MS) this.report(Math.round(time - this.last));
    this.last = visible ? time : undefined;
    if (this.now() >= this.until) {
      this.running = false;
      return;
    }
    this.frame((next) => this.tick(next));
  }
}

let log: FlickerLog | undefined;

/// The transcript's root mounted (App.tsx VirtualTranscript); nothing before startFlickerLog.
export function noteTranscriptMount(): void {
  log?.transcriptMounted();
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
      for (const entry of list.getEntries())
        if (entry.duration > LONG_FRAME_MS) longFrame(Math.round(entry.duration));
    }).observe({ type: "long-animation-frame", buffered: false });
    return true;
  } catch {
    return false;
  }
}

/// Starts the detector once, in the app's own WebKit pane. A detector that cannot start never
/// stops the pane from mounting.
export function startFlickerLog(win: Window = window): void {
  try {
    install(win);
  } catch {
    // The pane matters more than its flicker record.
  }
}

function install(win: Window): void {
  const handler = win.webkit?.messageHandlers?.agentSession;
  if (log || !handler) return;
  const send: Send = (events) => {
    try {
      void Promise.resolve(
        handler.postMessage({ id: crypto.randomUUID(), method: "diag.flicker", params: { events } }),
      ).catch(() => undefined);
    } catch {
      // A page that lost its handler has nobody to tell.
    }
  };
  const flicker = new FlickerLog(send);
  log = flicker;
  const doc = win.document;
  const navigation = win.performance?.getEntriesByType?.("navigation")[0] as PerformanceNavigationTiming | undefined;
  flicker.record("page-load", { type: navigation?.type ?? "unknown" });

  const longFrame = (ms: number) => flicker.record("long-frame", { ms });
  const types = (globalThis as { PerformanceObserver?: typeof PerformanceObserver }).PerformanceObserver
    ?.supportedEntryTypes;
  let watch: FrameWatch | undefined;
  if (!observeLongFrames(types, doc, longFrame)) {
    watch = new FrameWatch(
      longFrame,
      () => doc.visibilityState === "visible",
      (run) => win.requestAnimationFrame(run),
      () => win.performance.now(),
    );
    const armed = watch;
    new MutationObserver(() => armed.arm()).observe(doc.documentElement, {
      childList: true,
      subtree: true,
      characterData: true,
    });
  }

  doc.addEventListener("visibilitychange", () => {
    flicker.record("visibility", { state: doc.visibilityState });
    watch?.reset();
    if (doc.visibilityState === "visible") watch?.arm();
  });
  win.addEventListener("pagehide", () => flicker.flush());
}
