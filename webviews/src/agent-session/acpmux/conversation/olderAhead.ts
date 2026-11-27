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
/// A display frame (ms). A scroll event comes once a frame whose offset moved, so the first one after
/// a rest carries one frame's move: a fling's or a drag's first frame, its speed from the start.
const FRAME_MS = 1000 / 60;

export class OlderAhead {
  /// The reader's upward speed, px/ms; 0 while still or going down.
  private speed = 0;
  private lastTop: number | undefined;
  private lastAt = 0;
  /// The last upward wheel (ms), whether it moved the view or not (`wheeledUp`).
  private wheelUpAt = Number.NEGATIVE_INFINITY;
  /// That wheel's speed up, px/ms: its step, which the view takes in a frame.
  private wheelSpeed = 0;
  /// How long a page has taken to read, smoothed (ms); undefined before the first.
  private readMs: number | undefined;

  /// A scroll event: `top` is the view's offset among the rows, `now` in ms.
  scrolled(top: number, now: number): void {
    const gap = now - this.lastAt;
    if (this.lastTop === undefined || gap <= 0) this.speed = 0;
    // The first event after a rest: the view stood at the last offset until the frame before this
    // event, so the move is that one frame's. Read as no speed, a fling's first frames asked for the
    // next page only once it was a few views from the loaded rows' top, and a short one (`rising`):
    // the fling reached that top within three frames, before the page came (transcript-scroll-up).
    else if (gap > SCROLL_GAP_MS) this.speed = Math.max(0, this.lastTop - top) / FRAME_MS;
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
    const scrolling = now - this.lastAt > SCROLL_GAP_MS ? 0 : this.speed;
    const speed = Math.max(scrolling, now - this.wheelUpAt > SCROLL_GAP_MS ? 0 : this.wheelSpeed);
    const lead = speed * (this.readMs ?? OLDER_ASK_GUESS_MS) * OLDER_AHEAD_MARGIN;
    return Math.max(floor, Math.min(lead, viewport * OLDER_AHEAD_MAX_VIEWPORTS));
  }

  /// An upward wheel at `now` (ms), whether or not it moved the view, of `pixels` (its step up, 0 when
  /// not in pixels): the speed the view goes up at from its first frame, before any scroll event.
  wheeledUp(now: number, pixels = 0): void {
    this.wheelUpAt = now;
    this.wheelSpeed = Math.max(0, pixels) / FRAME_MS;
  }

  /// Whether the reader is scrolling up now. An ask made while they are reads the big older page and
  /// pages ahead (direct.ts `loadOlder`); one made at rest (an open filling the view) reads a short one.
  /// A reader wheeling up against the loaded rows' top, held there until the page lands, is rising
  /// too: read as at rest, each page after the hold was a short one with none read ahead, so the
  /// reader caught up with the loaded top again at once.
  rising(now: number): boolean {
    return (now - this.lastAt <= SCROLL_GAP_MS && this.speed > 0) || now - this.wheelUpAt <= SCROLL_GAP_MS;
  }

  /// A new chat: nothing read in another applies.
  reset(): void {
    this.speed = 0;
    this.lastTop = undefined;
    this.lastAt = 0;
    this.readMs = undefined;
    this.wheelUpAt = Number.NEGATIVE_INFINITY;
    this.wheelSpeed = 0;
  }
}
