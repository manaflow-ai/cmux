// A fixed clock for stage frames: "now" starts at GALLERY_NOW and runs from there, so relative
// times ("5 min ago", date lines) read the same in every run and screenshot. Fixtures place their
// timestamps relative to GALLERY_NOW. Timers and performance.now() are untouched.

/** 2026-10-06 09:41:00 UTC. */
export const GALLERY_NOW = Date.UTC(2026, 9, 6, 9, 41, 0);

export const minutesAgo = (minutes: number) => GALLERY_NOW - minutes * 60_000;

export function installGalleryClock(start = GALLERY_NOW): void {
  const RealDate = Date;
  const origin = performance.now();
  const now = () => start + Math.round(performance.now() - origin);
  class GalleryDate extends RealDate {
    constructor(...args: unknown[]) {
      if (args.length === 0) super(now());
      else super(...(args as [number, number, number, number, number, number, number]));
    }
    static now(): number {
      return now();
    }
  }
  globalThis.Date = GalleryDate as DateConstructor;
}

/// How long ago a scene's finished work ended, at most, in minutes: a finished line stays in the
/// composer hat only for its grace (subagents/trayLinger.ts TRAY_LINGER_MS, 2 min), so a scene that
/// shows one ends it well inside that, with room for a slow capture.
export const RECENT_END_MINUTES = 0.5;

/// A finished run's start and end: it ran `ran` minutes and ended at most RECENT_END_MINUTES ago, or
/// at `minutes - ran` when that is sooner. Its duration on the line stays `ran`.
export function recentRun(minutes: number, ran: number): { startedAt: number; endedAt: number } {
  const endedAgo = Math.max(0, Math.min(minutes - ran, RECENT_END_MINUTES));
  return { startedAt: minutesAgo(endedAgo + ran), endedAt: minutesAgo(endedAgo) };
}
