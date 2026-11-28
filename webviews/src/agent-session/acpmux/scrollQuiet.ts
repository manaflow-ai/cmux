// While a reader scrolls a chat, the agent pages hold the drawing of other chats' changes until the
// scroll rests (Leo, 2026-11-18: "Lawrence, on a relatively small chat, of course, like this is in
// his app with a lot of workspaces, a lot of history, and he was just scrolling up and down through
// that one particular chat, and you know, he was feeling some dropped frames, like it wasn't smooth.
// ... it gets sort of hijacked by the other parts of the app, which are actually non-visible.").
//
// Every agent page runs in one renderer, and each hears every chat's `_acpmux/session_changed`
// (about 4 a second on a fleet Mac). Each change drew the whole pane of every page, a New Tab page's
// lists and a page no tab shows included, between the scrolled chat's frames
// (bench/session-scale-scroll.bench.ts). The scrolled page says so to every page of its origin
// (a BroadcastChannel); a page that hears it draws another chat's change once no wheel has moved
// for `SCROLL_QUIET_MS`, in one snapshot. The page's own chat still draws at once.

/// How long after the last wheel a scroll counts as resting.
export const SCROLL_QUIET_MS = 250;
/// The longest a held change waits, however long the scroll goes on: the lists are never staler.
export const SCROLL_HOLD_MAX_MS = 5_000;
/// How often a scrolling page tells the others: each message pushes their rest out by the quiet time.
const ANNOUNCE_MS = 100;
const CHANNEL = "cmux-acpmux-scroll";

export type Clock = { now(): number; set(run: () => void, ms: number): unknown; clear(id: unknown): void };
const realClock: Clock = {
  now: () => performance.now(),
  set: (run, ms) => setTimeout(run, ms),
  clear: (id) => clearTimeout(id as ReturnType<typeof setTimeout>),
};

export type ScrollQuiet = {
  /// A wheel moved a chat on this page.
  scrolled(): void;
  /// Whether a chat on this page or another is scrolling now.
  scrolling(): boolean;
  /// Runs `run` once the scroll rests, or `SCROLL_HOLD_MAX_MS` after it was asked at the latest.
  /// The returned cancel drops it.
  afterScroll(run: () => void): () => void;
  dispose(): void;
};

type Channel = Pick<BroadcastChannel, "postMessage" | "close"> & {
  onmessage: ((event: MessageEvent) => void) | null;
};

export function createScrollQuiet(clock: Clock = realClock, channel: Channel | undefined = openChannel()): ScrollQuiet {
  let restAt = -Infinity;
  let announcedAt = -Infinity;
  const waits = new Set<{ run: () => void; since: number }>();
  let timer: unknown;
  const arm = () => {
    if (timer !== undefined) clock.clear(timer);
    timer = undefined;
    if (waits.size === 0) return;
    const now = clock.now();
    let due = restAt;
    for (const wait of waits) due = Math.min(due, wait.since + SCROLL_HOLD_MAX_MS);
    timer = clock.set(fire, Math.max(0, due - now));
  };
  function fire(): void {
    timer = undefined;
    const now = clock.now();
    const due = [...waits].filter((wait) => now >= restAt || now >= wait.since + SCROLL_HOLD_MAX_MS);
    for (const wait of due) waits.delete(wait);
    arm();
    for (const wait of due) wait.run();
  }
  const heard = () => {
    restAt = Math.max(restAt, clock.now() + SCROLL_QUIET_MS);
    if (waits.size > 0) arm();
  };
  if (channel) channel.onmessage = heard;
  return {
    scrolled() {
      heard();
      const now = clock.now();
      if (now - announcedAt < ANNOUNCE_MS) return;
      announcedAt = now;
      try {
        channel?.postMessage(1);
      } catch {
        // A closed channel tells nobody; this page still holds its own changes.
      }
    },
    scrolling: () => clock.now() < restAt,
    afterScroll(run) {
      const wait = { run, since: clock.now() };
      waits.add(wait);
      arm();
      return () => {
        if (waits.delete(wait)) arm();
      };
    },
    dispose() {
      waits.clear();
      arm();
      if (channel) {
        channel.onmessage = null;
        channel.close();
      }
    },
  };
}

function openChannel(): Channel | undefined {
  try {
    return typeof BroadcastChannel === "function" ? new BroadcastChannel(CHANNEL) : undefined;
  } catch {
    return undefined;
  }
}

let shared: ScrollQuiet | undefined;

/// The page's own, made on first use; none where there is no window (tests without a DOM, workers).
export function pageScrollQuiet(): ScrollQuiet | undefined {
  if (typeof window === "undefined") return undefined;
  shared ??= createScrollQuiet();
  return shared;
}

/// Drops the page's own, so the next test file's pages start with no scroll heard; with `clock`, the
/// page's own runs on it (a test moves time by hand instead of waiting).
export function resetPageScrollQuietForTests(clock?: Clock): void {
  shared?.dispose();
  shared = clock ? createScrollQuiet(clock, undefined) : undefined;
}
