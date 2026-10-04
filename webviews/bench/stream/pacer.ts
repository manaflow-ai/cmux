// Adaptive reveal pacing for streamed agent text: decouples network bursts from what the reader
// sees. Text arrives in chunks (Claude: ~16 chars every ~50 ms; Codex: bursts); the pacer reveals
// it at a steady character rate that tracks the arrival rate and keeps a small, bounded lag.
//
//   rate   = chars arrived over the last RATE_WINDOW_MS (EWMA-smoothed)
//   lag    = clamp(p90(inter-arrival gap) * GAP_FACTOR, MIN_LAG_MS, MAX_LAG_MS)
//   target = rate * lag                      (chars the display should trail by)
//   cps    = rate + (backlog - target) / CORRECT_MS * 1000
//   cps   >= MIN_CPS while anything is waiting; backlog > rate * MAX_BACKLOG_MS catches up in CATCH_UP_MS
//   after the turn ends (or the stream stalls for STALL_MS), the rest drains within FINISH_MS
//
// Pure: no DOM and no timers. The caller ticks it from requestAnimationFrame with the frame time.

export type PacerOptions = {
  rateWindowMs: number;
  gapFactor: number;
  minLagMs: number;
  maxLagMs: number;
  correctMs: number;
  minCps: number;
  maxBacklogMs: number;
  catchUpMs: number;
  finishMs: number;
  stallMs: number;
};

export const DEFAULT_PACER: PacerOptions = {
  rateWindowMs: 600,
  gapFactor: 1.25,
  minLagMs: 50,
  maxLagMs: 350,
  correctMs: 250,
  minCps: 40,
  maxBacklogMs: 900,
  catchUpMs: 250,
  finishMs: 180,
  stallMs: 600,
};

const GAP_SAMPLES = 32;

export class RevealPacer {
  /** Characters received so far. */
  received = 0;
  /** Characters revealed so far (fractional; floor it to draw). */
  shown = 0;
  private finished = false;
  private arrivals: [number, number][] = [];
  private gaps: number[] = [];
  private lastArrival: number | undefined;
  private lastTick: number | undefined;
  private smoothedRate = 0;

  constructor(private readonly options: PacerOptions = DEFAULT_PACER) {}

  /** `chars` more characters arrived at `now`. */
  arrived(now: number, chars: number): void {
    if (chars <= 0) return;
    if (this.lastArrival !== undefined) {
      this.gaps.push(now - this.lastArrival);
      if (this.gaps.length > GAP_SAMPLES) this.gaps.shift();
    }
    this.lastArrival = now;
    this.arrivals.push([now, chars]);
    this.received += chars;
  }

  /** The stream ended: drain what is left quickly. */
  finish(): void {
    this.finished = true;
  }

  /** Reveal everything now (reduced motion off-screen, a session switch, history). */
  flush(): void {
    this.shown = this.received;
  }

  get backlog(): number {
    return this.received - this.shown;
  }

  /** The lag the pacer aims for, from the recent inter-arrival gaps. */
  targetLagMs(): number {
    const { minLagMs, maxLagMs, gapFactor } = this.options;
    if (this.gaps.length < 3) return Math.min(maxLagMs, Math.max(minLagMs, 120));
    const sorted = [...this.gaps].sort((a, b) => a - b);
    const p90 = sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * 0.9))];
    return Math.min(maxLagMs, Math.max(minLagMs, p90 * gapFactor));
  }

  /** Arrival rate in chars/second over the recent window, smoothed. */
  private rate(now: number): number {
    const window = this.options.rateWindowMs;
    while (this.arrivals.length && this.arrivals[0][0] < now - window) this.arrivals.shift();
    const chars = this.arrivals.reduce((sum, [, count]) => sum + count, 0);
    const instant = (chars / window) * 1000;
    // EWMA so one burst does not double the speed for a frame.
    this.smoothedRate = this.smoothedRate === 0 ? instant : this.smoothedRate * 0.9 + instant * 0.1;
    return this.smoothedRate;
  }

  /** Advances to frame time `now`; returns the characters to show. */
  tick(now: number): number {
    const dt = this.lastTick === undefined ? 1000 / 120 : Math.min(100, now - this.lastTick);
    this.lastTick = now;
    const backlog = this.received - this.shown;
    if (backlog <= 0) return Math.floor(this.shown);
    const o = this.options;
    const rate = Math.max(this.rate(now), o.minCps);
    const stalled = this.lastArrival !== undefined && now - this.lastArrival > o.stallMs;
    let cps: number;
    if (this.finished || stalled) cps = Math.max(rate, (backlog / o.finishMs) * 1000);
    else if (backlog > (rate * o.maxBacklogMs) / 1000) cps = (backlog / o.catchUpMs) * 1000;
    else {
      const target = (rate * this.targetLagMs()) / 1000;
      cps = Math.max(o.minCps, rate + ((backlog - target) / o.correctMs) * 1000);
    }
    this.shown = Math.min(this.received, this.shown + (cps * dt) / 1000);
    return Math.floor(this.shown);
  }
}

/** Moves `count` back off a UTF-16 low surrogate so a reveal never splits a code point. */
export function safeCut(text: string, count: number): number {
  if (count <= 0 || count >= text.length) return Math.max(0, Math.min(count, text.length));
  const code = text.charCodeAt(count);
  return code >= 0xdc00 && code <= 0xdfff ? count - 1 : count;
}

/** Snaps `count` back to the last word boundary (reduced motion reveals whole words). */
export function wordCut(text: string, count: number, full: number): number {
  if (count >= full) return full;
  const space = text.lastIndexOf(" ", count);
  const newline = text.lastIndexOf("\n", count);
  return Math.max(space, newline, 0);
}
