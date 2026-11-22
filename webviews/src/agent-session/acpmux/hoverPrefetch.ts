// A chat the pointer rests on in the sidebar is read before the click (Leo, 2026-11-01: "loading
// into a chat and some of its recent messages ... it's not cached well enough nor
// prerendered/prefetched well enough"). The app's sidebar is native; it forwards each row the
// pointer moves onto (and the row a keyboard step heads for) as the host's `chat.prefetch` with
// `hover: true`, and nothing else. Every rule about when a hover is worth a read lives here:
//
//   - a hover must REST on a row for HOVER_DWELL_MS, so a pointer passing over rows on its way
//     somewhere reads none of them. One timer at a time: the next hover, a hover that left
//     (no session), Low Power Mode (also turning on mid-dwell) and the client's close cancel it;
//   - a chat read for a hover is not read again for HOVER_REFIRE_MS (the pointer leaving a row and
//     coming back, a jittery pointer between two rows). The chats remembered for that are the
//     HOVER_RECENT most recent, so the map never grows with the sidebar;
//   - what a read costs and keeps is the read-ahead's (direct.ts `prefetchForHost`): at most two
//     reads out at once, the page's read-ahead tier of 24 tails, and the host's 20 chats.
//
// Nothing here walks the list or the rows: each hover is O(1), whatever the sidebar holds.

/// How long the pointer must rest on a row before its chat is read. Long enough that a sweep down
/// the sidebar (a row every 20-40 ms) reads nothing; short enough that the read is in before a
/// click that follows a deliberate move, which takes a person 200 ms and more.
export const HOVER_DWELL_MS = 100;
/// A chat read for a hover is not read again for this long (the read-ahead's own refresh,
/// direct.ts READ_AHEAD_REFRESH_MS, decides past that whether it changed enough to read again).
export const HOVER_REFIRE_MS = 5_000;
/// The chats remembered for HOVER_REFIRE_MS; older ones are forgotten first.
export const HOVER_RECENT = 8;

export type HoverOptions = {
  /// The Mac is in Low Power Mode: a guess at the next click is not worth the read.
  lowPower?: boolean;
};

/// Timers and the clock, injectable so a test runs the dwell without waiting on it.
export type HoverClock = {
  now(): number;
  setTimeout(run: () => void, ms: number): unknown;
  clearTimeout(timer: unknown): void;
};

const realClock: HoverClock = {
  now: () => Date.now(),
  setTimeout: (run, ms) => setTimeout(run, ms),
  clearTimeout: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
};

export class HoverPrefetch {
  private timer: unknown;
  private pending: string | undefined;
  /// Chats read for a hover, by when, least recent first.
  private fired = new Map<string, number>();
  private stopped = false;

  constructor(
    private readonly read: (sessionId: string) => void,
    private readonly clock: HoverClock = realClock,
    private readonly dwellMs = HOVER_DWELL_MS,
  ) {}

  /// The pointer is on `sessionId`'s row now (undefined: on no chat's row). Replaces any hover
  /// still waiting out its dwell.
  hover(sessionId: string | undefined, options: HoverOptions = {}): void {
    if (this.stopped) return;
    // Low Power Mode first: it cancels a dwell on this same row too (the host sends it on again
    // when the Mac turns Low Power Mode on, AgentPaneView+HoverPrefetch.swift).
    if (options.lowPower || !sessionId) return this.cancel();
    if (sessionId === this.pending) return;
    this.cancel();
    const firedAt = this.fired.get(sessionId);
    if (firedAt !== undefined && this.clock.now() - firedAt < HOVER_REFIRE_MS) return;
    this.pending = sessionId;
    this.timer = this.clock.setTimeout(() => {
      this.timer = undefined;
      this.pending = undefined;
      if (this.stopped) return;
      this.fired.delete(sessionId);
      this.fired.set(sessionId, this.clock.now());
      while (this.fired.size > HOVER_RECENT) this.fired.delete(this.fired.keys().next().value!);
      this.read(sessionId);
    }, this.dwellMs);
  }

  /// A hover still waiting out its dwell reads nothing.
  cancel(): void {
    if (this.timer !== undefined) this.clock.clearTimeout(this.timer);
    this.timer = undefined;
    this.pending = undefined;
  }

  /// The client is going away: no timer outlives it, and nothing is remembered.
  stop(): void {
    this.cancel();
    this.stopped = true;
    this.fired.clear();
  }

  /// Test seam: the hover waiting out its dwell, and how many chats are remembered.
  get waiting(): string | undefined {
    return this.pending;
  }
  get remembered(): number {
    return this.fired.size;
  }
}
