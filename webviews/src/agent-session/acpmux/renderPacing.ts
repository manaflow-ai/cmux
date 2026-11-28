/**
 * Chooses an agent pane's rendering rate from settled transcript scrolls.
 * Display information and WebKit preference changes remain native; this
 * policy owns only the pure state and thresholds.
 */
export class AdaptiveRenderRate {
  static readonly minimumFrames = 30;
  static readonly lateFactor = 1.5;
  static readonly overloaded = 0.2;
  static readonly recovered = 0.05;
  static readonly firstBackoff = 10_000;
  static readonly maximumBackoff = 160_000;

  private fullRate = true;
  private backoff = AdaptiveRenderRate.firstBackoff;
  private changedAt: number | undefined;

  get isFullRate(): boolean {
    return this.fullRate;
  }

  /** Returns a changed decision, or undefined when the current rate stays. */
  record(intervals: number[], displayInterval: number, now: number): boolean | undefined {
    const capped = AdaptiveRenderRate.cappedInterval(displayInterval);
    if (intervals.length < AdaptiveRenderRate.minimumFrames || capped <= displayInterval) return undefined;
    const elapsed = this.changedAt === undefined ? Number.POSITIVE_INFINITY : now - this.changedAt;
    if (this.fullRate) {
      if (AdaptiveRenderRate.lateShare(intervals, displayInterval) > AdaptiveRenderRate.overloaded) {
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
