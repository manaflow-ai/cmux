// Whether the person attends the chat on screen: the read model behind "New since you looked" and
// Jump up (design/transcript-overlays.md, "What counts as seen"). Leo, 2026-11-11: "if someone steps
// away from the computer for a bit, that doesn't mean they're necessarily watching it, right? Like if
// they didn't move the mouse at all, then it's like, well, they didn't see it. There's that activity
// sort of model there."
//
// A chat's rows are seen only while all three hold:
//
// - the page is on screen (`document.visibilityState`, a background workspace or an occluded window
//   is hidden);
// - its window is key and the pane has focus (`document.hasFocus()`, window focus and blur);
// - the person moved the pointer, pressed a key or a button, or scrolled in the pane within
//   `ATTENTION_IDLE_MS`.
//
// acpmux owns the read state (`hub/seen.rs`): the pane only says whether its person attends
// (`_acpmux/view` `attending`), with the log seq it held at their last input (`seenSeq`), and the
// daemon keeps the chat's mark (`seenSeq` in session.json), counts the turns that end unattended and
// answers the return. This file decides nothing but the three facts above, and runs nothing per
// input but a timestamp write: the idle timer is armed once per window and re-armed lazily.

/// How long without input the person still counts as attending: 60 s. Long enough to read a screenful
/// of a reply without touching anything (about 250 words at a reading pace of 250 a minute, the most
/// a 900 px pane shows of prose), short enough that stepping away from the desk (a coffee, a call)
/// counts as away before the next turn of a working agent ends. Longer windows mark turns read that
/// ended after the person left; shorter ones put "New" over text they were reading.
export const ATTENTION_IDLE_MS = 60_000;

/// What the pane knows about its person, at `now` (ms).
export type AttentionFacts = {
  shown: boolean;
  focused: boolean;
  /// When the person last gave input in the pane (ms), if ever since it loaded.
  lastInputAt: number | undefined;
  now: number;
  idleMs?: number;
};

/// Whether the person attends the chat: on screen, focused, and input within the idle window.
export function attending(facts: AttentionFacts): boolean {
  const { shown, focused, lastInputAt, now, idleMs = ATTENTION_IDLE_MS } = facts;
  return shown && focused && lastInputAt !== undefined && now - lastInputAt < idleMs;
}

/// The page's surroundings, injected so tests drive them without a browser.
export type AttentionEnv = {
  now(): number;
  shown(): boolean;
  focused(): boolean;
  setTimer(run: () => void, ms: number): unknown;
  clearTimer(timer: unknown): void;
  /// Subscribes to the page's input and focus events; returns the unsubscribe.
  listen(onInput: () => void, onFocusChange: () => void): () => void;
  idleMs?: number;
};

/// The inputs that are the person: pointer, keys, wheel and scroll. A scroll the transcript makes
/// itself (following a streaming reply) is no input: only `wheel`, keys and the pointer count, and a
/// scrollbar drag is a pointerdown.
const INPUTS = ["pointermove", "pointerdown", "keydown", "wheel", "touchstart"] as const;

/// The browser's surroundings: the page's own events, captured so a control that stops propagation
/// still counts. Passive: nothing here delays an input.
export function browserAttentionEnv(): AttentionEnv | undefined {
  if (typeof document === "undefined" || typeof window === "undefined") return undefined;
  // Test seam: the browser tests shorten the window (agent-pane-seen.test.ts).
  const idle = (globalThis as { __cmuxAttentionIdleMs?: unknown }).__cmuxAttentionIdleMs;
  return {
    now: () => Date.now(),
    shown: () => document.visibilityState !== "hidden",
    focused: () => document.hasFocus(),
    setTimer: (run, ms) => setTimeout(run, ms),
    clearTimer: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
    listen(onInput, onFocusChange) {
      const options = { capture: true, passive: true } as const;
      for (const kind of INPUTS) window.addEventListener(kind, onInput, options);
      window.addEventListener("focus", onFocusChange);
      window.addEventListener("blur", onFocusChange);
      document.addEventListener("visibilitychange", onFocusChange);
      return () => {
        for (const kind of INPUTS) window.removeEventListener(kind, onInput, options);
        window.removeEventListener("focus", onFocusChange);
        window.removeEventListener("blur", onFocusChange);
        document.removeEventListener("visibilitychange", onFocusChange);
      };
    },
    ...(typeof idle === "number" && idle > 0 ? { idleMs: idle } : {}),
  };
}

/// Follows whether the person attends and calls `onChange` once per flip. `onInput` runs on the
/// input that starts (or restarts) attending, and on each later one at most once per second, so its
/// owner can note the log seq the person has seen (`seenAt`).
export class Attention {
  private lastInputAt: number | undefined;
  private timer: unknown;
  private was: boolean;
  private readonly stop: () => void;
  private lastNoted = -Infinity;

  constructor(
    private readonly env: AttentionEnv,
    private readonly onChange: (attending: boolean) => void,
    private readonly onInput: () => void = () => {},
  ) {
    // The page opening on screen with focus is the person's doing (a click on the chat's row, a
    // shortcut): it counts as input. A page restored unfocused waits for the person.
    if (env.shown() && env.focused()) this.lastInputAt = env.now();
    this.was = this.now();
    if (this.was) {
      this.arm();
      this.lastNoted = env.now();
      this.onInput();
    }
    this.stop = env.listen(this.input, this.focusChanged);
  }

  /// Whether the person attends now.
  now(): boolean {
    return attending({
      shown: this.env.shown(),
      focused: this.env.focused(),
      lastInputAt: this.lastInputAt,
      now: this.env.now(),
      idleMs: this.env.idleMs,
    });
  }

  private readonly input = (): void => {
    const at = this.env.now();
    this.lastInputAt = at;
    if (at - this.lastNoted >= 1_000 || !this.was) {
      this.lastNoted = at;
      this.onInput();
    }
    if (!this.was) this.settle();
    else if (this.timer === undefined) this.arm();
  };

  /// Focus or visibility changed. Coming back on screen and focused is the person's doing too.
  private readonly focusChanged = (): void => {
    if (this.env.shown() && this.env.focused()) {
      this.lastInputAt = this.env.now();
      this.onInput();
    }
    this.settle();
  };

  /// The idle timer: fires at the window's end from the last input it knows of; an input since moves
  /// the end, so it re-arms for the rest instead of being reset on every pointer move.
  private arm(): void {
    if (this.timer !== undefined) this.env.clearTimer(this.timer);
    const idle = this.env.idleMs ?? ATTENTION_IDLE_MS;
    const left = this.lastInputAt === undefined ? idle : this.lastInputAt + idle - this.env.now();
    this.timer = this.env.setTimer(
      () => {
        this.timer = undefined;
        this.settle();
      },
      Math.max(0, left),
    );
  }

  private settle(): void {
    const next = this.now();
    if (next) this.arm();
    else if (this.timer !== undefined) {
      this.env.clearTimer(this.timer);
      this.timer = undefined;
    }
    if (next === this.was) return;
    this.was = next;
    this.onChange(next);
  }

  dispose(): void {
    this.stop();
    if (this.timer !== undefined) this.env.clearTimer(this.timer);
    this.timer = undefined;
  }
}
