// How much of a streaming agent message shows on each display frame. Deltas arrive in bursts
// (one per acpmux event, often several words at once); drawing each burst as it lands makes the
// text jump. The reveal instead advances every frame at a rate proportional to the backlog, so
// text flows at the stream's own speed with a short, steady delay, and never falls behind.

export type StreamRevealOptions = {
  /// Text already there when the row mounts (history, or a row scrolled into view mid-stream):
  /// it shows at once; only text after it is revealed.
  initial?: string;
  /// Reduce Motion: everything shows as it arrives.
  reduceMotion?: boolean;
};

export class StreamReveal {
  /// The backlog is revealed in about this long, whatever its size.
  static readonly catchUpMs = 120;
  /// Once the stream has ended, the rest shows in about this long.
  static readonly finishMs = 60;
  /// The slowest reveal, so a trickling stream still moves.
  static readonly minCharsPerSecond = 120;
  /// A longer gap between frames (a hidden pane, a long task) counts as this long.
  static readonly maxFrameMs = 50;
  /// A frame that ends inside a word moves to the word's end when it is at most this far.
  static readonly wordReach = 12;

  private shown: number;
  private target = 0;
  private lastFrame: number | undefined;
  /// When the current backlog should be fully shown.
  private deadline: number | undefined;
  private ending = false;
  private clock = 0;
  private readonly reduceMotion: boolean;

  constructor(options: StreamRevealOptions = {}) {
    this.shown = options.initial?.length ?? 0;
    this.target = this.shown;
    this.reduceMotion = options.reduceMotion ?? false;
  }

  /// Whether everything known so far shows.
  get settled(): boolean {
    return this.shown >= this.target;
  }

  /// The visible length of `text` for the frame at `now` (ms); `done` when the stream ended.
  advance(text: string, now: number, done: boolean): number {
    const grew = text.length > this.target;
    this.target = text.length;
    const elapsed =
      this.lastFrame === undefined ? 0 : Math.min(StreamReveal.maxFrameMs, Math.max(0, now - this.lastFrame));
    this.lastFrame = now;
    // Frame time with long gaps clamped, so a pause does not make the backlog overdue.
    this.clock += elapsed;
    const time = this.clock;
    if (this.reduceMotion || this.shown >= text.length) {
      this.shown = text.length;
      return this.shown;
    }
    // New text (or the end of the stream) sets when the backlog should be shown; the reveal
    // moves toward it linearly, so it neither stalls on a long tail nor bursts.
    const ending = done && !this.ending;
    this.ending = done;
    if (grew || ending || this.deadline === undefined) {
      const due = time + (done ? StreamReveal.finishMs : StreamReveal.catchUpMs);
      this.deadline = done ? Math.min(this.deadline ?? due, due) : due;
    }
    if (elapsed === 0) return this.shown;
    const backlog = text.length - this.shown;
    const remaining = Math.max(elapsed, this.deadline - time + elapsed);
    const step = Math.max((StreamReveal.minCharsPerSecond / 1000) * elapsed, (backlog * elapsed) / remaining);
    const end = StreamReveal.wordEnd(text, Math.min(text.length, this.shown + Math.ceil(step)));
    this.shown = Math.max(this.shown, end);
    return this.shown;
  }

  /// `end`, moved to the end of the word it falls in when that is near, and off a surrogate pair.
  private static wordEnd(text: string, end: number): number {
    if (end <= 0 || end >= text.length) return end;
    if (!/\s/.test(text[end]) && !/\s/.test(text[end - 1])) {
      const reach = Math.min(text.length, end + StreamReveal.wordReach);
      for (let index = end; index < reach; index += 1)
        if (/\s/.test(text[index])) {
          end = index;
          break;
        }
    }
    const code = text.charCodeAt(end - 1);
    if (code >= 0xd800 && code <= 0xdbff) end += 1;
    return end;
  }
}
