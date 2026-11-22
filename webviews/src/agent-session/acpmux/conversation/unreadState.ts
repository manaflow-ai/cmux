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
/// `quiet`: nothing new to read under the line (the transcript's `sinceNews`: only status lines,
/// such as a subagent's "started working", and the person's own prompts came since). A quiet mark
/// draws no line, no banner and no Jump up target (Leo, 2026-11-22: "it shouldnt just do this like
/// this when there's nothing"). Unknown until the transcript says, which a lone line (the gallery)
/// never does: it draws.
/// `placed`: the line's observer answered once, so where it first showed is known.
export type UnreadView = {
  mark: string;
  side: UnreadSide;
  seen: boolean;
  read: boolean;
  hidden: boolean;
  quiet?: boolean;
  placed?: boolean;
};

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
    now.quiet === next.quiet &&
    now.placed === next.placed
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
/// `inPlace`: the line marks a return to a chat that stayed on screen (the reader's hand came back
/// to the pane, not a chat picked), so a line on screen at its first answer sits over rows that
/// were already in front of them: it is read at once and never draws (Leo, 2026-11-22).
export function noteUnreadSide(mark: string, side: UnreadSide, inPlace = false): void {
  const now = of(mark);
  const first = !now.placed;
  const readNow = first && inPlace && side === "in";
  publish({
    ...now,
    side,
    seen: now.seen || side === "in",
    read: now.read || readNow,
    placed: true,
  });
}

/// Whether there is anything new to read under the line (the transcript's `sinceNews`). News that
/// comes under a quiet line while that line is on screen arrives in front of the reader: the line
/// is read and never draws.
export function noteUnreadNews(mark: string, news: boolean): void {
  const now = of(mark);
  const live = news && now.quiet === true && now.side === "in";
  publish({ ...now, quiet: !news, read: now.read || live });
}

/// The line was on screen to a reader at the pane for the dwell (SinceDivider.tsx `useDissipate`):
/// it has done its job and fades. The banner goes with it.
export function dissipateUnread(mark: string): void {
  const now = of(mark);
  publish({ ...now, seen: true, read: true });
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
  return !mine.hidden && !mine.seen && !mine.read && !mine.quiet && mine.side !== "in";
}

/// Whether the line for `mark` is read (it fades).
export const unreadRead = (mark: string, current: UnreadView | undefined): boolean =>
  current?.mark === mark && current.read;

/// Whether the line for `mark` draws: there is something new under it and it is not read. A line
/// that does not draw is only transparent: its row takes no height either way (SinceDivider.tsx).
export const unreadShows = (mark: string, current: UnreadView | undefined): boolean =>
  !(current?.mark === mark && (current.read || current.quiet === true));

/// Whether Jump up should take the reader to the line: there is one, with something new under it,
/// and it is not read yet.
export const unreadPending = (mark: string | undefined, current: UnreadView | undefined): boolean =>
  mark !== undefined && unreadShows(mark, current);

/// Test seam: forget every mark.
export function resetUnreadForTest(): void {
  view = undefined;
  for (const listener of listeners) listener();
}
