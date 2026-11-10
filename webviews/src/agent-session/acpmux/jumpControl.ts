// The transcript's one jump control (design/transcript-overlays.md, VirtualTranscript.tsx
// JumpToLatest). Leo, 2026-11-10, of a Jump up disc stacked on Jump to latest with the unread pill
// under them: "There's also no point doubling up on this", and of Jump up: "what is the point of that
// if it's just, like, if it's always there? Like, this should be more selective. And it also needs to
// work better with when there is truly some unread stuff from the past."
//
// So there is one control, and it does the jump the view needs:
// - `unread`: "New since you looked" lies above the view, not yet reached: up to it, with the count;
// - `latest`: scrolled up from the latest message (or a chat this one started waits on an answer):
//   down to it, Jump to latest or the Needs your input pill;
// - `hidden`: neither.
// Pure: VirtualTranscript.tsx feeds it the unread marker's state and where the view is.

import type { UnreadBannerMode, UnreadView } from "./conversation/unreadState";

export type JumpControl = { kind: "unread"; turns: number } | { kind: "latest" } | { kind: "hidden" };

/// Whether the unread line for `mark` is above the view and still the reader's to reach: not read,
/// not hidden, never on screen, and not passed by a jump or by the reader reaching the latest message
/// (unreadState.ts `sinceDone`). A mark the line's observer has not reported yet is above: a chat
/// opens at its latest message. Off (the unread setting) leaves it out.
export function unreadAbove(mark: string, view: UnreadView | undefined, mode: UnreadBannerMode): boolean {
  if (mode === "off") return false;
  const mine = view?.mark === mark ? view : undefined;
  if (!mine) return true;
  return !mine.seen && !mine.read && !mine.hidden && mine.side === "above";
}

export function jumpControl({
  unread,
  behind,
  asks,
  asksElsewhere,
}: {
  /// The chat's "New since you looked", when it has one drawn.
  /// `above`: the line lies wholly above the view by the transcript's layout.
  unread?: { mark: string; turns: number; view: UnreadView | undefined; mode: UnreadBannerMode; above: boolean };
  /// Scrolled up from the latest message (VirtualTranscript.tsx `behind`).
  behind: boolean;
  /// Open asks, and how many of them wait in other chats (needsYou/JumpPill.ts).
  asks: number;
  asksElsewhere: number;
}): JumpControl {
  // An ask waiting below (or in a chat this one started) comes first: the reader is needed there.
  if (asks > 0 && (behind || asksElsewhere > 0)) return { kind: "latest" };
  if (unread && unread.turns > 0 && unread.above && unreadAbove(unread.mark, unread.view, unread.mode))
    return { kind: "unread", turns: unread.turns };
  if (behind || asksElsewhere > 0) return { kind: "latest" };
  return { kind: "hidden" };
}
