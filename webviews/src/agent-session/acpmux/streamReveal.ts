// How much of a streaming agent message shows on each display frame (plans/cmux-next/acp-streaming.md
// "Pacing"). Deltas arrive in bursts: Claude about 16 characters every 50 ms, Codex runs of tokens
// a few ms apart with 100-500 ms pauses. Drawing each delta as it lands makes text pop in and
// stutter. The reveal instead runs at the arrival rate and trails by a lag that covers a usual gap,
// so it keeps flowing between deltas:
//
//   rate = characters that arrived in the last 600 ms (EWMA 0.9/0.1), at least 40 chars/s
//   lag  = 1.25 x p90 of the last 32 gaps between deltas, 50-350 ms (120 ms until 3 gaps)
//   cps  = rate + (backlog - rate x lag) / 250 ms, at least 40 chars/s
//
// A backlog of more than 900 ms of text drains in 250 ms; once the stream ends (or nothing arrives
// for 600 ms) the rest drains in 180 ms. Pure: the caller ticks it with display-frame times.

export type StreamRevealOptions = {
  /// Text already there when the row mounts (history, or a row scrolled into view mid-stream):
  /// it shows at once; only text after it is revealed.
  initial?: string;
  /// Reduce Motion: everything shows as it arrives.
  reduceMotion?: boolean;
};

const GAP_SAMPLES = 32;

export class StreamReveal {
  static readonly rateWindowMs = 600;
  static readonly gapFactor = 1.25;
  static readonly minLagMs = 50;
  static readonly maxLagMs = 350;
  static readonly correctMs = 250;
  static readonly minCharsPerSecond = 40;
  static readonly maxBacklogMs = 900;
  static readonly catchUpMs = 250;
  static readonly finishMs = 180;
  static readonly stallMs = 600;
  /// A longer gap between frames (a hidden pane, a long task) counts as this long.
  static readonly maxFrameMs = 100;

  /// Characters shown, fractional (floored to draw).
  private shown: number;
  private received: number;
  private lastFrame: number | undefined;
  /// Frame time with long gaps clamped, so a pause does not make the backlog overdue.
  private clock = 0;
  private lastArrival: number | undefined;
  private arrivals: [number, number][] = [];
  private gaps: number[] = [];
  private smoothedRate = 0;
  private drainUntil: number | undefined;
  private readonly reduceMotion: boolean;

  constructor(options: StreamRevealOptions = {}) {
    this.shown = options.initial?.length ?? 0;
    this.received = this.shown;
    this.reduceMotion = options.reduceMotion ?? false;
  }

  /// Whether everything known so far shows.
  get settled(): boolean {
    return Math.floor(this.shown) >= this.received;
  }

  /// Shows everything now (a hidden page, a session switch).
  flush(): void {
    this.shown = this.received;
  }

  /// The visible length of `text` for the frame at `now` (ms); `done` when the stream ended.
  advance(text: string, now: number, done: boolean): number {
    const elapsed =
      this.lastFrame === undefined ? 0 : Math.min(StreamReveal.maxFrameMs, Math.max(0, now - this.lastFrame));
    this.lastFrame = now;
    this.clock += elapsed;
    const time = this.clock;
    if (text.length > this.received) this.arrived(time, text.length - this.received);
    this.received = text.length;
    if (this.reduceMotion || this.shown >= text.length) {
      this.shown = text.length;
      return text.length;
    }
    if (elapsed > 0)
      this.shown = Math.min(text.length, this.shown + (this.charsPerSecond(time, elapsed, done) * elapsed) / 1000);
    return StreamReveal.cut(text, Math.floor(this.shown));
  }

  private arrived(time: number, chars: number): void {
    if (this.lastArrival !== undefined) {
      this.gaps.push(time - this.lastArrival);
      if (this.gaps.length > GAP_SAMPLES) this.gaps.shift();
    }
    this.lastArrival = time;
    this.arrivals.push([time, chars]);
  }

  /// The lag the reveal aims for, from the recent gaps between deltas.
  private lagMs(): number {
    if (this.gaps.length < 3) return 120;
    const sorted = [...this.gaps].sort((a, b) => a - b);
    const p90 = sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * 0.9))]!;
    return Math.min(StreamReveal.maxLagMs, Math.max(StreamReveal.minLagMs, p90 * StreamReveal.gapFactor));
  }

  private rate(time: number): number {
    while (this.arrivals.length && this.arrivals[0]![0] < time - StreamReveal.rateWindowMs) this.arrivals.shift();
    const chars = this.arrivals.reduce((sum, [, count]) => sum + count, 0);
    const instant = (chars / StreamReveal.rateWindowMs) * 1000;
    // Smoothed, so one burst does not double the speed for a frame.
    this.smoothedRate = this.smoothedRate === 0 ? instant : this.smoothedRate * 0.9 + instant * 0.1;
    return Math.max(this.smoothedRate, StreamReveal.minCharsPerSecond);
  }

  private charsPerSecond(time: number, elapsed: number, done: boolean): number {
    const backlog = this.received - this.shown;
    const rate = this.rate(time);
    const stalled = this.lastArrival === undefined || time - this.lastArrival > StreamReveal.stallMs;
    // Draining (the end, a stall, a backlog too big) moves linearly to a deadline set when it
    // starts, so it finishes on time instead of slowing down as the backlog shrinks.
    const drain =
      done || stalled
        ? StreamReveal.finishMs
        : backlog > (rate * StreamReveal.maxBacklogMs) / 1000
          ? StreamReveal.catchUpMs
          : 0;
    if (drain) {
      this.drainUntil ??= time - elapsed + drain;
      const remaining = Math.max(elapsed, this.drainUntil - time + elapsed);
      return Math.max(rate, (backlog / remaining) * 1000);
    }
    this.drainUntil = undefined;
    const target = (rate * this.lagMs()) / 1000;
    return Math.max(StreamReveal.minCharsPerSecond, rate + ((backlog - target) / StreamReveal.correctMs) * 1000);
  }

  /// `end`, moved off the middle of a surrogate pair.
  private static cut(text: string, end: number): number {
    if (end <= 0 || end >= text.length) return Math.max(0, Math.min(end, text.length));
    const code = text.charCodeAt(end - 1);
    return code >= 0xd800 && code <= 0xdbff ? end + 1 : end;
  }
}
