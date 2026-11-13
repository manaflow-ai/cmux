// How far above the first loaded row the transcript asks for the next page of older history.
//
// Leo (2026-11-12): "I would probably prefer if things loaded faster. Right now I'm just getting some
// blanks in between loads as I scroll up. Like, it just doesn't catch up to my speed of scrolling
// sometimes."
//
// A fixed distance (OLDER_AHEAD_VIEWPORTS) is a fixed time only at one speed: a reader scrolling up
// faster than that distance per page read reaches the loaded rows' top while the page is still out,
// and stops there with nothing above until it lands. The distance here is also as far as the reader
// goes, at the speed they are scrolling up now, in the time a page has taken to read, twice over (the
// page's own read and the commit that draws it), so the ask starts that much earlier.

/// The time a page is taken to need before one has been read in this chat (ms).
export const OLDER_ASK_GUESS_MS = 400;
/// The distance covers this many reads of a page at the reader's speed.
export const OLDER_AHEAD_MARGIN = 2;
/// The farthest ahead it asks, in viewports: a fling's speed times a slow read stays bounded.
export const OLDER_AHEAD_MAX_VIEWPORTS = 40;
/// Scroll events further apart than this are a new scroll: the speed starts from zero (ms).
const SCROLL_GAP_MS = 150;
/// How much of each new reading the speed and the read time take.
const SMOOTHING = 0.5;

export class OlderAhead {
  /// The reader's upward speed, px/ms; 0 while still or going down.
  private speed = 0;
  private lastTop: number | undefined;
  private lastAt = 0;
  /// How long a page has taken to read, smoothed (ms); undefined before the first.
  private readMs: number | undefined;

  /// A scroll event: `top` is the view's offset among the rows, `now` in ms.
  scrolled(top: number, now: number): void {
    const gap = now - this.lastAt;
    if (this.lastTop === undefined || gap > SCROLL_GAP_MS || gap <= 0) this.speed = 0;
    else {
      // Only a rise counts: a page landing above moves the offset down, as does a scroll down.
      const rise = Math.max(0, this.lastTop - top) / gap;
      this.speed = rise === 0 ? 0 : this.speed + (rise - this.speed) * SMOOTHING;
    }
    this.lastTop = top;
    this.lastAt = now;
  }

  /// A page read that answered took `ms`.
  read(ms: number): void {
    if (!(ms >= 0)) return;
    this.readMs = this.readMs === undefined ? ms : this.readMs + (ms - this.readMs) * SMOOTHING;
  }

  /// How far above the first loaded row (px) an ask starts, never under `floor`.
  ahead(floor: number, viewport: number, now: number): number {
    // A reader who stopped scrolling a while ago is not moving, whatever the last speed read.
    const speed = now - this.lastAt > SCROLL_GAP_MS ? 0 : this.speed;
    const lead = speed * (this.readMs ?? OLDER_ASK_GUESS_MS) * OLDER_AHEAD_MARGIN;
    return Math.max(floor, Math.min(lead, viewport * OLDER_AHEAD_MAX_VIEWPORTS));
  }

  /// A new chat: nothing read in another applies.
  reset(): void {
    this.speed = 0;
    this.lastTop = undefined;
    this.lastAt = 0;
    this.readMs = undefined;
  }
}
