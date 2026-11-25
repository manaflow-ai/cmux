// The guest's `typing {on}` (design/chat-multiplayer.md 4.3): on at the first keystroke of a draft,
// off when it is sent or cleared or after 5 s without a keystroke, and never more than two frames a
// second; a change inside that gap goes when it ends, and only if it still differs from what was
// sent. One-shot timers only, none while nothing changes.

export const TYPING_IDLE_MS = 5_000;
/** At most two frames a second. */
export const TYPING_GAP_MS = 500;

export type TypingTimers = {
  set: (run: () => void, ms: number) => unknown;
  clear: (timer: unknown) => void;
  now: () => number;
};

const realTimers: TypingTimers = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
  now: () => performance.now(),
};

export class TypingSignal {
  /** What the room last heard. */
  private sent = false;
  private wanted = false;
  private lastSentAt = Number.NEGATIVE_INFINITY;
  private idle?: unknown;
  private gap?: unknown;

  constructor(
    /** Sends `typing {on}`; false when there is no live connection. */
    private readonly send: (on: boolean) => boolean,
    private readonly timers: TypingTimers = realTimers,
  ) {}

  /** The draft changed to `text`. */
  input(text: string): void {
    if (!text.trim()) return this.stop();
    this.clearIdle();
    this.idle = this.timers.set(() => {
      this.idle = undefined;
      this.want(false);
    }, TYPING_IDLE_MS);
    this.want(true);
  }

  /** The draft was sent or cleared. */
  stop(): void {
    this.clearIdle();
    this.want(false);
  }

  /** A new connection: the room heard nothing from this one yet. */
  reset(): void {
    this.sent = false;
    this.flush();
  }

  dispose(): void {
    this.clearIdle();
    if (this.gap !== undefined) this.timers.clear(this.gap);
    this.gap = undefined;
  }

  private want(on: boolean): void {
    this.wanted = on;
    this.flush();
  }

  private flush(): void {
    if (this.wanted === this.sent || this.gap !== undefined) return;
    const wait = this.lastSentAt + TYPING_GAP_MS - this.timers.now();
    if (wait > 0) {
      this.gap = this.timers.set(() => {
        this.gap = undefined;
        this.flush();
      }, wait);
      return;
    }
    if (!this.send(this.wanted)) return;
    this.sent = this.wanted;
    this.lastSentAt = this.timers.now();
  }

  private clearIdle(): void {
    if (this.idle !== undefined) this.timers.clear(this.idle);
    this.idle = undefined;
  }
}
