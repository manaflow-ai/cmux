// The chat's minimal motion under load (Leo, 2026-11-09: "i wonder if we can do a thing where like at
// really high loads if it knows it can't performantly perform the animation... it just goes into
// minimal ish mode? and just does things as fast as it can/some sort of fallback ish thing").
//
// While the chat is busy (a commit of its rows, the reader's input, a send: `poke`), each display
// frame's gap is read. When the frames of the last second missed MISSED_ENTER_MS of their budget in
// all (each gap's time past two frames, spread over SUSTAINED_MS of it), or a long task the engine reports (Chromium's `longtask`)
// held the main thread that long, the page is marked `data-chat-motion="minimal"`: every chat motion
// token goes to 0 (composerStates.css MINIMAL-MOTION), and every gate that reads them or the web
// motion gate (`motionMode`, ui/motion/motionMode.ts) moves nothing: rows land in place in the frame
// they come, nothing slides or settles, and no glide moves the view after the frame that moved it.
// Once the frames have held their budget for HEALTHY_FOR the mark goes, and the chat moves again: the
// hysteresis keeps a frame's motion from turning the mode back on and off.
//
// Cost: one frame callback while the chat is busy, none while it is idle (IDLE_FRAMES after the last
// poke the loop stops), and O(frames in a second) per frame at most. Stop condition: `dispose` ends
// the loop and the observer and takes the mark away; a hidden page counts no gap (it draws none).

/// The mark on the page (or on any element over the chat, as the gallery's variants set it).
export const CHAT_MOTION_ATTR = "data-chat-motion";
export const MINIMAL_MOTION = "minimal";

/// A display frame at 60 Hz, the slowest display the chat draws on (ms).
const FRAME = 1000 / 60;
/// What the frames may miss over WINDOW (ms, each gap's time past two frames, summed) before the
/// chat goes minimal: about seven dropped frames in a second.
export const MISSED_ENTER_MS = 120;
/// The misses must spread over at least this much of the window (ms, first to last): load the chat
/// keeps meeting, not one burst. A single long task (a long chat's first draw, a page of history)
/// misses its frames once and the chat after it draws in budget; it leaves the motion on.
export const SUSTAINED_MS = 250;
/// The span the frames are read over (ms).
export const WINDOW = 1000;
/// How long the frames hold their budget (no gap past two frames) before the chat moves again (ms).
export const HEALTHY_FOR = 2000;
/// With no poke for this many frames (1.5 s at 60 Hz) the loop stops: an idle chat runs no frame
/// callback. Counted in frames, not time, so a page whose clock stands still (a test's) ends it too.
export const IDLE_FRAMES = 90;
/// Still minimal with no poke: at most this many frames more, healthy or not.
const MINIMAL_FRAMES = 600;
/// A gap past this is the page coming back from hidden or a machine asleep, not a busy frame (ms).
const AWAY_GAP = 5000;

export type FrameBudget = {
  /// The chat is doing work: read its frames for IDLE_FRAMES more.
  poke(): void;
  /// Whether the chat is in its minimal motion now.
  readonly minimal: boolean;
  /// Ends the loop and the observer, and takes the mark away.
  dispose(): void;
};

type Clock = {
  now(): number;
  frame(callback: (time: number) => void): number;
  cancel(handle: number): void;
};

/// The gaps' budget over the window: the decision, separate from the clock so it can be tested.
export class FrameBudgetState {
  minimal = false;
  /// Each missed span (end time, ms missed), oldest first.
  private missed: { at: number; ms: number }[] = [];
  private healthySince: number | undefined;

  /// A frame `gap` ms after the last one, at `now`. Returns whether the mode changed.
  frame(gap: number, now: number): boolean {
    if (!(gap > 0) || gap >= AWAY_GAP) return false;
    const over = gap - 2 * FRAME;
    if (over > 0) this.miss(over, now);
    else this.healthySince ??= now;
    return this.decide(now);
  }

  /// The main thread was held `ms` past the engine's long-task bound at `now` (a long task).
  busy(ms: number, now: number): boolean {
    if (ms > 0) this.miss(ms, now);
    return this.decide(now);
  }

  private miss(ms: number, now: number): void {
    this.missed.push({ at: now, ms });
    this.healthySince = undefined;
  }

  private decide(now: number): boolean {
    while (this.missed.length && this.missed[0]!.at < now - WINDOW) this.missed.shift();
    const missed = this.missed.reduce((sum, span) => sum + span.ms, 0);
    const spread = this.missed.length ? this.missed.at(-1)!.at - this.missed[0]!.at : 0;
    if (!this.minimal && missed >= MISSED_ENTER_MS && spread >= SUSTAINED_MS) {
      this.minimal = true;
      this.healthySince = undefined;
      return true;
    }
    if (this.minimal && this.healthySince !== undefined && now - this.healthySince >= HEALTHY_FOR) {
      this.minimal = false;
      this.missed = [];
      return true;
    }
    return false;
  }
}

const shared = new WeakMap<Document, { budget: FrameBudget; users: number }>();

/// The chat's frame budget on `doc`, one per page however many transcripts it draws; each caller
/// disposes its own use, and the last one ends it.
export function shareFrameBudget(doc: Document): FrameBudget {
  const known = shared.get(doc);
  if (known) {
    known.users += 1;
    return releasing(doc, known);
  }
  const entry = { budget: createFrameBudget(doc), users: 1 };
  shared.set(doc, entry);
  return releasing(doc, entry);
}

function releasing(doc: Document, entry: { budget: FrameBudget; users: number }): FrameBudget {
  let released = false;
  return {
    poke: () => entry.budget.poke(),
    get minimal() {
      return entry.budget.minimal;
    },
    dispose() {
      if (released) return;
      released = true;
      entry.users -= 1;
      if (entry.users > 0) return;
      entry.budget.dispose();
      shared.delete(doc);
    },
  };
}

export function createFrameBudget(doc: Document, clock?: Clock): FrameBudget {
  const view = doc.defaultView;
  const time: Clock = clock ?? {
    now: () => view?.performance?.now() ?? Date.now(),
    frame: (callback) =>
      typeof view?.requestAnimationFrame === "function" ? view.requestAnimationFrame(callback) : -1,
    cancel: (handle) => {
      if (handle >= 0 && typeof view?.cancelAnimationFrame === "function") view.cancelAnimationFrame(handle);
    },
  };
  const state = new FrameBudgetState();
  let handle: number | undefined;
  let last: number | undefined;
  let left = 0;
  let disposed = false;
  const apply = () => {
    const root = doc.documentElement;
    if (state.minimal) root.setAttribute(CHAT_MOTION_ATTR, MINIMAL_MOTION);
    else if (root.getAttribute(CHAT_MOTION_ATTR) === MINIMAL_MOTION) root.removeAttribute(CHAT_MOTION_ATTR);
  };
  const tick = (at: number) => {
    handle = undefined;
    if (disposed) return;
    const now = time.now();
    if (doc.visibilityState === "hidden") last = undefined;
    else if (last !== undefined && state.frame(at - last, now)) apply();
    last = doc.visibilityState === "hidden" ? undefined : at;
    // Idle and moving: stop reading. Still minimal: read on until the frames are healthy again.
    left -= 1;
    if (left > 0 || (state.minimal && left > IDLE_FRAMES - MINIMAL_FRAMES)) handle = time.frame(tick);
    else last = undefined;
  };
  // Long tasks where the engine reports them (Chromium); WebKit has none, and the frames tell.
  let observer: PerformanceObserver | undefined;
  try {
    const Observer = (view as (Window & typeof globalThis) | null)?.PerformanceObserver;
    if (Observer?.supportedEntryTypes?.includes("longtask")) {
      observer = new Observer((list) => {
        if (left <= 0) return;
        let changed = false;
        for (const entry of list.getEntries()) changed = state.busy(entry.duration - 50, time.now()) || changed;
        if (changed) apply();
      });
      observer.observe({ type: "longtask", buffered: false });
    }
  } catch {
    observer = undefined;
  }
  return {
    get minimal() {
      return state.minimal;
    },
    poke() {
      if (disposed) return;
      left = IDLE_FRAMES;
      if (handle === undefined) {
        const next = time.frame(tick);
        if (next >= 0) handle = next;
      }
    },
    dispose() {
      disposed = true;
      if (handle !== undefined) time.cancel(handle);
      handle = undefined;
      observer?.disconnect();
      state.minimal = false;
      apply();
    },
  };
}

/// Whether `node`'s chat is in its minimal motion (the page's mark or one over it).
export function minimalMotion(node: Element | null | undefined): boolean {
  return Boolean(node?.closest(`[${CHAT_MOTION_ATTR}="${MINIMAL_MOTION}"]`));
}
