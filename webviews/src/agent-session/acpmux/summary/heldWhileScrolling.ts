// The right-hand card (the Summary card, SummaryCard.tsx, and Session Info, session-info/SessionInfo.tsx)
// holds still while the reader scrolls the chat (Leo, 2026-10-25: "session summary on top right
// flickers when im scrolling thru the chat"). The card is read from the chat's loaded rows, and
// scrolling up through a long chat pages older history in (direct.ts `loadOlder`): each page that
// landed under the scroll changed the card mid-gesture. It slid in from its reserved column, its
// header toggle flipped, sections appeared and it grew, page after page. The card now reads the rows
// as they stood when the reader started scrolling, and takes what the scroll paged in once, when the
// scroll settles. Only the reader's own scrolling holds it: a streamed reply that keeps the view at
// its end, Jump to latest's glide and every live update outside a scroll reach it at once.
//
// One flag for the page, set by the transcript's reader scrolls (App.tsx `onScroll`). A scroll event
// only re-arms the one settle timer; the flag notifies its readers twice per gesture (on and off),
// never per event, so a scroll renders nothing more than before. The timer stops when the scroll
// settles (`HOLD_SETTLE_MS` without a reader scroll) or when the page clears it (`releaseReaderScroll`).
import { useRef, useSyncExternalStore } from "react";
import { ScrollPacing } from "../pacing";

/// How long after the reader's last scroll the card takes what changed: the pane's own measure of a
/// settled scroll (pacing.ts).
export const HOLD_SETTLE_MS = ScrollPacing.settleMs;

type Clock = {
  setTimer: (callback: () => void, ms: number) => unknown;
  clearTimer: (handle: unknown) => void;
};

const browserClock: Clock = {
  setTimer: (callback, ms) => setTimeout(callback, ms),
  clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/// Whether the reader is scrolling: on at a reader scroll, off `settleMs` after the last one.
export class ReaderScroll {
  private scrolling = false;
  private settle: unknown;
  private readonly listeners = new Set<() => void>();

  constructor(
    private readonly clock: Clock = browserClock,
    private readonly settleMs = HOLD_SETTLE_MS,
  ) {}

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  readonly read = () => this.scrolling;

  /// A scroll the reader made (wheel, trackpad, keys, scrollbar drag).
  scrolled(): void {
    if (this.settle !== undefined) this.clock.clearTimer(this.settle);
    this.settle = this.clock.setTimer(this.release, this.settleMs);
    if (this.scrolling) return;
    this.scrolling = true;
    this.notify();
  }

  /// The scroll settled, or the page let go of it (another chat, the transcript unmounting).
  readonly release = () => {
    if (this.settle !== undefined) this.clock.clearTimer(this.settle);
    this.settle = undefined;
    if (!this.scrolling) return;
    this.scrolling = false;
    this.notify();
  };

  private notify() {
    for (const listener of this.listeners) listener();
  }
}

/// The page's one reader-scroll flag.
export const readerScroll = new ReaderScroll();
export const noteReaderScroll = () => readerScroll.scrolled();
export const releaseReaderScroll = () => readerScroll.release();

/// `value` as it stood when the reader started scrolling, until the scroll settles; `value` itself
/// otherwise. A change of `key` (another chat) takes the new value at once.
export function useHeldWhileScrolling<T>(value: T, key: unknown, flag: ReaderScroll = readerScroll): T {
  const scrolling = useSyncExternalStore(flag.subscribe, flag.read, () => false);
  const held = useRef<{ value: T; key: unknown }>({ value, key });
  if (!scrolling || held.current.key !== key) held.current = { value, key };
  return held.current.value;
}
