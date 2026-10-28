// Continuous input (pointer moves, wheel, pinch) handled once per display frame, as Chrome's
// renderer does it (third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc):
// IsRafAlignedEvent() holds mouse move, wheel and touch move; DispatchRafAlignedInput() hands them
// over at the frame, coalesced; a discrete event (a press, a release, a key) flushes the queue
// first, so a handler never sees a press before the move that led to it. A stream keeps the latest
// value by default (a pointer position) or merges with its own rule (wheel deltas add up).
//
// The key-to-paint probe at the bottom measures, in the page, how long a key takes to reach the
// screen: the key's timestamp to the next frame plus one task (the frame has painted by then).

/** Requests and cancels display frames: the window's requestAnimationFrame, or a test's. */
export type FrameScheduler = {
  request(callback: (time: number) => void): number;
  cancel(handle: number): void;
};

export function windowFrames(win: Window): FrameScheduler {
  return {
    request: (callback) => win.requestAnimationFrame(callback),
    cancel: (handle) => win.cancelAnimationFrame(handle),
  };
}

/** One coalesced stream of a `FrameInputQueue`: `push` per event, one `deliver` per frame. */
export type FrameInput<T> = {
  /** Holds `value` (merged into the one held) until the frame. */
  push(value: T): void;
  /** Delivers the held value now, if any (a release, the end of a gesture). */
  flush(): void;
  /** Drops the held value. */
  cancel(): void;
  readonly pending: boolean;
};

type Stream = { deliverNow(): void; drop(): void };

/// Discrete events that flush the coalesced moves first (Chrome's ShouldFlushQueue).
const DISCRETE = ["pointerdown", "pointerup", "mousedown", "mouseup", "click", "dblclick", "keydown", "keyup"];

/**
 * The coalesced streams of one window, flushed together by one frame request. A discrete event
 * flushes every stream first, in the order the streams first got a value.
 */
export class FrameInputQueue {
  private readonly held = new Set<Stream>();
  private frame: number | undefined;
  private scheduled = false;

  constructor(private readonly frames: FrameScheduler) {}

  /**
   * A stream delivering at most once per frame. `merge` folds a new value into the held one; by
   * default the newest wins. `deliver` gets the value and how many pushes it stands for.
   */
  stream<T>(deliver: (value: T, coalesced: number) => void, merge: (held: T, next: T) => T = (_held, next) => next) {
    let value: T | undefined;
    let count = 0;
    const stream: Stream = {
      deliverNow: () => {
        if (count === 0) return;
        const delivered = value as T;
        const coalesced = count;
        value = undefined;
        count = 0;
        this.held.delete(stream);
        deliver(delivered, coalesced);
      },
      drop: () => {
        value = undefined;
        count = 0;
        this.held.delete(stream);
      },
    };
    const input: FrameInput<T> = {
      push: (next) => {
        value = count === 0 ? next : merge(value as T, next);
        count += 1;
        this.held.add(stream);
        this.schedule();
      },
      flush: () => stream.deliverNow(),
      cancel: () => stream.drop(),
      get pending() {
        return count > 0;
      },
    };
    return input;
  }

  /** Delivers every held value now, oldest stream first. */
  flush(): void {
    for (const stream of Array.from(this.held)) stream.deliverNow();
    if (this.held.size === 0) this.unschedule();
  }

  private schedule(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    const handle = this.frames.request(this.onFrame);
    // A scheduler that runs the callback at once (a test's) has already cleared `scheduled`.
    if (this.scheduled) this.frame = handle;
  }

  private unschedule(): void {
    if (!this.scheduled) return;
    this.scheduled = false;
    if (this.frame !== undefined) this.frames.cancel(this.frame);
    this.frame = undefined;
  }

  private readonly onFrame = (): void => {
    this.scheduled = false;
    this.frame = undefined;
    this.flush();
  };
}

const queues = new WeakMap<Window, FrameInputQueue>();

/**
 * The window's queue, made on first use with the window's frames; its passive capture listeners
 * flush the held moves before each discrete event reaches any handler.
 */
export function frameInputQueue(win: Window): FrameInputQueue {
  let queue = queues.get(win);
  if (queue) return queue;
  const made = new FrameInputQueue(windowFrames(win));
  queue = made;
  queues.set(win, made);
  for (const type of DISCRETE) win.addEventListener(type, () => made.flush(), { capture: true, passive: true });
  return made;
}

/** A latest-wins (or `merge`d) stream on `win`'s queue: see `FrameInputQueue.stream`. */
export function frameInput<T>(
  win: Window,
  deliver: (value: T, coalesced: number) => void,
  merge?: (held: T, next: T) => T,
): FrameInput<T> {
  return frameInputQueue(win).stream(deliver, merge);
}

// MARK: key-to-paint probe

/// Upper bounds of the histogram's buckets, in ms; one more bucket holds everything above the last.
export const KEY_TO_PAINT_BOUNDS_MS = [2, 4, 8, 12, 16, 20, 25, 33, 50, 75, 100, 150, 250, 500, 1000] as const;
/// The probe posts at most this often.
export const KEY_TO_PAINT_REPORT_MS = 10_000;
/// Keys measured per frame at most; a burst beyond it (a held key repeats far slower) is not measured.
const KEYS_PER_FRAME = 16;

/** What the probe posts: numbers only, never a key or any text. */
export type KeyToPaintReport = {
  kind: "key_to_paint";
  bounds_ms: number[];
  counts: number[];
  count: number;
  sum_ms: number;
  max_ms: number;
  window_ms: number;
};

export type KeyToPaintSeams = {
  /** Where keydown is heard (the document). */
  target: Pick<EventTarget, "addEventListener" | "removeEventListener">;
  frames: FrameScheduler;
  /** Runs `callback` as a task after the current one: after a frame callback, the frame has painted. */
  tick(callback: () => void): void;
  /** The clock of `Event.timeStamp` (performance.now). */
  now(): number;
  post(report: KeyToPaintReport): void;
};

/**
 * Key-to-paint in the page: each keydown's timestamp to the next frame plus one task, into a fixed
 * histogram posted at most once per `KEY_TO_PAINT_REPORT_MS`. Off until `setEnabled(true)` (the host,
 * through `window.cmuxKeyToPaint`): no listener, no frame, no post while off.
 */
export class KeyToPaintProbe {
  private enabled = false;
  private starts: number[] = [];
  private frameAsked = false;
  private counts: number[] = Array.from({ length: KEY_TO_PAINT_BOUNDS_MS.length + 1 }, () => 0);
  private count = 0;
  private sum = 0;
  private max = 0;
  private windowStart = 0;
  // Bumped on every enable and disable: a frame or tick asked for before then records nothing.
  private generation = 0;

  constructor(private readonly seams: KeyToPaintSeams) {}

  get isEnabled(): boolean {
    return this.enabled;
  }

  setEnabled(on: boolean): void {
    if (on === this.enabled) return;
    this.enabled = on;
    this.generation += 1;
    this.reset(this.seams.now());
    this.starts = [];
    this.frameAsked = false;
    if (on) this.seams.target.addEventListener("keydown", this.onKey, { capture: true, passive: true });
    else this.seams.target.removeEventListener("keydown", this.onKey, { capture: true });
  }

  private readonly onKey = (event: Event): void => {
    if (!this.enabled || this.starts.length >= KEYS_PER_FRAME) return;
    this.starts.push(event.timeStamp);
    if (this.frameAsked) return;
    this.frameAsked = true;
    const generation = this.generation;
    this.seams.frames.request(() => {
      if (generation !== this.generation) return;
      // Keys after this frame callback paint in the next frame: they wait for their own.
      const measured = this.starts;
      this.starts = [];
      this.frameAsked = false;
      this.seams.tick(() => {
        if (generation === this.generation) this.record(measured, this.seams.now());
      });
    });
  };

  private record(starts: number[], end: number): void {
    for (const start of starts) {
      const ms = Math.max(0, end - start);
      let bucket = KEY_TO_PAINT_BOUNDS_MS.findIndex((bound) => ms <= bound);
      if (bucket < 0) bucket = KEY_TO_PAINT_BOUNDS_MS.length;
      this.counts[bucket]! += 1;
      this.count += 1;
      this.sum += ms;
      this.max = Math.max(this.max, ms);
    }
    if (this.count > 0 && end - this.windowStart >= KEY_TO_PAINT_REPORT_MS) {
      this.seams.post({
        kind: "key_to_paint",
        bounds_ms: [...KEY_TO_PAINT_BOUNDS_MS],
        counts: [...this.counts],
        count: this.count,
        sum_ms: Math.round(this.sum * 100) / 100,
        max_ms: Math.round(this.max * 100) / 100,
        window_ms: Math.round(end - this.windowStart),
      });
      this.reset(end);
    }
  }

  private reset(now: number): void {
    this.counts.fill(0);
    this.count = 0;
    this.sum = 0;
    this.max = 0;
    this.windowStart = now;
  }
}

/** The probe on `doc`'s window: frames from requestAnimationFrame, the task from a MessageChannel. */
export function keyToPaintProbe(doc: Document, post: (report: KeyToPaintReport) => void): KeyToPaintProbe | null {
  const win = doc.defaultView;
  if (!win) return null;
  // Made at the first measured key: an off probe holds no channel.
  let channel: MessageChannel | undefined;
  const ticks: Array<() => void> = [];
  return new KeyToPaintProbe({
    target: doc,
    frames: windowFrames(win),
    tick: (callback) => {
      if (!channel) {
        channel = new win.MessageChannel();
        channel.port1.onmessage = () => ticks.shift()?.();
      }
      ticks.push(callback);
      channel.port2.postMessage(null);
    },
    now: () => win.performance.now(),
    post,
  });
}

/**
 * The page's switch for the probe, `window.cmuxKeyToPaint`. The host calls it: the agent pane's
 * `AgentPaneView.setKeyToPaintProbe` (CmuxNextAgentPane), which takes each report as `pane.keyToPaint`.
 */
export type KeyToPaintControl = {
  setEnabled(on: boolean): boolean;
};

type ProbeWindow = Window & { cmuxKeyToPaint?: KeyToPaintControl };

/**
 * Makes the probe for `doc` (off) and its switch `window.cmuxKeyToPaint`; each report goes to
 * `post`. `make` builds the probe (tests pass one on fake frames). Idempotent.
 */
export function installKeyToPaintProbe(
  doc: Document,
  post: (report: KeyToPaintReport) => void,
  make: typeof keyToPaintProbe = keyToPaintProbe,
): void {
  const win = doc.defaultView as ProbeWindow | null;
  if (!win || win.cmuxKeyToPaint) return;
  const probe = make(doc, post);
  if (!probe) return;
  win.cmuxKeyToPaint = {
    setEnabled(on) {
      probe.setEnabled(on);
      return probe.isEnabled;
    },
  };
}
