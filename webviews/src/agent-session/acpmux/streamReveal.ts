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
// for 600 ms) the rest drains in 180 ms, or longer for a backlog that would need more than twice the
// arrival rate (at most 350 ms, the longest lag): the reply's last lines never sprint when a tool call
// ends its stream (Leo, 2026-11-21: "sometimes animations sprint for no reason"). A delta that lands
// after a stall drains the same way, at no more than twice the rate the stream last flowed at (up to
// 900 ms), instead of through the lag correction, which drew it at 3-6x. Pure: the caller
// ticks it with display-frame times.

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
  // motion-allow: the text reveal's finish pace, not a motion step
  static readonly finishMs = 180;
  /// The most a finish drains over the arrival rate: a larger backlog takes longer, up to maxLagMs.
  static readonly finishSpeedup = 2;
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
  /// The arrival rate while the stream last flowed: a stall empties the rate window, so a delta
  /// that lands after one is paced against what the reader last followed, not against ~0.
  private flowRate = 0;
  /// A delta landed after a stall: its backlog drains like a finish (at most twice the flow rate,
  /// within the longest lag) instead of through the lag correction, which sprinted it at 3-6x
  /// (design/chat-animation-ordering-map.md O4).
  private resumed = false;
  private reduceMotion: boolean;

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

  /// A completed reply was replaced by a historical/page snapshot. The replacement is already
  /// visible content, so it must not be paced as if it had just streamed in.
  replace(text: string): void {
    this.shown = text.length;
    this.received = text.length;
    this.lastFrame = undefined;
    this.lastArrival = undefined;
    this.arrivals = [];
    this.gaps = [];
    this.drainUntil = undefined;
    this.flowRate = 0;
    this.resumed = false;
  }

  /// Reduce Motion changed while the row is mounted: on, all of `text` (the latest, which may not
  /// have reached `advance` yet) shows now and later text shows as it arrives; off, only text after
  /// it is paced.
  setReduceMotion(on: boolean, text: string): void {
    this.reduceMotion = on;
    if (!on) return;
    this.received = Math.max(this.received, text.length);
    this.flush();
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
      this.resumed = false;
      return text.length;
    }
    if (elapsed > 0)
      this.shown = Math.min(text.length, this.shown + (this.charsPerSecond(time, elapsed, done) * elapsed) / 1000);
    return StreamReveal.cut(text, Math.floor(this.shown));
  }

  private arrived(time: number, chars: number): void {
    if (this.lastArrival !== undefined && time - this.lastArrival > StreamReveal.stallMs) {
      // The stream resumes after a stall: a fresh deadline for the new backlog. The gap itself is
      // not a gap between deltas, so it does not stretch the lag.
      this.resumed = true;
      this.drainUntil = undefined;
      this.lastArrival = time;
      this.arrivals.push([time, chars]);
      return;
    }
    if (this.resumed) this.drainUntil = undefined;
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
    const stalled = this.resumed || this.lastArrival === undefined || time - this.lastArrival > StreamReveal.stallMs;
    // Sampled on arrival frames only: the quiet frames before a stall registers decay the rate.
    if (!stalled && !done && time === this.lastArrival) this.flowRate = rate;
    const paced = Math.max(rate, this.flowRate);
    // Draining (the end, a stall, a backlog too big) moves linearly to a deadline set when it
    // starts, so it finishes on time instead of slowing down as the backlog shrinks.
    const drain =
      done || stalled
        ? Math.min(
            // The stream resumed and is still going: the backlog may trail longer (up to the
            // catch-up bound) rather than sprint; at the end it never trails past the longest lag.
            this.resumed && !done ? StreamReveal.maxBacklogMs : StreamReveal.maxLagMs,
            Math.max(StreamReveal.finishMs, (backlog / (paced * StreamReveal.finishSpeedup)) * 1000),
          )
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

/// Han, kana, Hangul and full-width punctuation: scripts that write no spaces between words.
const CJK = /[\u3000-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff\uff00-\uffef]/;

/// A word longer than this (a URL, a hash) shows as it arrives instead of waiting for its end.
export const LONG_WORD_CHARS = 48;

/// Where a streaming reply's visible text may end: at the end of a whole word, never inside one
/// and never inside the last word while more may still arrive (it can still grow), so text grows a
/// word at a time and nothing trails the last word. `raw` is the reveal's length; `shown` what
/// already shows (the result never shrinks it); `done` once the stream ended, when all of it shows.
export function wordEdge(text: string, raw: number, done: boolean, shown: number): number {
  const limit = Math.min(raw, text.length);
  if (done && limit >= text.length) return text.length;
  let end = limit;
  // The word ending at `end` is whole when what follows it has arrived and is a space. Chinese,
  // Japanese and Korean put no spaces between words: each of their characters is whole.
  const whole = (at: number) =>
    (at < text.length && /\s/.test(text[at]!) && !/\s/.test(text[at - 1]!)) ||
    CJK.test(text[at - 1]!) ||
    (at < text.length && CJK.test(text[at]!));
  // Measured from the word's start, not from what shows: once part of a long word shows, the
  // rest grows as it arrives. Past LONG_WORD_CHARS the answer is known, so a run with no space in
  // it (a data URL, a minified line) costs at most that many steps a frame.
  while (end > 0 && limit - end <= LONG_WORD_CHARS && !whole(end)) end -= 1;
  if (limit - end > LONG_WORD_CHARS) return limit;
  return Math.max(end, Math.min(shown, text.length));
}
