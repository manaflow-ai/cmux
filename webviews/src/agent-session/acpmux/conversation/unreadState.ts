// The unread marker's state (design/transcript-overlays.md): where the "New" line is from the
// reader, whether its mark is read, and how the floating banner shows. One small store, read with
// useSyncExternalStore by the divider (SinceDivider.tsx), the banner (UnreadBanner) and the
// transcript (VirtualTranscript.tsx, Jump up). Nothing here runs per scroll frame: the line's one
// IntersectionObserver and the reader's own presses write it.
//
// A mark is `AcpmuxSince.key` (the chat and its seen seq), so a later return is a new mark and
// everything the reader did to the old one (read, the banner hidden) stays with the old one.

/// Where the drawn line is from the reader: on screen, above or below the view. The virtual
/// transcript drops a row far from the view, so a line not drawn keeps the side it left by (above at
/// first: a chat opens at its latest message).
export type UnreadSide = "in" | "above" | "below";

/// `seen`: the line was on screen once, or the reader pressed Jump or reached the latest message by
/// their own move (`sinceDone`, #40065): the banner has done its job for this mark.
/// `read`: Mark read, or seen and then the latest message reached: the line fades (no row moves).
/// `hidden`: the banner's ×/Mark read, until the next mark.
/// `count`: the messages after the line ("157 new messages", `countNewMessages`), kept current while
/// the line is unread and frozen once it is read, so a fading label never changes under the eye.
export type UnreadView = {
  mark: string;
  side: UnreadSide;
  seen: boolean;
  read: boolean;
  hidden: boolean;
  count?: number;
};

/// How long the line stays once it has been on screen before it fades in place (Leo, 2026-11-15,
/// of the terminal's "157 new messages" rule: "we needto properly do somthing like this in the gui
/// somehow"). Long enough to see where the new part starts; scrolling past it fades it sooner.
export const SINCE_FADE_MS = 6_000; // motion-allow: how long a seen line stays before its fade (--agent-motion-calm), not an animation

/// The most messages the line counts: past it the label reads "999+", and counting stays bounded
/// however long the chat ran while the person was away.
export const SINCE_COUNT_CAP = 999;

/// The row kinds that count as a message after the line: what the agent or another person said or
/// ran. Notices, status, mux rows, recaps and the line itself never count (design/transcript-overlays.md).
export const MESSAGE_KINDS: ReadonlySet<string> = new Set(["assistant", "user", "activity", "btw"]);

/// How many rows of any kind `countNewMessages` reads per message it may count.
const ROWS_PER_MESSAGE = 8;

/// The messages after the row `dividerId` in `rows`, read from the end back to it. Bounded, so a
/// chat that ran all day costs the same per update as one that ran a minute: past `cap` messages it
/// answers `cap` + 1 (the label's "999+"); past `ROWS_PER_MESSAGE` times as many rows of any kind
/// with fewer messages it answers `undefined` (the label reads "New": no number it cannot stand by).
/// `undefined` too when no line is found.
export function countNewMessages(
  rows: readonly { id: string; kind: string }[],
  dividerId: string,
  cap = SINCE_COUNT_CAP,
): number | undefined {
  let count = 0;
  const last = Math.max(0, rows.length - cap * ROWS_PER_MESSAGE);
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.id === dividerId) return count;
    if (MESSAGE_KINDS.has(row.kind)) count += 1;
    if (count > cap) return count;
    if (index > 0 && index <= last) return undefined;
  }
  return undefined;
}

/// How the banner shows, the `agentPane.display.unreadBanner` setting (chatDisplay.ts): expanded
/// (the count, the time, Jump and Mark read), collapsed (a small pill), or off.
export type UnreadBannerMode = "expanded" | "collapsed" | "off";
export const UNREAD_BANNER_MODES: readonly UnreadBannerMode[] = ["expanded", "collapsed", "off"];
export const isUnreadBannerMode = (value: unknown): value is UnreadBannerMode =>
  value === "expanded" || value === "collapsed" || value === "off";

let view: UnreadView | undefined;
const listeners = new Set<() => void>();

function publish(next: UnreadView): void {
  const now = view;
  if (
    now?.mark === next.mark &&
    now.side === next.side &&
    now.seen === next.seen &&
    now.read === next.read &&
    now.hidden === next.hidden &&
    now.count === next.count
  )
    return;
  if (now?.mark !== next.mark || next.read) clearFade();
  view = next;
  for (const listener of listeners) listener();
}

/// The one fade timer, for the mark whose line came on screen (`noteUnreadSide`).
let fade: { mark: string; timer: unknown } | undefined;
type FadeTimers = { set: (fn: () => void, ms: number) => unknown; clear: (timer: unknown) => void };
const PAGE_TIMERS: FadeTimers = {
  set: (fn, ms) => setTimeout(fn, ms),
  clear: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
};
let timers = PAGE_TIMERS;
/// Test seam: the fade's timers (the page's unless a test passes its own).
export function setSinceTimersForTest(next: FadeTimers = PAGE_TIMERS): void {
  timers = next;
}
function clearFade(): void {
  if (fade) timers.clear(fade.timer);
  fade = undefined;
}
function armFade(mark: string): void {
  if (fade?.mark === mark) return;
  clearFade();
  fade = {
    mark,
    timer: timers.set(() => {
      fade = undefined;
      if (view?.mark === mark && !view.read) publish({ ...view, seen: true, read: true });
    }, SINCE_FADE_MS),
  };
}

/// The view for `mark`: a mark not met yet starts above (the chat opened at its latest message).
function of(mark: string): UnreadView {
  return view?.mark === mark ? view : { mark, side: "above", seen: false, read: false, hidden: false };
}

export const subscribeUnread = (listener: () => void): (() => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
export const readUnread = (): UnreadView | undefined => view;

/// The line's observer: where the line is now. On screen once, it is seen and fades a moment later
/// (`SINCE_FADE_MS`); seen and then scrolled past (above the view), it is read at once. Read, it
/// fades in place: its row keeps its height, so nothing below it moves.
export function noteUnreadSide(mark: string, side: UnreadSide): void {
  const now = of(mark);
  const passed = now.seen && now.side === "in" && side === "above";
  publish({ ...now, side, seen: now.seen || side === "in", read: now.read || passed });
  if (side === "in" && !now.read) armFade(mark);
}

/// How many messages came after the line for `mark` (App.tsx, `countNewMessages` over the rows).
/// Only the label's words change: the row keeps its height. Frozen once the line is read.
export function noteUnreadCount(mark: string, count: number | undefined): void {
  const now = of(mark);
  if (now.read || count === undefined) return;
  publish({ ...now, count });
}

/// The line came into the DOM for `mark` (its row mounted): a new mark starts its view.
export function noteUnreadMounted(mark: string): void {
  if (view?.mark !== mark) publish(of(mark));
}

/// Ends the banner for `mark` without the line having been on screen: the reader pressed Jump, or
/// went to the latest message themselves (VirtualTranscript.tsx, follow-bottom turning on by the
/// reader's move). Below the latest message a line is above the view, whatever its observer last
/// read (#40065). A mark seen and then left at the latest message is read: the line fades.
export function sinceDone(mark: string, reachedLatest = false): void {
  const now = of(mark);
  const side: UnreadSide = now.side === "in" ? "in" : "above";
  publish({ ...now, side, seen: true, read: now.read || (reachedLatest && now.seen) });
}

/// Mark read: the line fades in place and the banner goes until the next mark.
export function markUnreadRead(mark: string): void {
  publish({ ...of(mark), seen: true, read: true, hidden: true });
}

/// The banner's own dismiss without reading: it goes until the next mark, the line stays.
export function hideUnreadBanner(mark: string): void {
  publish({ ...of(mark), hidden: true });
}

/// Whether the banner shows for `mark`: not off, not hidden for this mark, not done, and the line
/// off screen.
export function bannerShown(
  mark: string | undefined,
  current: UnreadView | undefined,
  mode: UnreadBannerMode,
): boolean {
  if (mark === undefined || mode === "off") return false;
  const mine = current?.mark === mark ? current : undefined;
  if (!mine) return true;
  return !mine.hidden && !mine.seen && !mine.read && mine.side !== "in";
}

/// Whether the line for `mark` is read (it fades).
export const unreadRead = (mark: string, current: UnreadView | undefined): boolean =>
  current?.mark === mark && current.read;

/// Whether Jump up should take the reader to the line: there is one, and it is not read yet.
export const unreadPending = (mark: string | undefined, current: UnreadView | undefined): boolean =>
  mark !== undefined && !(current?.mark === mark && current.read);

/// Test seam: forget every mark.
export function resetUnreadForTest(): void {
  clearFade();
  view = undefined;
  for (const listener of listeners) listener();
}
