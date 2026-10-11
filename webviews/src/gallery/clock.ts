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
