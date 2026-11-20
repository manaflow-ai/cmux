// The transcript's scroll state (VirtualTranscript's TranscriptView), in one place: where the reader
// is, what moves the view (a follow, Jump to latest's glide, a held disclosure, a fold at the very
// bottom), the place it reports, and the room it keeps. The refs are made here, before any of the
// transcript's closures, so the React Compiler reads each one as a ref wherever a closure uses it
// (a closure declared above its `useRef` left the transcript uncompiled). The scroll lane's frame
// guard joins them here.
//
// Each ref keeps the timing it had: what an event or a layout pass writes is still written there,
// synchronously. `followingRef` is the reader's intent, written before any React work (the scroll
// handler's `queueScroll`, the pacer), never state and never written in an effect.
import { useCallback, useRef, useState } from "react";
import type { FoldAnchor } from "./conversation/foldAnchor";
import type { FoldRide } from "./conversation/foldRide";
import type { OlderReserve } from "./conversation/olderReserve";
import { geometryFromArrays } from "./conversationGeometry";
import type { TranscriptPlace } from "./jumpUp";
import type { AcpmuxRow, PlacedLayout } from "./model";
import { createScrollPacer, type ScrollFrame } from "./scrollPacer";
import { useCommittedEvent } from "./useCommittedEvent";
import { SCROLL_ANCHOR_SETTLE_MS } from "./virtualTranscriptModel";
import type { ScrollAnchor } from "./VirtualTranscript";

/// A disclosure at the very bottom keeps the bottom pinned while it opens or closes
/// (VirtualTranscript `beginBottomStackFold`).
export type BottomStackFold = {
  toggle: HTMLElement;
  row: HTMLElement;
  beforeTop: number;
  delta: number;
  from: number;
  /// Each drawn row's viewport top at the click.
  drawn: Map<Element, number>;
  /// The toggle adds or removes whole rows (toggleRow), or changes its row with no height fold of
  /// its own (Show all output, Details): the thread slides instead.
  rows?: boolean;
  animation?: Animation;
  /// The line the held rows start at, in the thread's own coordinates.
  line?: number;
  /// The rows that keep their pixels, each sliding against the thread.
  held?: Animation[];
  /// The rows rising with the thread that would cross the line, each cut at it.
  cuts?: Map<HTMLElement, Animation>;
  /// The scroller's offset as the stack last left it (the click, then each of its passes).
  pinned: number;
  cleanupTimer?: ReturnType<typeof setTimeout>;
};

/// The layout before the first commit hands over its own (`latestLayoutRef`): no rows, no height.
const UNPLACED: PlacedLayout = { geometry: geometryFromArrays([], [], 0), totalHeight: 0 };

/// The transcript's scroll refs. `rows`, `sessionId`, `width` and `onAnchor` are read once, as the
/// refs' first values.
export function useTranscriptScroll(first: {
  rows: readonly AcpmuxRow[];
  sessionId: string | undefined;
  width: number;
  onAnchor: ((anchor: ScrollAnchor | null) => void) | undefined;
}) {
  // `scroll` events also fire for layout-driven writes to scrollTop. Keep the user's intent in a
  // ref so those events cannot turn a pinned transcript into a one-frame jump when the composer
  // stack changes height.
  const followingRef = useRef(true);
  /// Where Jump to latest's glide is headed while it is in flight: its steps are the view following,
  /// not the reader's scroll, and nothing snaps it to the end before it arrives.
  const jumpTargetRef = useRef<number | undefined>(undefined);
  /// Where the last scroll left the view, and whether that was at the latest row.
  const scrolledToRef = useRef({ top: 0, atLatest: false });
  /// The disclosure line the reader just clicked, held where they clicked it while its fold plays
  /// (conversation/foldAnchor.ts).
  const foldAnchorRef = useRef<FoldAnchor | undefined>(undefined);
  /// The rows under a disclosure's height fold, moved by translate while only folding rows change
  /// size, and placed by one render when the fold ends (conversation/foldRide.ts).
  const foldRideRef = useRef<FoldRide | undefined>(undefined);
  /// A fold at the very bottom in flight (`BottomStackFold`).
  const bottomStackFoldRef = useRef<BottomStackFold | undefined>(undefined);
  /// Where the reader last saw it rest, measured in view; undefined until it is.
  const seenAnchorRef = useRef<ScrollAnchor | null | undefined>(undefined);
  /// The reader's place when the rows they were reading left the transcript while they were
  /// scrolled up (a reconnect or a rebuild drew a shorter tail, or no rows for a frame): held until
  /// those rows come back, then put back where it was (`heldReaderPlace`). Leo (2026-11-12): "THE
  /// PAGINATION/WHATEVER INFINITE SCROLL UP DOESN'T [...] WORK IT JUST [...] SENDS ME TO THE BOTTOM".
  /// The rows' going clamped the offset to the shorter tail's end, the bottom, and nothing found
  /// the reader's row again. Only the reader's own input, Jump to latest or a send lets it go.
  const heldPlaceRef = useRef<ScrollAnchor | undefined>(undefined);
  /// Where Jump up goes and its top in the layout, as of the last commit (`pressUp` reads it).
  const upTopRef = useRef<{ top: number | undefined; place: TranscriptPlace | undefined }>({
    top: undefined,
    place: undefined,
  });
  /// Where the view rests, once a scroll settles (the latest message is null): the last one
  /// reported, the report's timer, and a report that came due while the pane was hidden.
  const reportedAnchorRef = useRef<string | undefined>(undefined);
  const anchorTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const anchorDeferredRef = useRef(false);
  /// Reports where the view rests with `report` once the scroll settles: SCROLL_ANCHOR_SETTLE_MS on,
  /// unless another call comes first.
  const reportAnchorSoon = useCallback((report: () => void) => {
    clearTimeout(anchorTimerRef.current);
    anchorTimerRef.current = setTimeout(report, SCROLL_ANCHOR_SETTLE_MS);
  }, []);
  /// The anchor sink and the report, as of the last commit.
  const onAnchorRef = useRef(first.onAnchor);
  const reportAnchorRef = useRef<() => void>(() => {});
  /// The layout and rows of the last commit, for the handlers.
  const latestLayoutRef = useRef<{ layout: PlacedLayout; rows: readonly AcpmuxRow[] }>({
    layout: UNPLACED,
    rows: first.rows,
  });
  /// The chat opened at its latest message (or its place): before that its offset is not the reader's.
  const didOpenAtLatestRef = useRef(false);
  /// The layout and rows the last placement pass placed.
  const previousLayoutRef = useRef<PlacedLayout | null>(null);
  const previousRowsRef = useRef<readonly AcpmuxRow[]>(first.rows);
  /// The room kept under the last row as of the last placement pass.
  const heldRoomRef = useRef(0);
  /// The room a followed view keeps for a prompt whose queued card left (VirtualTranscript `floor`).
  const floorRef = useRef({ height: 0, width: first.width, sessionId: first.sessionId, rows: 0 });
  /// The prompts whose cards left, which the room under the last row is kept for (`floorRef`).
  const heldForRef = useRef(new Set<string>());
  /// Where the rows draw against where they lay out (VirtualTranscript `lift`), as of the last commit.
  const liftRef = useRef(0);
  /// Where the warm rows were built from (warmAnchor), held while a fast scroll outruns them.
  const heldWarmAtRef = useRef<string | undefined>(undefined);
  /// The room above the rows for history not loaded yet, and the row it is held against.
  const olderRoomRef = useRef<OlderReserve | undefined>(undefined);
  /// An older page is being asked for.
  const olderAskingRef = useRef(false);
  /// The bottom stack's measures, as of the last commit, for the handlers.
  const dockRef = useRef<HTMLElement | null | undefined>(undefined);
  const dockSpaceRef = useRef(0);
  const dockRoomRef = useRef(0);
  const dockHeightRef = useRef(0);
  const dockCardRef = useRef(0);
  const dockTrayRef = useRef(0);
  /// Ends the bottom stack's fold in flight, and the line it held.
  const stopBottomStackFold = useCallback(() => {
    const stack = bottomStackFoldRef.current;
    if (!stack) return;
    bottomStackFoldRef.current = undefined;
    foldAnchorRef.current = undefined;
    stack.row.removeAttribute("data-bottom-fold");
    stack.row.removeAttribute("data-bottom-stack-fold");
    clearTimeout(stack.cleanupTimer);
    if (stack.animation) {
      stack.animation.onfinish = null;
      stack.animation.oncancel = null;
      stack.animation.cancel();
    }
    for (const held of stack.held ?? []) held.cancel();
    for (const cut of stack.cuts?.values() ?? []) cut.cancel();
  }, []);
  return {
    followingRef,
    jumpTargetRef,
    scrolledToRef,
    foldAnchorRef,
    foldRideRef,
    bottomStackFoldRef,
    stopBottomStackFold,
    seenAnchorRef,
    heldPlaceRef,
    upTopRef,
    reportedAnchorRef,
    anchorTimerRef,
    anchorDeferredRef,
    reportAnchorSoon,
    onAnchorRef,
    reportAnchorRef,
    latestLayoutRef,
    didOpenAtLatestRef,
    previousLayoutRef,
    previousRowsRef,
    heldRoomRef,
    floorRef,
    heldForRef,
    liftRef,
    heldWarmAtRef,
    olderRoomRef,
    olderAskingRef,
    dockRef,
    dockSpaceRef,
    dockRoomRef,
    dockHeightRef,
    dockCardRef,
    dockTrayRef,
  };
}

/// The transcript's scroll pacer (scrollPacer.ts), made once: each frame it lets through runs the
/// last committed render's `onFrame`.
export function useScrollPacer(onFrame: (frame: ScrollFrame) => void): ReturnType<typeof createScrollPacer> {
  const frame = useCommittedEvent(onFrame);
  const [pacer] = useState(() => createScrollPacer(frame));
  return pacer;
}
