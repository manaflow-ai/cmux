// The transcript's frame guard (VirtualTranscript `armFrameGuard`): while the reader scrolls, the
// scroller's offset is read once more after every frame callback and before the frame paints, so an
// offset a frame callback wrote (a fling's or a drag's step, a wheel's default applied there) is
// committed in the frame that paints it rather than a frame later, when its scroll event comes.
//
// The read runs in a ResizeObserver callback, the one hook after the frame callbacks and before paint:
// each frame a frame callback observes the scroller anew, and a new observation is delivered in that
// frame. It reads scrollTop on a layout the frame has just made, so it forces none. Without a
// ResizeObserver (a test DOM) the read runs in the frame callback itself.
//
// It stops once the offset has stood still `idleMs` (only a move the read reports restarts that clock;
// an arm does too), and at `stop` (the transcript unmounting): no frame is asked for after either.

type Observer = { observe(node: Element): void; unobserve(node: Element): void; disconnect(): void };

export type FrameGuardOptions = {
  /// The read: reports whether the offset moved since the last read (`FrameGuard.moved`).
  read: () => void;
  /// Runs at each of the guard's frames, before it observes (what the last frame left to clear).
  frame?: () => void;
  /// The scroller, or null once it is gone.
  node: () => Element | null;
  idleMs: number;
  now?: () => number;
  requestFrame?: (callback: () => void) => number;
  cancelFrame?: (handle: number) => void;
  /// Makes the observer whose callback runs `read`; undefined: no observer here.
  observer?: (callback: () => void) => Observer | undefined;
};

export class FrameGuard {
  private handle: number | undefined;
  private observer: Observer | undefined;
  private movedAt = Number.NEGATIVE_INFINITY;
  private stopped = false;
  private readonly now: () => number;
  private readonly requestFrame: (callback: () => void) => number;
  private readonly cancelFrame: (handle: number) => void;

  constructor(private options: FrameGuardOptions) {
    this.now = options.now ?? (() => performance.now());
    this.requestFrame = options.requestFrame ?? ((callback) => requestAnimationFrame(callback));
    this.cancelFrame = options.cancelFrame ?? ((handle) => cancelAnimationFrame(handle));
    this.observer = this.makeObserver();
  }

  /// Made at once: ResizeObserver callbacks run in the order their observers were made, and the guard's
  /// read must come before a row measure's commit in the same frame, which places the rows from the
  /// offset it last handled (a guard made after the transcript's row observer read the step a measure
  /// had already put back: a drag's row stood still a frame, then leapt).
  private makeObserver() {
    return this.options.observer?.(() => {
      if (!this.stopped) this.options.read();
    });
  }

  /// The read, frame and node given later than the guard was made (the transcript's, once it mounted):
  /// the observer stays the one made at once.
  connect(hooks: Pick<FrameGuardOptions, "read" | "frame" | "node">): void {
    this.options = { ...this.options, ...hooks };
  }

  /// Frames the guard has asked for and not yet run (0 or 1).
  get pending(): boolean {
    return this.handle !== undefined;
  }

  /// The offset moved (the read saw it): the idle clock starts again.
  moved(): void {
    this.movedAt = this.now();
  }

  /// A scroll or an input that may move the offset: read it this frame and each frame until it is still.
  arm(): void {
    this.stopped = false;
    this.moved();
    this.observer ??= this.makeObserver();
    // This frame too, when it can: an observation made now is delivered before this frame paints.
    if (this.observer) this.watch();
    if (this.handle !== undefined) return;
    this.handle = this.requestFrame(this.tick);
  }

  /// No frame is asked for after this, and the observer lets go of the scroller.
  stop(): void {
    this.stopped = true;
    if (this.handle !== undefined) this.cancelFrame(this.handle);
    this.handle = undefined;
    this.observer?.disconnect();
    this.observer = undefined;
  }

  private readonly tick = () => {
    this.handle = undefined;
    if (this.stopped || !this.options.node()) return;
    this.options.frame?.();
    this.watch();
    if (this.now() - this.movedAt < this.options.idleMs) this.handle = this.requestFrame(this.tick);
  };

  private watch() {
    const node = this.options.node();
    if (!node) return;
    if (!this.observer) {
      this.options.read();
      return;
    }
    this.observer.unobserve(node);
    this.observer.observe(node);
  }
}
