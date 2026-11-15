/**
 * Chooses an agent pane's rendering rate from settled transcript scrolls.
 * Display information and WebKit preference changes remain native; this
 * policy owns only the pure state and thresholds.
 *
 * The rate drops to the capped rate (near 60 fps) only when the full rate
 * already draws no more frames than the cap would: the scroll's mean frame
 * interval is at least `overloaded` of the capped interval. A page that misses
 * some 120 Hz slots still draws more frames at full rate than at 60: with a
 * share `s` of frames taking two slots it draws 120 / (1 + s) fps, 100 fps at
 * s = 0.2, where the cap draws 60. The old rule dropped at s = 0.2 and held
 * the cap for 10 s, doubling to 160 s, so one heavy scroll left every later
 * send and arrival at 60 fps (Leo, 2026-11-11: "It doesn't move at 120 hertz.
 * That's our problem.").
 *
 * A scroll that a send or an arrival drove (the send's ride, the follow) is not
 * a reader's scroll and never drops the rate: its frames are the motion the
 * rate exists for (`sent`).
 */
export class AdaptiveRenderRate {
  static readonly minimumFrames = 30;
  static readonly lateFactor = 1.5;
  /// Drop when the mean interval at full rate is at least this share of the capped interval: the
  /// full rate then draws under 1 / 0.9 of the cap's frames (about 67 fps on a 120 Hz display).
  static readonly overloaded = 0.9;
  static readonly recovered = 0.05;
  static readonly firstBackoff = 10_000;
  static readonly maximumBackoff = 40_000;
  /// How long after a send its scroll reports stay the send's (ms): its ride, the reply's first rows and
  /// ScrollPacing's settle.
  static readonly sendWindow = 1_500;

  private fullRate = true;
  private backoff = AdaptiveRenderRate.firstBackoff;
  private changedAt: number | undefined;
  private sentAt: number | undefined;

  get isFullRate(): boolean {
    return this.fullRate;
  }

  /// The reader sent a prompt at `now`: the motion that follows is the send's.
  sent(now: number): void {
    this.sentAt = now;
  }

  /// Returns a changed decision, or undefined when the current rate stays.
  record(intervals: number[], displayInterval: number, now: number): boolean | undefined {
    const capped = AdaptiveRenderRate.cappedInterval(displayInterval);
    if (intervals.length < AdaptiveRenderRate.minimumFrames || capped <= displayInterval) return undefined;
    const elapsed = this.changedAt === undefined ? Number.POSITIVE_INFINITY : now - this.changedAt;
    if (this.fullRate) {
      const span = intervals.reduce((sum, interval) => sum + interval, 0);
      const sendDriven = this.sentAt !== undefined && now - this.sentAt <= span + AdaptiveRenderRate.sendWindow;
      if (!sendDriven && span / intervals.length >= capped * AdaptiveRenderRate.overloaded) {
        this.backoff =
          elapsed < this.backoff
            ? Math.min(this.backoff * 2, AdaptiveRenderRate.maximumBackoff)
            : AdaptiveRenderRate.firstBackoff;
        this.fullRate = false;
        this.changedAt = now;
        return false;
      }
    } else if (
      elapsed >= this.backoff &&
      AdaptiveRenderRate.lateShare(intervals, capped) <= AdaptiveRenderRate.recovered
    ) {
      this.fullRate = true;
      this.changedAt = now;
      return true;
    }
    return undefined;
  }

  static cappedInterval(displayInterval: number): number {
    if (displayInterval <= 0) return 0;
    return displayInterval * Math.max(1, Math.floor((1000 / 60 + 0.01) / displayInterval + 1e-9));
  }

  private static lateShare(intervals: number[], expected: number): number {
    return (
      intervals.filter((interval) => interval > expected * AdaptiveRenderRate.lateFactor).length / intervals.length
    );
  }
}

export type FramePacingSettings = { adaptive: boolean; displayInterval: number };

/** Bridges one settled scroll through the existing native pane bridge. */
export async function reportScrollPacing(
  intervals: number[],
  callNative: <T>(method: string, params?: Record<string, unknown>) => Promise<T>,
  policy: AdaptiveRenderRate,
  now: () => number = () => performance.now(),
): Promise<void> {
  try {
    const settings = await callNative<FramePacingSettings>("pane.framePacing", { intervals });
    if (!settings.adaptive || settings.displayInterval <= 0) return;
    const decision = policy.record(intervals, settings.displayInterval, now());
    if (decision !== undefined) await callNative("pane.renderRate", { full: decision });
  } catch {
    // A closed/reloading pane has no reason to retain a pending pacing report.
  }
}
