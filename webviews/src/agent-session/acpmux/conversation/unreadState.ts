// The unread marker's state (design/transcript-overlays.md): where the "New" line is from the
// reader and whether its mark is read. One small store, read with useSyncExternalStore by the divider
// (SinceDivider.tsx) and the transcript (VirtualTranscript.tsx, whose one jump control points up to
// the line while it is above the view and unreached, jumpControl.ts `unreadAbove`). Nothing here runs
// per scroll frame: the line's one IntersectionObserver and the reader's own presses write it.
//
// A mark is `AcpmuxSince.key` (the chat and its seen seq), so a later return is a new mark and
// everything the reader did to the old one (read, reached) stays with the old one.

/// Where the drawn line is from the reader: on screen, above or below the view. The virtual
/// transcript drops a row far from the view, so a line not drawn keeps the side it left by (above at
/// first: a chat opens at its latest message).
export type UnreadSide = "in" | "above" | "below";

/// `seen`: the line was on screen once, or the reader pressed Jump or reached the latest message by
/// their own move (`sinceDone`, #40065): the unread jump has done its job for this mark.
/// `read`: Mark read, or seen and then the latest message reached: the line fades (no row moves).
/// `hidden`: Mark read, until the next mark.
export type UnreadView = { mark: string; side: UnreadSide; seen: boolean; read: boolean; hidden: boolean };

/// The `agentPane.display.unreadBanner` setting (chatDisplay.ts): `off` keeps the jump control from
/// pointing up to unread turns; `expanded` and `collapsed` both let it.
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
    now.hidden === next.hidden
  )
    return;
  view = next;
  for (const listener of listeners) listener();
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

/// The line's observer: where the line is now. On screen once, it is seen.
export function noteUnreadSide(mark: string, side: UnreadSide): void {
  const now = of(mark);
  publish({ ...now, side, seen: now.seen || side === "in" });
}

/// The line came into the DOM for `mark` (its row mounted): a new mark starts its view.
export function noteUnreadMounted(mark: string): void {
  if (view?.mark !== mark) publish(of(mark));
}

/// Ends the unread jump for `mark` without the line having been on screen: the reader pressed Jump, or
/// went to the latest message themselves (VirtualTranscript.tsx, follow-bottom turning on by the
/// reader's move). Below the latest message a line is above the view, whatever its observer last
/// read (#40065). A mark seen and then left at the latest message is read: the line fades.
export function sinceDone(mark: string, reachedLatest = false): void {
  const now = of(mark);
  const side: UnreadSide = now.side === "in" ? "in" : "above";
  publish({ ...now, side, seen: true, read: now.read || (reachedLatest && now.seen) });
}

/// Mark read: the line fades in place and the unread jump goes until the next mark.
export function markUnreadRead(mark: string): void {
  publish({ ...of(mark), seen: true, read: true, hidden: true });
}

/// Whether the line for `mark` is read (it fades).
export const unreadRead = (mark: string, current: UnreadView | undefined): boolean =>
  current?.mark === mark && current.read;

/// Test seam: forget every mark.
export function resetUnreadForTest(): void {
  view = undefined;
  for (const listener of listeners) listener();
}
