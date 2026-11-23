import { flushSync } from "react-dom";
import { type AcpmuxRow, type PlacedLayout } from "../model";
import { pressJumpUp, type JumpBack, type IdleTracker, type jumpUpTarget } from "../jumpUp";
import { isAgentMotionOff } from "../../shared/motion";
import { MOTION_MS } from "../../../motion/scale.generated";
import { animateScroll } from "../threadMinimap/scrollMotion";
import { JUMP_CURVE, jumpDuration, jumpGlideStart } from "../threadMinimap/model";
import { cssTimeMs } from "../conversation/fold";
import { type FoldAnchor } from "../conversation/foldAnchor";
import { clearScrollOrigin, layoutScrollTop, physicalScrollTop } from "../conversation/scrollCoordinates";
import { indexOfRow } from "./rowIndex";
import { restingAnchor } from "./scrollAnchors";

/// What `jumpToLatestWith` reads of TranscriptView, as of the call.
export type JumpToLatestDeps = {
  ref: { current: HTMLDivElement | null };
  canLoadNewer: boolean;
  onReturnToLatest: (() => Promise<void>) | undefined;
  latestAfterReturn: { current: { focused: boolean; path: string } | undefined };
  olderScrollTarget: { current: number | undefined };
  revealing: { current: string | undefined };
  revealWindow: { current: number };
  takeRoom: () => void;
  stopBottomStackFold: () => void;
  foldAnchor: { current: FoldAnchor | undefined };
  dropFoldRoom: (now?: boolean) => void;
  requestFollow: (node: HTMLElement) => void;
  follow: (next: boolean, path?: string) => void;
  focusComposer: (() => void) | undefined;
  latestLayout: { current: { layout: PlacedLayout; rows: readonly AcpmuxRow[] } };
  idle: IdleTracker;
  dropJumpBack: () => void;
  stopJump: () => void;
  rideToLatest: (node: HTMLDivElement, target: number, reduce: boolean, flush: boolean, send?: boolean) => void;
};

/// What `placeViewWith` reads of TranscriptView, as of the call.
export type PlaceViewDeps = {
  ref: { current: HTMLDivElement | null };
  revealing: { current: string | undefined };
  revealWindow: { current: number };
  stopJump: () => void;
  unlift: () => void;
  scrolledTo: { current: { top: number; atLatest: boolean } };
  follow: (next: boolean, path?: string) => void;
  placing: { current: boolean };
  setScrollAt: (top: number, delta?: number) => void;
  placedTop: { current: number | undefined };
};

/// What `pressUpWith` reads of TranscriptView, as of the call.
export type PressUpDeps = {
  ref: { current: HTMLDivElement | null };
  jumpBack: { current: JumpBack | undefined };
  setJumpBackHeld: (held: boolean) => void;
  following: () => boolean;
  jumpToLatest: (focused: boolean, path?: string) => void;
  placeView: (top: () => number) => void;
  upTopRef: { current: { top: number | undefined; place: ReturnType<typeof jumpUpTarget> } };
  latestLayout: { current: { layout: PlacedLayout; rows: readonly AcpmuxRow[] } };
};

// Jump to latest (the button, ChatGPT and Codex style): a smooth scroll to the latest message, then a
// landing on it, so a reply that grew meanwhile is followed again.
export function jumpToLatestWith(
  {
    ref,
    canLoadNewer,
    onReturnToLatest,
    latestAfterReturn,
    olderScrollTarget,
    revealing,
    revealWindow,
    takeRoom,
    stopBottomStackFold,
    foldAnchor,
    dropFoldRoom,
    requestFollow,
    follow,
    focusComposer,
    latestLayout,
    idle,
    dropJumpBack,
    stopJump,
    rideToLatest,
  }: JumpToLatestDeps,
  focused: boolean,
  path = "jump",
) {
  const node = ref.current;
  if (!node) return;
  // The rows end in history (canLoadNewer): the newest page comes first, then the jump runs to it.
  if (canLoadNewer && onReturnToLatest) {
    latestAfterReturn.current = { focused, path };
    void onReturnToLatest();
    return;
  }
  olderScrollTarget.current = undefined;
  // Jump to latest is the reader leaving the Find match: end its hold, or the next tick pulls the
  // view back to the match and stops following again.
  revealing.current = undefined;
  revealWindow.current = 0;
  // The room the stack grew while scrolled up comes first, out of view, so following again moves
  // nothing and the glide runs to the end above the card instead of snapping there.
  takeRoom();
  stopBottomStackFold();
  foldAnchor.current = undefined;
  dropFoldRoom(true);
  clearScrollOrigin(node);
  // The reader asked for the latest row: following holds through the input hold their fling
  // left, as a send's does (its momentum is held too, momentumHold.ts holdMomentum).
  follow(true, path);
  requestFollow(node);
  if (focused) focusComposer?.();
  // cmux's animations off (ui.animations) or the system's Reduce Motion: it lands in one frame, and
  // with no glide in flight nothing aims one again at a moved end.
  const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  // The layout the room just taken committed (flushSync above), not the one this render closed over.
  const target = Math.max(0, latestLayout.current.layout.totalHeight - node.clientHeight);
  // The reader's own press: Jump up's mark goes and an idle stretch starts at the latest message, so
  // Jump up never comes up just because they pressed this (Leo, 2026-11-12: "after clicking the
  // jump to bottom button, this appears... maybe a bit extra?").
  // Jump up's own way back (Esc after a press) is the press's return, not a new act: the mark stays.
  if (path !== "jump-back") {
    const { layout: placed, rows: shown } = latestLayout.current;
    idle.scrolled(restingAnchor(target + node.clientHeight / 3, false, placed, shown) ?? undefined);
  }
  // At the latest message nothing is left to go back to: a way back a Jump up press held goes, or
  // the button came back at the bottom pointing down at where the reader already is.
  dropJumpBack();
  stopJump();
  rideToLatest(node, target, reduce, true);
}

/// Jump up (jumpUp.ts): to where the reader left off, holding where the view is; pressed again
/// (or Esc), back there. The reader asked for this place, so the view stops following the reply.
/// It glides on Jump to latest's ride (curve, distance duration, move token): a long way skips at
/// once to one viewport from the place, with those rows mounted before the frame paints, and eases
/// the rest, so the view never cuts to a far place in one frame nor draws the rows it crosses.
/// `top` is read each frame: rows that measure on the way move the landing with them. Reduce
/// Motion and motion off still cut.
export function placeViewWith(
  {
    ref,
    revealing,
    revealWindow,
    stopJump,
    unlift,
    scrolledTo,
    follow,
    placing,
    setScrollAt,
    placedTop,
  }: PlaceViewDeps,
  top: () => number,
) {
  const node = ref.current;
  if (!node) return;
  revealing.current = undefined;
  revealWindow.current = 0;
  stopJump();
  unlift();
  scrolledTo.current = { top: node.scrollTop, atLatest: false };
  follow(false);
  const target = () => physicalScrollTop(node, Math.max(0, top()));
  const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  placing.current = true;
  const glideFrom = jumpGlideStart(node.scrollTop, target(), node.clientHeight);
  if (!reduce && glideFrom !== node.scrollTop) {
    node.scrollTop = glideFrom;
    flushSync(() => setScrollAt(node.scrollTop));
  }
  const move = cssTimeMs(
    node.ownerDocument.defaultView?.getComputedStyle(node).getPropertyValue("--agent-motion-move") ?? "",
  );
  const duration = reduce
    ? 0
    : jumpDuration(target() - node.scrollTop) * ((move ?? MOTION_MS.standard) / MOTION_MS.standard);
  animateScroll(
    node,
    target,
    duration,
    JUMP_CURVE,
    () => {
      placing.current = false;
      placedTop.current = node.scrollTop;
      scrolledTo.current = { top: node.scrollTop, atLatest: false };
    },
    () => {
      // The reader's own input took the view mid-glide: from here their scroll is theirs.
      placing.current = false;
    },
    { explicit: true },
  );
}

/// Jump up's press: back along the way a press holds, else to where the reader left off (`placeViewWith`).
export function pressUpWith({
  ref,
  jumpBack,
  setJumpBackHeld,
  following,
  jumpToLatest,
  placeView,
  upTopRef,
  latestLayout,
}: PressUpDeps) {
  const node = ref.current;
  if (!node) return;
  const press = pressJumpUp(jumpBack.current, {
    top: layoutScrollTop(node),
    atLatest: following(),
  });
  if (press.kind === "back") {
    jumpBack.current = undefined;
    setJumpBackHeld(false);
    if (press.back.atLatest) jumpToLatest(false, "jump-back");
    else {
      const back = press.back.top;
      placeView(() => back);
    }
    return;
  }
  const { top, place } = upTopRef.current;
  if (top === undefined || !place) return;
  jumpBack.current = press.back;
  setJumpBackHeld(true);
  // The place pressed for, a third down the view, where its row measures on the way. Held by its
  // row: the target can change under the glide (the New line read as it comes into view), and the
  // view must not turn round to it.
  const hint = { current: -1 };
  placeView(() => {
    const { layout: placed, rows: shown } = latestLayout.current;
    const index = indexOfRow(shown, place.rowId, hint);
    return (index >= 0 ? placed.geometry.topAt(index) + place.offset : top) - node.clientHeight / 3;
  });
}
