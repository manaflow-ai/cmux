// Frame intervals of settled transcript scrolls, consumed by the page's adaptive rendering policy.

export type PacingClock = {
  requestFrame: (callback: (now: number) => void) => number;
  cancelFrame: (handle: number) => void;
  setTimer: (callback: () => void, ms: number) => unknown;
  clearTimer: (handle: unknown) => void;
};

const browserClock = (): PacingClock => ({
  requestFrame: (callback) => requestAnimationFrame(callback),
  cancelFrame: (handle) => cancelAnimationFrame(handle),
  setTimer: (callback, ms) => setTimeout(callback, ms),
  clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
});

/** Samples frame intervals while the transcript scrolls; once a scroll settles, reports them. */
export class ScrollPacing {
  /** A scroll has settled after this long without a scroll event. */
  static readonly settleMs = 250;
  /** At most this many intervals per report (about 4 s at 160 Hz). */
  static readonly maximumFrames = 640;

  private intervals: number[] = [];
  private lastFrame: number | undefined;
  private frame: number | undefined;
  private settle: unknown;

  constructor(
    private readonly report: (intervals: number[]) => void,
    private readonly clock: PacingClock = browserClock(),
  ) {}

  /** A scroll event: samples frames until the scroll settles. */
  scrolled(): void {
    if (this.frame === undefined) this.frame = this.clock.requestFrame(this.tick);
    if (this.settle !== undefined) this.clock.clearTimer(this.settle);
    this.settle = this.clock.setTimer(this.finish, ScrollPacing.settleMs);
  }

  /** Stops sampling without reporting. */
  stop(): void {
    if (this.frame !== undefined) this.clock.cancelFrame(this.frame);
    if (this.settle !== undefined) this.clock.clearTimer(this.settle);
    this.reset();
  }

  private readonly tick = (now: number) => {
    if (this.lastFrame !== undefined && this.intervals.length < ScrollPacing.maximumFrames)
      this.intervals.push(now - this.lastFrame);
    this.lastFrame = now;
    this.frame = this.clock.requestFrame(this.tick);
  };

  private readonly finish = () => {
    if (this.frame !== undefined) this.clock.cancelFrame(this.frame);
    const intervals = this.intervals;
    this.reset();
    if (intervals.length) this.report(intervals);
  };

  private reset(): void {
    this.intervals = [];
    this.lastFrame = undefined;
    this.frame = undefined;
    this.settle = undefined;
  }
}
