// Whether the reader is at the chat: the page shows and their hand moved on it lately (Leo,
// 2026-11-11: "if someone steps away from the computer for a bit, that doesn't mean they're
// necessarily watching it, right? Like if they didn't move the mouse at all, then it's like, well,
// they didn't see it. There's that activity sort of model there.").
//
// The pane tells acpmux whether the reader attends the chat it shows (direct.ts `syncView`,
// `attending`), so a turn that ends while they are away is unread (acpmux hub/seen.rs) while the
// chat stays shown (its process, recap and presence), and coming back by hand is seeing it: "New since you looked" goes after the last record they were here for, and Jump up
// takes them there. Chat apps mark a channel read while it is open in a focused window; this asks
// for a hand on it, since a window left open on a chat says nothing about whether anyone read it.
//
// One record per page: an input moves `lastInputAt` and nothing else; a single timer, armed once
// per away/back change and re-armed only when it fires early, turns the reader away. No work per
// pointer move beyond a store. It listens only while something subscribes: a page with no chat
// client (a guest's fed transcript) keeps no listener, and the last client's dispose removes them.

/// How long without a pointer move, wheel, key or focus on the page before the reader counts as
/// away. Long enough to read a reply without touching anything; short enough that stepping away
/// leaves what came after unread.
export const ATTENTION_IDLE_MS = 2 * 60_000;

/// The inputs that say a hand is on the page.
const INPUTS = ["pointermove", "pointerdown", "wheel", "keydown", "touchstart"] as const;

/// Whether a reader whose last input was at `lastInputAt` is still here at `now`.
export function presentAt(lastInputAt: number, now: number, idleMs = ATTENTION_IDLE_MS): boolean {
  return now - lastInputAt < idleMs;
}

export type Attention = {
  /// The reader's hand was on the page within the idle time.
  present(): boolean;
  /// When their hand was last on the page: what a chat had by then is what they saw (direct.ts
  /// `noteSeen`, acpmux `seenSeq`).
  lastInputAt(): number;
  /// An input this page's own listeners do not see: the reader showed the page (switched to its
  /// tab or workspace) or picked a chat in it.
  touch(): void;
  /// Called when `present()` changes, either way.
  subscribe(listener: () => void): () => void;
  dispose(): void;
};

type AttentionTarget = Pick<Window, "addEventListener" | "removeEventListener">;

/// Watches `target` for input while it has a subscriber; with none it says the reader is here and
/// listens to nothing. `now` and the timers are the page's unless a test passes its own.
export function createAttention(
  target: AttentionTarget,
  idleMs = ATTENTION_IDLE_MS,
  now: () => number = Date.now,
  timers: { set: (fn: () => void, ms: number) => unknown; clear: (id: unknown) => void } = {
    set: (fn, ms) => setTimeout(fn, ms),
    clear: (id) => clearTimeout(id as ReturnType<typeof setTimeout>),
  },
): Attention {
  let lastInputAt = now();
  let here = true;
  let timer: unknown;
  const listeners = new Set<() => void>();
  const changed = () => {
    for (const listener of listeners) listener();
  };
  const arm = (ms: number) => {
    timer = timers.set(check, Math.max(0, ms));
  };
  // The timer runs once per idle time at most: inputs since it was armed only push the next check out.
  function check(): void {
    timer = undefined;
    const left = lastInputAt + idleMs - now();
    if (left > 0) return arm(left);
    if (!here) return;
    here = false;
    changed();
  }
  const input = () => {
    lastInputAt = now();
    if (timer === undefined) arm(idleMs);
    if (here) return;
    here = true;
    changed();
  };
  const start = () => {
    for (const name of INPUTS) target.addEventListener(name, input, { capture: true, passive: true });
    target.addEventListener("focus", input);
    // Watching starts with a reader here: whoever opened the chat did it by hand.
    lastInputAt = now();
    here = true;
    arm(idleMs);
  };
  const stop = () => {
    for (const name of INPUTS) target.removeEventListener(name, input, { capture: true });
    target.removeEventListener("focus", input);
    if (timer !== undefined) timers.clear(timer);
    timer = undefined;
    here = true;
  };
  return {
    present: () => here,
    lastInputAt: () => lastInputAt,
    touch: () => {
      if (listeners.size > 0) input();
    },
    subscribe(listener) {
      if (listeners.size === 0) start();
      listeners.add(listener);
      return () => {
        if (!listeners.delete(listener) || listeners.size > 0) return;
        stop();
      };
    },
    dispose() {
      if (listeners.size > 0) stop();
      listeners.clear();
    },
  };
}

let page: { target: AttentionTarget; attention: Attention } | undefined;

/// The page's own attention, made on first use (and again for another window, as tests swap it);
/// none where there is no window (tests without a DOM, workers), where the reader counts as here.
export function pageAttention(): Attention | undefined {
  if (typeof window === "undefined" || typeof window.addEventListener !== "function") return undefined;
  if (page?.target !== window) page = { target: window, attention: createAttention(window) };
  return page.attention;
}
