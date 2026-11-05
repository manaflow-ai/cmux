// Several people in one physical room: each person's mic also hears the others. Echo
// cancellation removes the call's own playback, not a voice in the same room, so the same
// sentence can arrive from two speakers' transcribers. The louder mic is the speaker's own, so
// within `windowMs` a near-duplicate line from another speaker is dropped, unless it is louder:
// then it replaces the quieter one.

export interface Heard {
  speaker: string;
  text: string;
  at: number;
  /** Mic level 0...1 when the line was said; louder means closer to the speaker. */
  level: number;
  /** The memory entry this line became, once appended. */
  entryId?: number;
}

export type DedupeVerdict = { kind: "new" } | { kind: "duplicate" } | { kind: "replace"; previous: Heard };

export function words(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s']/gu, " ")
    .split(/\s+/)
    .filter(Boolean);
}

/** Jaccard similarity of the two lines' word sets. */
export function similarity(a: string, b: string): number {
  const left = new Set(words(a));
  const right = new Set(words(b));
  if (left.size === 0 || right.size === 0) return 0;
  let shared = 0;
  for (const word of left) if (right.has(word)) shared += 1;
  return shared / (left.size + right.size - shared);
}

export class CrossMicDedupe {
  private recent: Heard[] = [];

  constructor(
    private readonly windowMs = 4000,
    private readonly threshold = 0.6,
  ) {}

  check(line: Heard): DedupeVerdict {
    this.recent = this.recent.filter((seen) => line.at - seen.at <= this.windowMs);
    const match = this.recent.find(
      (seen) => seen.speaker !== line.speaker && similarity(seen.text, line.text) >= this.threshold,
    );
    if (!match) return { kind: "new" };
    if (line.level > match.level) {
      // The louder speaker takes over the entry the quieter mic made.
      this.recent = this.recent.filter((seen) => seen !== match);
      this.recent.push({ ...line, entryId: match.entryId });
      return { kind: "replace", previous: match };
    }
    return { kind: "duplicate" };
  }

  /** Records a line that became a new entry, so later copies from other mics match it. */
  remember(line: Heard): void {
    this.recent.push(line);
  }
}
