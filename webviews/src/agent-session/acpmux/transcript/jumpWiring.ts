import { flushSync } from "react-dom";
import { writeScrollTop } from "../conversation/scrollController";
import { type AcpmuxRow, type PlacedLayout } from "../model";
import { isAgentMotionOff } from "../../shared/motion";
import { MOTION_MS } from "../../../motion/scale.generated";
import { animateScroll } from "../threadMinimap/scrollMotion";
import { JUMP_CURVE, jumpDuration, jumpGlideStart } from "../threadMinimap/model";
import { cssTimeMs } from "../conversation/fold";
import { type FoldAnchor } from "../conversation/foldAnchor";
import { userScrollIntent } from "../conversation/userScroll";
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
  followRequest: { current: (() => boolean) | undefined };
  follow: (next: boolean, path?: string) => void;
  focusComposer: (() => void) | undefined;
  latestLayout: { current: { layout: PlacedLayout; rows: readonly AcpmuxRow[] } };
  stopJump: () => void;
  /// The reader asked for the latest message: what they skipped is theirs to have passed (`caughtUp`).
  reachedLatest: () => void;
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
    followRequest,
    follow,
    focusComposer,
    latestLayout,
    stopJump,
    reachedLatest,
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
  followRequest.current = userScrollIntent(node).request();
  follow(true, path);
  if (focused) focusComposer?.();
  // cmux's animations off (ui.animations) or the system's Reduce Motion: it lands in one frame, and
  // with no glide in flight nothing aims one again at a moved end.
  const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  // The layout the room just taken committed (flushSync above), not the one this render closed over.
  const target = Math.max(0, latestLayout.current.layout.totalHeight - node.clientHeight);
  // The reader's own press: what they skipped on the way is theirs to have passed, so the control
  // never comes back up at the bottom (Leo, 2026-11-12: "it appears again", #42032).
  reachedLatest();
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
    writeScrollTop(node, glideFrom, "glide");
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
