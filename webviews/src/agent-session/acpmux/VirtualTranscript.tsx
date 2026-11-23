import type { PromptHeads } from "./promptHeads";
import { PendingEntrances } from "./conversation/pendingEntrances";
import { TRANSCRIPT_COMPOSER_GAP, gridScale } from "./transcriptGrid";
import React, {
  useCallback,
  useDeferredValue,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  useSyncExternalStore,
  useInsertionEffect,
} from "react";
import { flushSync } from "react-dom";
import { rowPresence, type RowPresenceHints } from "./conversation/rowPresence";
import { LayeredMap } from "./conversation/layeredMap";
import { dockClearSpans, dockClearStops } from "./conversation/dockClear";
import { KeptLayouts } from "./conversation/keptLayouts";
import { isAgentMotionOff } from "../shared/motion";
import { LoadFadeWindow } from "../shared/loadFade";
import { entranceAllowed, pageAway } from "../shared/pageReveal";
import { holdUntilSettled } from "./conversation/unsettledHeights";
import { endOffscreenMotion } from "./conversation/offscreenMotion";
import {
  layoutConversation,
  type PlacedLayout,
  type RowHeights,
  layoutGeometry,
  placedFromEstimate,
  placedWithOrigin,
  placeRowsIndexed,
  transcriptRowWidth,
  mergeRowRanges,
  scrollLeadRanges,
  visibleLayoutRange,
  type AcpmuxRow,
  nextDrawnRow,
  prevDrawnRow,
  finalFooterId,
  keepsReplyRoom,
  statusEdge,
  isLiveLine,
  isLineRow,
  restRoom,
  rowFrameKey,
  SINCE_DIVIDER,
} from "./model";
import { RowFrameCache } from "./conversation/rowFrameCache";
import { railOwnsWheel } from "./threadMinimap/railWheel";
import { animateScroll, MOTION_SCROLL_EVENT, stopScroll, scrollRunning } from "./threadMinimap/scrollMotion";
import { holdMomentum, installMomentumHold } from "./threadMinimap/momentumHold";
import { JUMP_CURVE, jumpDuration, jumpGlideStart } from "./threadMinimap/model";
import { cssTimeMs, foldMotion, foldMs } from "./conversation/fold";
import { drawTranscriptShell } from "./transcript/transcriptShell";
import { useStableCallback } from "./stableCallback";
import { minimapReserve } from "./chatMinimap/paint";
import type { RowsChange } from "./threadMinimap/model";
import { preserveScrollAnchorTop, scrollAnchorBase } from "./conversation/scrollAnchor";
import { useBesideStack } from "./conversation/useBesideStack";
import { attachUserScrollIntent, userScrollIntent } from "./conversation/userScroll";
import {
  clearScrollOrigin,
  layoutScrollTop,
  physicalScrollTop,
  retainScrollOrigin,
  scrollOrigin,
  writeAnchorScrollTop,
} from "./conversation/scrollCoordinates";
import { createFollowGlide, followRoom } from "./conversation/followGlide";
import { createTailGlide, type PlacedRows, type TailGlide } from "./conversation/tailGlide";
import { finishCarry, notePinPass, pinLiveLine, refreshPinned } from "./conversation/pinnedLiveLine";
import {
  createFollowChase,
  type FollowChase,
  ARRIVAL_EASE,
  arrivalStepMs,
  sendMotionMs,
} from "./conversation/followChase";
import { shareFrameBudget, type FrameBudget, rowsMoved } from "./conversation/frameBudget";
import { followMotion } from "./conversation/followMotion.experiment";
import { composerDockMotion } from "./composer/dockMotion.experiment";
import { acpmuxPerf, type MountedSpan } from "./perf";
import { layoutWatchWanted, startLayoutWatch } from "./conversation/layoutWatch";
import { transition, type MotionList } from "./conversation/motionOwner";
import { useCountedRender } from "./perfRender";
import { drewStreamingRow, useStreamingRow } from "./streamingRow";
import { rowsWithLiveOutput } from "./liveToolOutput";
import { followTrace } from "./followTrace";
import { FIELD_GROWTH_EVENT, growthTranslate, type FieldGrowthEvent } from "./composer/fieldGrowthEvent";
import { ScrollPacing } from "./pacing";
import { AdaptiveRenderRate, reportScrollPacing } from "./renderPacing";
import { holdOlderScrollTarget, noteOlderScrollTarget } from "./conversation/olderScrollTarget";
import { noteTranscriptMount } from "./flickerLog";
import { useEndedReplyCheck } from "./conversation/replyJudge";
import { authoritativeScrollIntent, createScrollPacer, type ScrollFrame } from "./scrollPacer";
import { FrameGuard } from "./conversation/frameGuard";
import { STAND_IN_VIEWPORTS, standInRanges } from "./conversation/standIns";
import { useT } from "./i18n";
import { TRAY_GHOST } from "./subagents/trayMotionModel";
import { noteReaderScroll, readerScroll } from "./summary/heldWhileScrolling";
import { keepTabOnScreen } from "../../ui/tabReach";
import { useRowRepositories } from "./conversation/useRowRepositories";
import {
  newReferenceScopeCache,
  referenceScopes,
  turnOpener,
  type ReferenceScope,
  type ReferenceScopeCache,
} from "./conversation/bareReferences";
import { stopReadingAloud } from "./conversation/readAloud";
import { heightFoldInFlight, heightFoldPlaying, settleFoldsIn } from "./conversation/fold";
import { FoldRide, type FoldRideOptions } from "./conversation/foldRide";
import { inputPending } from "./inputPending";
import { fillRef, runThen } from "./heldFlag";
import { useCommittedEvent } from "./useCommittedEvent";
import { useHeldPer } from "./useHeldPer";
import { useRestingDock } from "./useRestingDock";
import { deliberateClick } from "./conversation/useAnchoredCollapse";
import { isRegroupHold } from "./conversation/keepOpenedLineModel";
import {
  ANCHORED_COLLAPSE_EVENT,
  atFoldBottom,
  clickFold,
  FOLD_HOLD_MIN_MS,
  opensBody,
  FOLD_SETTLE_MS,
  foldHoldTarget,
  foldHolding,
  foldRoomFor,
  foldToggleAt,
  holdFold,
  keepFold,
  pushUpCut,
  trimmedFoldRoom,
  verticalWheel,
  type FoldAnchor,
  notePlacement,
} from "./conversation/foldAnchor";
import { settleTurnFold, startTurnFold, watchTurnFold, type TurnFold } from "./conversation/turnFold";
import {
  captureTurnEnd,
  endsTurn,
  playTurnEnd,
  settleTurnEnd,
  TURN_END_ATTR,
  type TurnEndCapture,
  type TurnEndFold,
} from "./conversation/turnEndFold";
import { installGutterSelect, type HeldRow } from "./conversation/gutterSelect";
import {
  clearFindHighlights,
  foldFind,
  findRowIndex,
  findMemberRowId,
  paintFindHighlights,
  type ChatFind,
  rowHolds,
} from "./conversation/chatFind";
import { LIVE_THINKING, THINKING, foldCovers, turnFooterFrom, retryTargetIn } from "./conversation/turns";
import { createLiveLinePulse } from "./conversation/liveLinePulse";
import { installWheelGlide } from "./wheelGlide";
import { installDockWheelHold, installWheelPassThrough } from "./wheelPassThrough";
import { type TranscriptNeedsYou } from "./needsYou/JumpPill";
import { copyTextResult } from "./conversation/clipboard";
import { transcriptRangeText } from "./conversation/transcriptCopy";
import { chatColumnOf, useChatSizing } from "./chatWidth";
import { useChatDisplay } from "./chatDisplay";
import { useComposerSettings } from "./composerSettings";
import { type Folds } from "./conversation/viewFolds";
import { SUBAGENT_OF } from "./subagents/subagentRows";
import { noteSendFromLatest } from "./conversation/sendMorph";
import { sinceDone } from "./conversation/SinceDivider";
import { readUnread, subscribeUnread, unreadPending, noteUnreadNews } from "./conversation/unreadState";
import { sinceNews } from "./conversation/sinceNews";
import {
  jumpUpShown,
  jumpUpTarget,
  lastOwnPrompt,
  placeOffView,
  type JumpBack,
  type PromptScan,
  IdleTracker,
} from "./jumpUp";
import { jumpUpButton } from "./jumpUp.experiment";
import { experimentArm } from "../../experiments/experiment";
import { MOTION_MS, MOTION_SEND_CURVE, MOTION_SEND_MS } from "../../motion/scale.generated";
import { SHOWN_INK_PROPERTIES, followShownScrollerFade } from "../../scrollers";
import { thumbMotion } from "./conversation/thumbMotion.experiment";
import { editableTarget, wheelScrollsDown } from "./conversation/wheelChain";
import { heightLeftAbove, type NewerReserve, newerReserve, rowsReplaced } from "./conversation/newerReserve";
import { OlderAhead } from "./conversation/olderAhead";
import { type OlderReserve, olderReserve } from "./conversation/olderReserve";
import { floorEnd, type HeldRoom, roomUnder } from "./conversation/roomUnder";
import { type ChatOpen, type ChatRows, drawnKey, happenedAfterOpen, openChat } from "./conversation/openBreakpoint";
import { hasPromptTops, keepPromptTops, knownPromptTop } from "./conversation/transcriptHeights";
import { holdWebSwap } from "../../pages/shared/webSwap";
import { playChatSwitch, type ChatSwitchPlay } from "./chatSwitch";
import { chatSwitchMotion } from "./chatSwitch.experiment";
import { callNative } from "./callNative";
import { StreamReveal } from "./streamReveal";
import { type NativeRegistry, type OpenDiff } from "./rows/rowProps";
import { defaultRegistry, readOnlyRegistry } from "./rows/registry";
import { NO_ROWS, rowKind, FOLLOW_BOTTOM_DEADBAND_PX, SCROLL_ANCHOR_SETTLE_MS } from "./virtualTranscriptModel";
import { focusRoute } from "../../ui/focusRoute";
import { continuesLiveResize, LIVE_RESIZE_MS, stepLiveResize } from "./conversation/liveResizeStep";
import { DOCK_NOTICE } from "./noticeSlotModel";
import {
  type DrawnHeight,
  type ReportDrawn,
  type QueueDrawn,
  noQueue,
  drawnHeightOf,
  collapsingRow,
  type DrawnHeights,
} from "./transcript/drawnHeight";
import { OlderRowFade } from "./transcript/OlderRowFade";
import { THREAD_TOP } from "./transcript/RowFrame";
import { type RowFrameSources, drawRowFrames } from "./transcript/rowFrames";
import {
  ARRIVAL_TAIL,
  SENT_PROMPT_ID_LIMIT,
  rememberSentPromptId,
  ARRIVAL_PASS_MS,
  arrivedAtTail,
  TokenRows,
  newestPromptId,
  broughtSentPrompt,
} from "./transcript/arrivals";
import {
  scrollRangeIn,
  scrollRangeInBoxes,
  FIND_REVEAL_MS,
  FIND_REVEAL_FRAMES,
  FIND_REVEAL_STILL_FRAMES,
  FIND_REVEAL_MAX_FRAMES,
  findActiveRange,
  findMatchOffset,
} from "./transcript/findReveal";
import {
  type ScrollAnchor,
  restingAnchor,
  warmAnchor,
  warmAnchorTop,
  heldReaderPlace,
} from "./transcript/scrollAnchors";
import { jumpToLatestWith, placeViewWith, pressUpWith } from "./transcript/jumpWiring";
import { indexOfRow, mountedIndexOf } from "./transcript/rowIndex";
import { type TranscriptReferences, LIST_PROPS, sameList } from "./transcript/references";
import { type LastEstimate, estimateFrom, nearView } from "./transcript/liveEstimate";
export { RowContent } from "./transcript/RowFrame";
export { broughtSentPrompt } from "./transcript/arrivals";
export { heldReaderPlace } from "./transcript/scrollAnchors";
export type { ScrollAnchor } from "./transcript/scrollAnchors";
export { JumpToLatest, JumpUp } from "./transcript/JumpButtons";

/// How soon after the last width step's work finished a new width counts as the same live resize,
/// and how long a width holds before the whole chat is measured at it, come from
/// conversation/liveResizeStep.ts, which owns the rule and its reason (LIVE_RESIZE_MS above).

/// How long the rows hold still before a chat held whole saves its prompts' places (`keepPromptTops`): a
/// stream changes them every frame, and the save reads every row.
const PROMPT_TOPS_QUIET_MS = 1000;
/// The live width steps before the rows flow (`FLOW_CLASS`).
const LIVE_FLOW_STEPS = 2;
/// The thread's class while a live drag flows its rows (conversation.css): the rows sit in normal
/// flow from their placed range, and the browser rewraps them at each width.
const FLOW_CLASS = "acpmux-thread--flow";
/// With FLOW_CLASS while the view follows the latest row: the rows hang from the end of a box that
/// ends where the latest row rests, under a strut as tall as the room above a chat that fits.
const FLOW_END_CLASS = "acpmux-thread--flow-end";
/// The thread's two lengths while its rows flow (conversation.css): in a view that follows, `end` is
/// the box's height and `start` the most its top strut takes; in any other, `start` is the padding
/// above the first mounted row.
const FLOW_VARS = {
  start: "--acpmux-flow-start",
  end: "--acpmux-flow-end",
} as const;
/// A mounted row's gap under it while the rows flow: its margin there (conversation.css). On the
/// row's own element and written by `anchorFlow` alone, so a row gets it only in a drag.
const FLOW_ROW_GAP = "--acpmux-flow-gap";
/// The flow lengths last written on a thread (`writeFlow`): undefined for one that is not set.
type FlowWritten = { node: HTMLElement; start?: string; end?: string };
/// Sets one flow length on `node` (undefined removes it), unless it is the value last written there:
/// a frame of a drag that places the rows as the frame before it did writes no style at all.
function writeFlow(
  live: { wrote?: FlowWritten },
  node: HTMLElement,
  name: keyof typeof FLOW_VARS,
  value: string | undefined,
): void {
  if (live.wrote?.node !== node) live.wrote = { node };
  if (live.wrote[name] === value) return;
  live.wrote[name] = value;
  if (value === undefined) node.style.removeProperty(FLOW_VARS[name]);
  else node.style.setProperty(FLOW_VARS[name], value);
}

/// A store subscription that hears nothing (Jump up off: the unread state is not read).
const NO_SUBSCRIPTION = () => () => {};
/// With Jump up off, the unread view it would read: one constant, so a scroll reads no unread state.
const NO_UNREAD = () => undefined;

/// The last measured transcript box on this page: a transcript mounting again starts from it.
const lastTranscriptBox = { height: 600, width: 760 };

/// Whether any of `rows` is drawn inside the scroller's view (a row that grew there would draw over
/// the rows under it until the transcript places them again). One rect read per row the observer
/// reported, in its callback, where layout is already clean.
function inSight(scroller: HTMLElement | null, rows: readonly HTMLElement[]): boolean {
  if (!scroller || rows.length === 0) return false;
  const view = scroller.getBoundingClientRect();
  return rows.some((row) => {
    const rect = row.getBoundingClientRect();
    return rect.bottom > view.top && rect.top < view.bottom;
  });
}

type TranscriptRange = { anchorId: string; focusId: string };

/// The longest a chat opened cold takes to fade in (Leo 2026-10-21: "a fast fade in").
const CHAT_OPEN_FADE_MS = 150; // motion-allow: a ceiling on the host's fade-in token (micro, 120 ms), not a duration of its own

/// Fades the transcript of a chat this page opened cold in over the host's fade-in token (the
/// motion scale's micro step without the host), at most CHAT_OPEN_FADE_MS: opacity only, so no row
/// moves, starting on the frame its rows first draw. None when the host turned motion off or its
/// token is 0 (Reduce Motion, ui.animationSpeed off), or while the page is away (entranceAllowed).
function fadeInOpenedChat(node: HTMLElement | null): Animation | undefined {
  if (!node || typeof node.animate !== "function" || !entranceAllowed()) return undefined;
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return undefined;
  const style = getComputedStyle(document.documentElement);
  const token = style.getPropertyValue("--agent-motion-in").trim();
  const value = Number.parseFloat(token);
  const asked = !token || !Number.isFinite(value) ? MOTION_MS.micro : token.endsWith("ms") ? value : value * 1000;
  const duration = Math.min(asked, CHAT_OPEN_FADE_MS);
  if (!(duration > 0)) return undefined;
  return node.animate([{ opacity: 0 }, { opacity: 1 }], {
    duration,
    easing: style.getPropertyValue("--agent-ease-out").trim() || "ease-out",
  });
}

/// Whether `entry` is the height already kept for its row. Heights compare exactly: a fold's last
/// frame draws its row a fraction of a pixel short of the height it settles at (145.72px, then
/// 146px), and with any slack the row kept the frame's height, so every row below it sat that
/// fraction too high, over the row above. A height that did not change still compares equal, so
/// it renders nothing.
function sameDrawn(old: DrawnHeight | undefined, entry: DrawnHeight): boolean {
  return (
    old !== undefined &&
    old.sessionId === entry.sessionId &&
    old.version === entry.version &&
    old.width === entry.width &&
    old.height === entry.height &&
    Boolean(old.actions) === Boolean(entry.actions) &&
    old.status === entry.status &&
    Boolean(old.collapsing) === Boolean(entry.collapsing)
  );
}

/// Whether `updates` change any drawn height in `current`.
function changesDrawn(current: DrawnHeights, updates: Map<string, DrawnHeight>): boolean {
  for (const [id, entry] of updates) if (!sameDrawn(current.get(id), entry)) return true;
  return false;
}

/// Where a scroller sits, read while its content still matches `totalHeight`.
const scrollPosition = (node: HTMLElement, totalHeight: number) => ({
  top: node.scrollTop,
  atLatest: layoutScrollTop(node) >= totalHeight - node.clientHeight - FOLLOW_BOTTOM_DEADBAND_PX,
});

/// End or Cmd-Down, without Shift (Shift-End extends a row range): the keys that go to the end.
function toLatestKey(event: Pick<KeyboardEvent, "key" | "metaKey" | "shiftKey">): boolean {
  return !event.shiftKey && (event.key === "End" || (event.metaKey && event.key === "ArrowDown"));
}

/// Whether reader input moves the transcript toward its latest row: a wheel down or a key that
/// scrolls down. Such input never leaves the latest row, so follow-bottom need not wait for it.
function movingDown(event?: Event): boolean {
  if (event?.type === "wheel") return (event as WheelEvent).deltaY > 0;
  if (event?.type === "keydown")
    return ["ArrowDown", "PageDown", "End", " ", "Spacebar"].includes((event as KeyboardEvent).key);
  return false;
}

/// Holds the rows under what a bottom fold opened where they were drawn, against the thread's slide,
/// and cuts each row rising with it at the line they hold (`pushUpCut`). On the thread animation's
/// timing, so the text above moves and nothing under the opened line does. The first call runs
/// before the thread's slide starts, when the boxes read their settled places: a row is held when
/// its top did not rise with the stack since the click. Later calls (a late measure changed
/// `stack.from`) update the same effects, and start a cut a row now needs at the slide's `time`.
function holdUnderStack(
  host: HTMLElement,
  stack: {
    from: number;
    drawn: Map<Element, number>;
    line?: number;
    held?: Animation[];
    cuts?: Map<HTMLElement, Animation>;
  },
  timing: EffectTiming,
  time: CSSNumberish | null = 0,
): void {
  const hold = [{ translate: `0 ${-stack.from}px` }, { translate: "0 0" }];
  const hostTop = host.getBoundingClientRect().top;
  const rows = [...host.children] as HTMLElement[];
  if (stack.line === undefined) {
    const still = rows.filter((each) => {
      const was = stack.drawn.get(each);
      // Opening moves the rows above up (`from` > 0), closing moves them down (`from` < 0): the rows
      // that kept their place either way are the ones under the line.
      return was !== undefined && Math.abs(was - each.getBoundingClientRect().top) < Math.abs(stack.from) / 2;
    });
    stack.line = still.length
      ? Math.min(...still.map((each) => each.getBoundingClientRect().top - hostTop))
      : Math.max(0, ...rows.map((each) => each.getBoundingClientRect().bottom - hostTop));
    stack.held = still.map((each) => each.animate(hold, { ...timing, composite: "add" }));
    stack.cuts = new Map();
  } else for (const held of stack.held ?? []) (held.effect as KeyframeEffect).setKeyframes(hold);
  const heldRows = new Set(stack.held?.map((held) => (held.effect as KeyframeEffect).target));
  for (const each of rows) {
    if (heldRows.has(each)) continue;
    // A row rising with the thread moves as one with it, so its box reads its settled place there.
    const frames = pushUpCut(each.getBoundingClientRect().bottom - hostTop - stack.line, stack.from);
    const cut = stack.cuts?.get(each);
    if (cut) (cut.effect as KeyframeEffect).setKeyframes(frames);
    else if (frames.length) {
      const animation = each.animate(frames, timing);
      animation.currentTime = time;
      stack.cuts?.set(each, animation);
    }
  }
}

/// Puts a following view at the latest row. Anything past the browser's rounding is corrected: the
/// stack's eased growth (the queue's max-height move, #24718) comes in steps under
/// `FOLLOW_BOTTOM_DEADBAND_PX`, and a deadband here left the view resting up to that far from its end,
/// the last row under the stack. A fractional end is rounded up: WebKit floors a fractional offset
/// while it rounds the content's height, so the end as written rested a pixel short of the
/// scroller's own; past it, the browser clamps the offset to that end.
/// Returns whether it moved, and the physical offset it left the scroller at: every read is before
/// its style write, and the caller takes the offset from here, never from the scroller after this
/// pass wrote to the page (each such read lays the page out again, per streamed token).
function settleFollowBottomAt(node: HTMLElement, latest: number): { moved: boolean; top: number } {
  const end = Math.ceil(latest - 0.01);
  const current = node.scrollTop;
  // Where the write lands: a scroller already clamped there is at its end.
  const lands = Math.min(end, Math.max(0, node.scrollHeight - node.clientHeight));
  const moved = Math.abs(lands - current) > 0.5;
  if (moved) node.scrollTop = end;
  // Where the browser put it, read right after the scroll write and before the origin's style write
  // below: a scroll write leaves the page laid out, so this read lays nothing out again.
  const top = moved ? node.scrollTop : current;
  // Measurements above the view can move the logical end by half a pixel while the physical
  // end stays rounded. Keep that fraction even when the browser already clamped to the end,
  // so releasing follow before the next wheel does not inherit a half-pixel row jump.
  retainScrollOrigin(node, latest);
  return { moved, top };
}

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
const SCROLL_LEAD_STEPS = 2;

/// Once a fling stops, keep its lead only briefly. A stale direction keeps rows mounted far ahead
/// of the reader and makes every later render pay for a scroll that already ended.
// motion-allow: a scroll idle timeout, not a motion
const SCROLL_LEAD_IDLE_MS = 120;

/// How long the frame guard (VirtualTranscript `armFrameGuard`) keeps reading the offset each frame after
/// it last moved: a fling's frames and the pauses between a trackpad's flicks.
const SCROLL_GUARD_IDLE_MS = 250;

/// More new rows than this in one update are a load (a session switch, older history), not live rows.
const LIVE_ROWS_PER_UPDATE = 3;

/// A sent prompt the view keeps at its top while its turn fills the room under it (`sendTopEnd`).
export type SendTop = { id: string; index: number };

/// The index of a prompt that this update brought at the tail (a new user row that is no line), or -1.
/// A load (more than LIVE_ROWS_PER_UPDATE new rows, a first pass) brings none. O(1): the rows past the
/// old tail, and the old tail's last two (an optimistic prompt replaced by its canonical row).
export function sentPromptAt(before: readonly AcpmuxRow[], after: readonly AcpmuxRow[]): number {
  if (before.length === 0 || after.length - before.length > LIVE_ROWS_PER_UPDATE) return -1;
  for (let index = after.length - 1; index >= Math.max(0, before.length - 2); index -= 1) {
    const row = after[index]!;
    if (row.kind === "user" && !isLineRow(row) && row.id !== before[index]?.id) return index;
  }
  return -1;
}

/// The content end that rests a followed view with `sent` at its top: the prompt's row starts the
/// thread's top padding under the view's top, and the view's height reaches past it. 0 once the row
/// is gone. O(1) while the row keeps its index; else one walk back from the tail to find it again.
export function sendTopEndOf(
  sent: SendTop | undefined,
  rows: readonly AcpmuxRow[],
  placed: PlacedLayout,
  topInset: number,
  height: number,
): number {
  if (!sent || height <= 0) return 0;
  const at = rows[sent.index];
  // The optimistic prompt replaced in place by its canonical row (a new id, the same place) is the same prompt.
  if (at && at.id !== sent.id && sent.id.startsWith("local-") && at.kind === "user" && !isLineRow(at)) sent.id = at.id;
  if (rows[sent.index]?.id !== sent.id) {
    let found = -1;
    for (let index = rows.length - 1; index >= 0 && found < 0; index -= 1)
      if (rows[index]!.id === sent.id) found = index;
    if (found < 0) return 0;
    sent.index = found;
  }
  if (sent.index >= layoutGeometry(placed).count) return 0;
  return layoutGeometry(placed).topAt(sent.index) + topInset + height;
}

/// The prompt sent from the latest row that the view keeps at its top, and the content end that holds
/// it there as of the last render (`end`, 0: none). One per transcript (its `useState`), so render
/// reads and writes no ref; the effects and the scroll handler read `end`. O(1) a pass but for
/// `sendTopEndOf`'s walk back.
export class SendTopHold {
  private sent: SendTop | undefined;
  end = 0;

  /// The pass's held content end: takes a prompt `sentIds` holds that this pass brought at the tail
  /// (against the last committed rows, `placedRows`), lets it go when the view stops following, the
  /// chat changes or the rows outgrow the held view (`rowsHeight` past its end).
  update(
    hold: boolean,
    openedAtLatest: boolean,
    placedRows: readonly AcpmuxRow[],
    rows: readonly AcpmuxRow[],
    sentIds: ReadonlySet<string>,
    placed: PlacedLayout,
    topInset: number,
    height: number,
    rowsHeight: number,
  ): number {
    if (!hold) this.sent = undefined;
    else if (openedAtLatest && rows !== placedRows) {
      const sent = sentPromptAt(placedRows, rows);
      if (sent >= 0 && sentIds.has(rows[sent]!.id)) this.sent = { id: rows[sent]!.id, index: sent };
    }
    let end = sendTopEndOf(this.sent, rows, placed, topInset, height);
    if (end < rowsHeight) end = 0;
    if (end === 0) this.sent = undefined;
    this.end = end;
    return end;
  }
}
/// How recent an empty chat's first prompt is when its transcript mounts for it to enter (above).
const FIRST_SEND_FRESH_MS = 2000;

/// Viewports from the top of the loaded rows within which a page of older history came late: the
/// reader reached rows that were not loaded yet, so the page fades in. Pages ask well ahead
/// (OLDER_AHEAD_VIEWPORTS), so a page normally lands farther away and draws in place.
const OLDER_LATE_VIEWPORTS = 1;
/// Loaded rows at least this many views tall keep the older-history room while the reader waits at
/// their top (`giveRoomNearTop`); a shorter tail gives it up, so a scroll up is never pushed back down.
const OLDER_KEEP_ROOM_VIEWPORTS = 3;

/// Whether the reader's view is at the top of the loaded rows, read before a page lands above them.
/// A hidden or unplaced scroller draws in place (WebKit would play a hidden page's fade on return).
/// `room` is the space held above the loaded rows (ConversationLayout.origin).
function readerAtLoadedTop(node: HTMLElement | null, room: number): boolean {
  if (!node || node.clientHeight === 0) return false;
  return node.scrollTop - scrollOrigin(node) - room < node.clientHeight * OLDER_LATE_VIEWPORTS;
}

/// How far around the last mounted range a row whose drawn height changed is looked for; farther
/// (a jump), the whole transcript is placed again.
const DRAWN_SEARCH_ROWS = 64;

const MAX_SCROLL_LEAD_VIEWPORTS = 4;

/// Viewports of just-passed rows kept mounted behind a moving scroll (scrollLeadRanges `trail`), so a
/// quick reversal finds them drawn.
const SCROLL_TRAIL_VIEWPORTS = 1;

/// Viewports of rows kept mounted either side of the reader, built between frames.
const WARM_VIEWPORTS = 1;

/// Viewports of history mounted above the reader, in the commit that draws the view: a chat opens
/// with rows to scroll up into already drawn, and the warm rows keep that much above while the reader
/// scrolls (Leo, 2026-11-12: "if you try to scroll up, you can't really scroll much of anything up at
/// all. Like it doesn't load enough"). Rows the transcript already holds only; older pages still come
/// by OLDER_AHEAD_VIEWPORTS. Above the view, so a followed view's end anchors them: their heights
/// land in the offset in the frame they are measured and no visible row moves.
const HISTORY_VIEWPORTS = 4;

/// How far the reader scrolls, in viewports, before the warm rows move with them.
const WARM_STEP_VIEWPORTS = 0.5;

/// How far above the latest message the reader is before Jump to latest shows.
const JUMP_LATEST_DISTANCE = 80;

/// How long a scroll event can be attributed to the reader's most recent input. Expiring this
/// window never changes the reader's follow choice; it only distinguishes subsequent events.
const READER_SCROLL_MS = 1000;

/// How far a followed view's offset must rise, with no input seen yet, to be the reader's own scroll.
/// WebKit itself moves a followed offset a pixel or two above the latest line as a reply grows
/// (cx-02st5, agent-pane-follow-live), so a rise inside the follow deadband stays layout work.
const UNSEEN_READER_MOVE_PX = FOLLOW_BOTTOM_DEADBAND_PX;

/// How long a followed view keeps the room a queued prompt's card left, for the prompt to arrive.
const FLOOR_HOLD_MS = 1000;

/// How long after a send from the latest row the rows that come still rise on its glide: the prompt's
/// own row and its reply's first rows (acpmux's echo, the live line) land within it.
const SEND_RISE_MS = 1000;

/// A send's clock on `node` (`--agent-motion-send`, the scale's send step scaled by the host's speed).
/// The product's is 0 (Leo, 2026-11-11: "that slow settle animation is just so bad. Like, just do
/// it."): then the send's rows and the room the composer gives back move at once, never on the chase.
const sendClockMs = (node: HTMLElement) =>
  cssTimeMs(node.ownerDocument.defaultView?.getComputedStyle(node).getPropertyValue("--agent-motion-send") ?? "") ??
  MOTION_SEND_MS;

/// How far (px, under a line) a followed reply's new text may lie under the bottom stack while the
/// follow motion catches up with it (followChase.ts), past the room the live line keeps.
const CHASE_UNDER_STACK_PX = 20;

/// How long it keeps the room a withdrawn prompt's card left after the reply last grew: a reply
/// streaming fills it, and a turn in a tool call or thinking brings nothing to fill it with.
const WITHDRAWN_HOLD_MS = 250;

/// How soon the transcript asks again for an older page after an ask that brought nothing.
const OLDER_RECHECK_MS = 500;

/// How near the first loaded row, in viewports, the view asks for the next older page: far enough
/// ahead that a page read from acpmux lands before a fast scroll up reaches the top (two viewports
/// was a fraction of a second of a flick). The least of it: a reader scrolling up fast asks as far
/// ahead as their speed covers in a page's read (conversation/olderAhead.ts).
const OLDER_AHEAD_VIEWPORTS = 6;

export type VirtualTranscriptProps = Omit<React.ComponentProps<typeof TranscriptView>, "references">;

/// The bare `#N` scopes of `source` (referenceScopes), kept as the last value while every scope
/// it gives is the one it gave: the same reading of every row before the last (the cache kept its
/// prefix and evidence) and the same scope for the last row's turn.
function useTranscriptReferences(source: readonly AcpmuxRow[]): TranscriptReferences {
  const cache = useRef<ReferenceScopeCache>(undefined as unknown as ReferenceScopeCache);
  cache.current ??= newReferenceScopeCache();
  const held = useRef<
    | {
        source: readonly AcpmuxRow[];
        value: TranscriptReferences;
        lastTurn?: string;
        lastScope?: ReferenceScope;
      }
    | undefined
  >(undefined);
  const before = held.current;
  if (before?.source === source) return before.value;
  const kept = cache.current;
  const { generation, prefixLength, evidence } = kept;
  const scopeOf = referenceScopes(source, kept);
  const lastId = source.at(-1)?.id;
  const lastTurn = lastId === undefined ? undefined : kept.rowTurn.get(lastId);
  const lastScope = lastTurn === undefined ? undefined : scopeOf(lastTurn);
  const same =
    before !== undefined &&
    generation === kept.generation &&
    prefixLength === kept.prefixLength &&
    evidence === kept.evidence &&
    before.lastTurn === lastTurn &&
    before.lastScope === lastScope;
  const value = same ? before.value : { cache: kept, scopeOf };
  held.current = { source, value, lastTurn, lastScope };
  return value;
}

/// The transcript, drawn again only when what it is handed changes. The pane renders on every
/// snapshot, a running command's output update too (its rows feed the header's Preview, Session
/// Info and the sends), and handed the transcript new callbacks and new lists of the same rows
/// each time, so the whole transcript rendered once per update with nothing in it changed
/// (bench/delta-renders.bench.ts: 1.07 renders per output update at 75, 750 and 7,500 rows).
/// Here a callback prop is a stable function that calls the pane's newest one (its presence still
/// counts), a list of the same rows is the list drawn before, and the client's rows (`sourceRows`,
/// read only for bare `#N` scopes) reach the transcript as their scopes, which change only when
/// the rows name something new. A streamed reply's text still reaches its row through
/// streamingRow.ts without the pane.
export function VirtualTranscript(props: VirtualTranscriptProps) {
  // The newest props, for the stable callbacks below: written as the pane renders, so a callback
  // the transcript runs in its own layout effects already calls this render's function.
  const latest = useRef(props);
  latest.current = props;
  const calls = useRef(new Map<string, (...args: unknown[]) => unknown>());
  const lists = useRef(new Map<string, readonly unknown[]>());
  const stable: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(props)) {
    if (typeof value === "function") {
      let call = calls.current.get(key);
      if (!call) {
        call = (...args: unknown[]) =>
          (latest.current as unknown as Record<string, ((...args: unknown[]) => unknown) | undefined>)[key]?.(...args);
        calls.current.set(key, call);
      }
      stable[key] = call;
    } else if (Array.isArray(value) && LIST_PROPS.has(key)) {
      const before = lists.current.get(key);
      const kept = before && sameList(before, value) ? before : value;
      lists.current.set(key, kept);
      stable[key] = kept;
    } else stable[key] = value;
  }
  const source = (stable.sourceRows ?? stable.rows) as readonly AcpmuxRow[];
  delete stable.sourceRows;
  const references = useTranscriptReferences(source);
  return <TranscriptViewMemo {...(stable as VirtualTranscriptProps)} references={references} />;
}

/// The layouts of the chats this page's transcripts showed (conversation/keptLayouts.ts).
const keptLayouts = new KeptLayouts<DrawnHeights, AcpmuxRow>();

function TranscriptView({
  rows: paneRows,
  streams = false,
  earlier,
  promptCount,
  loadThrough,
  loadPromptIndex,
  sessionId,
  onToggleActivity,
  onOpenDiff,
  expanded,
  registry: givenRegistry,
  readOnly = false,
  canLoadOlder = false,
  historyFrom,
  canLoadNewer = false,
  historyThrough,
  later,
  onLoadNewer,
  onReturnToLatest,
  githubRepository,
  fallbackRepository,
  references,
  find,
  reveal,
  working = false,
  jumpButton = false,
  needsYou,
  dock,
  queueWithdrawn,
  queueIds,
  queuedTail,
  focusComposer,
  openAt,
  onAnchor,
  anchorNow,
  inViewNow,
  heldWorkedClosing,
  onLoadOlder,
  sends = 0,
  onFollowingChange,
  onKeepFrom,
  onJumpShownChange,
  coldOpen,
  onColdOpenShown,
  loading = false,
  clockOffset = 0,
  afterLatest,
  sinceKey,
  promptAuthor,
  onJumpToSince,
  showMinimap = true,
  endReserve: cardReserve = 0,
  minimapBeside = false,
  topInset = 0,
}: {
  rows: readonly AcpmuxRow[];
  /// The pane's live transcript: it draws the streaming reply's row ahead of the pane's snapshot
  /// (streamingRow.ts), so a streamed chunk re-renders this transcript and that row, not the pane.
  streams?: boolean;
  /// The chat's prompts older than `rows` (the snapshot's `earlierPrompts`): the thread rail lays
  /// them out from the first frame, so it never grows or shifts as history pages in.
  earlier?: PromptHeads;
  /// The chat's prompt count while it does not hold every prompt yet (the snapshot's `promptCount`):
  /// the rail starts at the height that many prompts take, with the held ones at their final rows.
  promptCount?: number;
  /// Pages history in until the prompt at `seq` is held (a click on an earlier prompt's tick).
  loadThrough?: (seq: number) => Promise<boolean>;
  /// Asks for the chat's prompt index (a hover or click on a pending tick): true once it named them.
  loadPromptIndex?: () => Promise<boolean>;
  sessionId?: string;
  /// Where the transcript opens instead of the latest message, when that row is loaded.
  openAt?: ScrollAnchor;
  /// Where it rests after each settled scroll (null at the latest message).
  onAnchor?: (anchor: ScrollAnchor | null) => void;
  /// Filled with where it last rested in view (null at the latest message, undefined when it was
  /// never in view), for a page about to let go.
  anchorNow?: React.MutableRefObject<(() => ScrollAnchor | null | undefined) | undefined>;
  /// Filled with the ids of the rows in the reader's view now, or null while it follows the latest
  /// message (a turn's end keeps those rows open, conversation/turnEndHold.ts).
  inViewNow?: React.MutableRefObject<(() => readonly string[] | null) | undefined>;
  /// Set by the pane when the rows it hands over next close a turn's Worked for that was held open
  /// while the reader was scrolled up (App.tsx `heldWorked`), the reader now back at the latest row.
  /// That close folds in the turn's end motion (conversation/turnEndFold.ts). Only read here: the
  /// pane lets the flag go once the render that reads it has committed.
  heldWorkedClosing?: React.MutableRefObject<boolean>;
  /// A reply is streaming: Jump to latest remains static while the shared transcript spinner carries
  /// the working state.
  working?: boolean;
  /// Draw Jump to latest: the chat's own stage only, which positions it above the composer.
  jumpButton?: boolean;
  /// Open asks: Jump to latest becomes the Needs your input pill (needsYou/JumpPill.tsx).
  needsYou?: TranscriptNeedsYou;
  /// The chat's bottom stack, laid over the transcript's foot (bottomStack.css): the view runs under
  /// it, the scrollbar's track to the pane's bottom as in the Claude and Codex apps, and its end sits
  /// above it. Its height is room under the last row, followed as it changes before the frame paints.
  dock?: HTMLElement | null;
  /// Prompts withdrawn from the queue (snapshot `queueWithdrawn`): no row comes for one whose card
  /// leaves the stack, so the view keeps no room for it.
  queueWithdrawn?: readonly string[];
  /// IDs from the queue snapshot: a folded prompt has no card in the DOM, but remains queued and
  /// must not be recorded as withdrawn when the fold changes.
  queueIds?: readonly string[];
  /// The waiting agent messages at the rows' end (conversation/queuedMessages.ts), one array while
  /// the queue holds them.
  queuedTail?: readonly AcpmuxRow[];
  /// Where a keyboard Jump to latest leaves focus, since the button hides (inert) once there.
  focusComposer?: () => void;
  /// `covers`: the clicked line's other keys (turns.ts `foldCovers`), toggled with it.
  onToggleActivity: (id: string, covers?: readonly string[]) => void;
  onOpenDiff?: OpenDiff;
  expanded: Folds;
  registry?: NativeRegistry;
  canLoadOlder?: boolean;
  /// The oldest event seq held (AcpmuxSnapshot.historyFrom): a read that drew no row still moves it.
  historyFrom?: number;
  /// Pages older history in (canLoadOlder): asked once per loaded page while the view is near the top.
  /// `fill`: the loaded rows do not reach the view's top, so the first page that draws above them lands
  /// at once rather than with the pages read after it.
  /// `rising`: the reader is scrolling up as it asks (OlderAhead), so the page is a big one, with more read ahead.
  onLoadOlder?: (fill: boolean, rising: boolean) => Promise<void>;
  /// The chat goes on past the rows (AcpmuxSnapshot.canLoadNewer): a reader scrolled far up holds a window of it.
  /// The rows that left are room under the last row (conversation/newerReserve.ts), and the view is never at the
  /// latest message there.
  canLoadNewer?: boolean;
  /// The newest event seq held while `canLoadNewer` (AcpmuxSnapshot.historyThrough): a read that drew no row still
  /// moves it.
  historyThrough?: number;
  /// The chat's prompts newer than `rows` while `canLoadNewer` (the snapshot's `laterPrompts`): the rail keeps
  /// their ticks after the held ones.
  later?: PromptHeads;
  /// Reads the next newer page (canLoadNewer): asked once per page while the view is near the rows' end.
  onLoadNewer?: () => Promise<void>;
  /// The reader goes to the latest message while `canLoadNewer` (Jump to latest, End, a send): the pane reads the
  /// chat's newest page in place of the window.
  onReturnToLatest?: () => Promise<void>;
  /// How many prompts this pane has sent: each new one puts the view at the latest message.
  sends?: number;
  /// Keeps the parent send path in sync with the reader's current follow state.
  onFollowingChange?: (following: boolean) => void;
  /// The oldest row the view draws while it follows the latest row, else null: the client lets go of no held record
  /// above it (direct.ts `setKeepFrom`).
  onKeepFrom?: (rowId: string | null, at?: number) => void;
  /// Jump to latest (or the Needs your input pill) shows or hides: the pane lifts its bottom toast
  /// deck above it while it shows (toastLayer.css). Told `false` when the transcript goes.
  onJumpShownChange?: (shown: boolean) => void;
  githubRepository?: string;
  /// The repository a bare `#N` means when `githubRepository` is unknown and the transcript names
  /// none before it (the header pull request's).
  fallbackRepository?: string;
  /// The client's rows, which still hold the work a closed "Worked for" folds away: where a bare
  /// `#N`'s repository is looked for (conversation/bareReferences.ts). Else `rows`.
  sourceRows?: readonly AcpmuxRow[];
  /// The bare `#N` scopes of `sourceRows` (VirtualTranscript's `useTranscriptReferences`).
  references: TranscriptReferences;
  /// Find in Chat (chatFind.ts): its bar, the query to highlight and the match to bring into view.
  find?: ChatFind;
  /// A row to bring into view (a count on the running line, WorkingFor.tsx); a new `key` asks again.
  /// The run that holds call `toolId` opens, as for a Find match.
  reveal?: { rowId: string; key: number; toolId: string };
  /// A chat the page switched to and read cold, by its open (a new number per open), whose rows
  /// have not shown yet: they fade in once, on the frame they first draw (fadeInOpenedChat).
  /// Undefined for a chat drawn from a kept tail, which shows whole on the frame the switch lands
  /// ("instant if cached"), for the first chat a page shows, which the host reveals
  /// (pane.painted), and once the open's rows have shown.
  coldOpen?: number;
  /// The chat's rows are still being read (the pane's `chatRead` is not in yet). Rows that arrive
  /// while it is, or just after it lands, after a first paint that was blank or partly blank, fade in
  /// once on their first mount (shared/loadFade.ts) instead of popping in. Rows drawn at the first
  /// paint, rows a scroll mounts and rows already on screen never fade.
  loading?: boolean;
  /// How far this computer's clock is ahead of the agent host's (the snapshot's `clockOffsetMs`):
  /// a row's time is the host's, and the open's breakpoint is this computer's (openBreakpoint.ts).
  clockOffset?: number;
  /// The rows of open `coldOpen` have shown. The pane keeps that, not this transcript, so a
  /// transcript mounted again (back from New Tab or a replay) does not fade the same open twice.
  onColdOpenShown?: (open: number) => void;
  /// Optional content placed immediately after the latest message, outside the scroller.
  afterLatest?: React.ReactNode;
  /// The key of "New since you looked" in these rows, if any: Jump to new shows over the top while
  /// it is out of view (conversation/SinceDivider.tsx), and `onJumpToSince` brings it in.
  sinceKey?: string;
  /// The author id this pane sends as (multiplayer/presenceClient.ts `selfId`): Jump up's "sent"
  /// mark is this author's newest prompt, never another person's in a shared chat (jumpUp.ts).
  promptAuthor?: string;
  onJumpToSince?: () => void;
  /// The focused chat's palette action can hide this pane's rail without changing the configured
  /// minimap experiment or any other pane's layout.
  showMinimap?: boolean;
  /// Drawn for a reader who may not act (a shared chat's guest, conversation/readOnly.ts): the rows
  /// come from `readOnlyRegistry` unless a registry is given, and no row draws an owner's control.
  readOnly?: boolean;
  /// Room the column keeps at its right for the computer use live preview (`--cv-inset-end`,
  /// computerUse/computerUsePreview.ts): rows are laid out that much narrower.
  endReserve?: number;
  /// The VS Code Minimap is on beside this transcript (App.tsx data-vscode-minimap): the column's end
  /// also keeps its room, in a chat wide enough (chatMinimap/paint.ts minimapReserve).
  minimapBeside?: boolean;
  /// CSS pixels of the scroller's top that the pane's tab row floats over (a one-tab pane, header/tabRow.ts
  /// `soloTab`): the scroller runs up under the row, and the rows draw this much lower and the content is
  /// this much taller, so the first row rests where it did below the row and the latest one where it did
  /// above the composer. 0 for a scroller below its header.
  topInset?: number;
}) {
  // Debug measurement (acpmuxPerf): the transcript's committed renders (perf.ts `renders`); tests
  // count them per key and per line (test/composer-smooth-grow.test.ts).
  useCountedRender("transcript");
  // The streaming reply's newer text, when the pane has not redrawn for it (streamingRow.ts): that
  // row only, in place, with its version moved on by the chunks it is ahead.
  const live = useStreamingRow(streams);
  const rows = useMemo(() => {
    if (!streams || !live) return paneRows;
    for (let index = paneRows.length - 1; index >= 0; index -= 1) {
      const row = paneRows[index]!;
      if (row.id !== live.row.id) continue;
      if (row.text !== live.drawnText) return paneRows;
      const next = paneRows.slice();
      const version = row.version + live.ahead;
      next[index] = { ...row, text: live.row.text, version };
      // The live line under the reply stays quiet while the reply's text moves (turns.ts
      // `quietKey` names the reply's id and version): it moves with the newer version here.
      const stale = `${row.id}:${row.version}`;
      for (let below = index + 1; below < next.length; below += 1) {
        const line = next[below]!;
        if (line.kind === THINKING && line.quietKey === stale)
          next[below] = {
            ...line,
            quietKey: `${row.id}:${version}`,
            version: line.version + live.ahead,
          };
      }
      return next;
    }
    return paneRows;
  }, [paneRows, live, streams]);
  // The live line hears each pass's chunk and event here; its frame draws only when what it shows
  // changes (conversation/liveLinePulse.ts). After the line's own effects, so a line mounted in this
  // pass already listens.
  const [livePulse] = useState(createLiveLinePulse);
  useLayoutEffect(() => livePulse.note(rows), [livePulse, rows]);
  // What this transcript drew of the pane's streaming reply: the pane takes the fast path only
  // while that row is drawn as the client holds it.
  useLayoutEffect(() => {
    if (!streams) return;
    for (let index = paneRows.length - 1; index >= 0; index -= 1) {
      const row = paneRows[index]!;
      if (row.kind === "assistant" && row.streaming) {
        drewStreamingRow(row.id, row.text);
        return;
      }
      if (row.kind === "user") break;
    }
    drewStreamingRow(undefined, undefined);
  }, [paneRows, streams]);
  const registry = givenRegistry ?? (readOnly ? readOnlyRegistry : defaultRegistry);
  const t = useT();
  // Debug measurement (acpmuxPerf): off until the first debug call.
  const renderStart = acpmuxPerf.enabled ? performance.now() : 0;
  acpmuxPerf.span("vt.renders", 1);
  const scrollRef = useRef({ top: 0, delta: 0 });
  /// Where the warm rows were built from (warmAnchor), held while a fast scroll outruns them (below).
  const heldWarmAt = useRef<string | undefined>(undefined);
  const scrollLeadTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  /// The frame guard (conversation/frameGuard.ts, `armFrameGuard` below) and the offset it last read and
  /// the one it handled. Made in the first render (one guard for the transcript's life), before the rows'
  /// observer (`observer` below), so its read runs first in a frame's ResizeObserver callbacks. Its read,
  /// frame and node, which read refs, are given as the transcript mounts (`connect`, below): until then
  /// they did nothing (`transcriptMounted`).
  const guardRead = useRef<() => void>(() => {});
  const frameGuard = useRef<{ seen: number | undefined; handled: number | undefined }>({
    seen: undefined,
    handled: undefined,
  });
  const [guard] = useState(
    () =>
      new FrameGuard({
        read: () => {},
        node: () => null,
        idleMs: SCROLL_GUARD_IDLE_MS,
        observer: (callback) => (typeof ResizeObserver === "function" ? new ResizeObserver(callback) : undefined),
      }),
  );
  const [, setScroll] = useState(scrollRef.current);
  const scheduleScrollLeadReset = () => {
    clearTimeout(scrollLeadTimer.current);
    if (scrollRef.current.delta === 0) {
      scrollLeadTimer.current = undefined;
      return;
    }
    scrollLeadTimer.current = setTimeout(() => {
      scrollLeadTimer.current = undefined;
      if (scrollRef.current.delta === 0) return;
      scrollRef.current = { ...scrollRef.current, delta: 0 };
      setScroll(scrollRef.current);
    }, SCROLL_LEAD_IDLE_MS);
  };
  const setScrollAt = (top: number, delta?: number) => {
    const next = { top, delta: delta ?? top - scrollRef.current.top };
    scrollRef.current = next;
    setScroll(next);
    scheduleScrollLeadReset();
  };
  /// The view follows the latest row (scrolledTo.atLatest, as of the last scroll). Jump to latest shows
  /// when it does not and the latest message is more than JUMP_LATEST_DISTANCE below, read each render,
  /// so a reply growing below or a session switch updates it without a scroll.
  const [following, setFollowing] = useState(true);
  /// Jump to latest is shown (`behind`, below): set past JUMP_LATEST_DISTANCE, cleared only back at
  /// the latest message.
  const jumpShown = useRef(false);
  /// Jump up (jumpUp.ts): the reader's idle stretch and the mark it pinned (this chat's, kept across
  /// reloads), the way back a press holds (a second press or Esc returns there), and the row lookups'
  /// hints.
  const [idle] = useState(() => new IdleTracker());
  // This chat's stretch (the last chat's is kept first, so coming straight back reads it).
  idle.open(sessionId, jumpButton);

  const jumpBack = useRef<JumpBack | undefined>(undefined);
  const [jumpBackHeld, setJumpBackHeld] = useState(false);
  /// Lets go of the way back a Jump up press holds.
  const dropJumpBack = useCallback(() => {
    jumpBack.current = undefined;
    setJumpBackHeld(false);
  }, [setJumpBackHeld]);
  const [promptScan] = useState<{ current: PromptScan }>(() => ({ current: { length: 0 } }));
  const [jumpUpHint] = useState(() => ({ current: -1 }));
  /// The offset Jump up just set, so its scroll event is not taken for the reader's stop.
  const placedTop = useRef<number | undefined>(undefined);
  /// Jump up's glide is in flight (`placeView`): its steps are its own, not the reader's stops.
  const placing = useRef(false);
  const [sinceHint] = useState(() => ({ current: -1 }));
  // Without the folder's GitHub remote, a bare `#N` in a row means the repository the transcript
  // mentioned last (conversation/transcriptRepositories.ts); each row's text is read once per change.
  const rowRepositories = useRowRepositories(rows, githubRepository, fallbackRepository);
  // Which repository each row's bare `#N` names, by the transcript's evidence
  // (conversation/bareReferences.ts): one scope object per turn, kept while nothing new is named;
  // a streaming reply reads only its own row again.
  const scopeAt = useMemo(
    () => (index: number) => references.scopeOf(turnOpener(references.cache, rows, index)),
    [rows, references],
  );
  /// The follow motion's arm (followMotion.experiment.ts), read once per transcript. Every arm but
  /// `eased` (followGlide, the view before) chases each move of the rows in view (followChase.ts).
  const [followArm] = useState(() => experimentArm(followMotion));
  /// Jump up's arm (jumpUp.experiment.ts), read once per transcript: `off` (the default) draws no
  /// Jump up and keeps no place for it on a scroll.
  const [jumpUpOn] = useState(() => experimentArm(jumpUpButton) === "on");
  const chasing = followArm !== "eased";
  /// The `send` arm (the product's): only a send's rise chases; a reply streaming, a row arriving
  /// and the turn's end move the rows at once, in the pass that moved them, as Claude Code's
  /// transcript only appends (Leo, 2026-11-09: "these animations all slosh around and it's not
  /// cohesive / i previously sent the claude code one, just look at how they do it").
  const slimFollow = followArm === "send";
  const followChase = useRef<FollowChase>(undefined);
  if (followChase.current == null) followChase.current = createFollowChase(slimFollow ? "blocks" : followArm);
  /// Freezes the composer growth's rise of the rows where it is painted (the dock's effect sets it).
  const freezeGrowthRise = useRef<() => void>(() => {});
  // `scroll` events also fire for layout-driven writes to scrollTop. Keep the user's intent in a
  // ref so those events cannot turn a pinned transcript into a one-frame jump when the composer
  // stack changes height.
  const followingRef = useRef(true);
  const followDeferred = useRef(false);
  /// A send or a move toward the latest row asks to follow now, through the input hold that defers
  /// follow-bottom. It lasts until the reader's next input (userScroll.ts `request`).
  const followRequest = useRef<(() => boolean) | undefined>(undefined);
  /// Upward reader input whose scroll event has not come yet: the live offset already holds that
  /// movement, so the anchor pass keeps it. Once the event is processed, a later live change is
  /// layout work (#26718) and the stored offset is the base again.
  const [followResume, resumeDeferredFollow] = useReducer((count: number) => count + 1, 0);
  /// "New since you looked" in these rows: reaching the latest message ends its banner (`reachedLatest`).
  const sinceMark = useRef(sinceKey);
  useInsertionEffect(() => {
    sinceMark.current = sinceKey;
  });
  /// The view follows the latest row again by the reader's move (a scroll, End, Jump to latest, a
  /// send): the unread banner has nothing left to offer, wherever its line's observer last saw the
  /// line, and a line the reader saw on the way is read (conversation/unreadState.ts `sinceDone`,
  /// as #40072 has it for #40065). A chat that opens follows from the start, so its banner still
  /// shows there.
  const reachedLatest = () => {
    if (sinceMark.current !== undefined) sinceDone(sinceMark.current, true);
  };
  /// `path` names what turned following on, for the trace (followTrace.ts `arms`).
  const follow = (next: boolean, path = "other") => {
    if (next && !followingRef.current) followTrace.armed(path);
    // A switch to another chat opens it at its latest message: that is not the reader going there.
    if (next && !followingRef.current && path !== "session") reachedLatest();
    // Followed again: a chase the reader's input held goes on home, whether or not a layout pass
    // comes after (followChase `resume`).
    if (next && !followingRef.current) resumeFollowMotion();
    if (next) heldPlace.current = undefined;
    followingRef.current = next;
    onFollowingChange?.(next);
    setFollowing(next);
  };
  const followRef = useRef(follow);
  followRef.current = follow;
  // The layout watcher's streaming read (conversation/layoutWatch.ts): a growing last row is no move.
  const workingRef = useRef(working);
  workingRef.current = working;
  const transcriptMounted = useRef(true);
  const scrollPacer = useRef<ReturnType<typeof createScrollPacer> | undefined>(undefined);
  const pacedScroll = (frame: ScrollFrame) => {
    if (!transcriptMounted.current) return;
    // A wheel/default write or a rail jump may move the live scroller after an event queued this
    // frame. The queued state is stale, but dropping it starves virtualization until motion stops.
    // Commit the live offset and preserve the synchronous reader/jump intent instead.
    if (ref.current && Math.abs(ref.current.scrollTop - frame.top) > 0.5) {
      const node = ref.current;
      const top = node.scrollTop;
      const atLatest = authoritativeScrollIntent({
        top,
        scrollHeight: node.scrollHeight,
        clientHeight: node.clientHeight,
        following: followingRef.current,
        jumping: jumpTarget.current !== undefined,
        deadband: FOLLOW_BOTTOM_DEADBAND_PX,
      });
      scrollRef.current = {
        top,
        delta: top - scrollRef.current.top || scrollRef.current.delta,
      };
      // Route recovery through the authoritative setter so the parent callback and synchronous
      // intent ref agree; a stale queued `atLatest` must not retake a parked reader.
      flushSync(() => {
        followRef.current(atLatest, "pacer");
        setScroll(scrollRef.current);
      });
      return;
    }
    acpmuxPerf.timed("flush.scroll", () => {
      flushSync(() => {
        setScroll(scrollRef.current);
        // Upward intent can arrive before the browser's default moves the offset. Even at the
        // queued frame's exact position, its old follow state must not replace that live intent.
        setFollowing(followingRef.current);
      });
    });
  };
  if (scrollPacer.current == null) scrollPacer.current = createScrollPacer(pacedScroll);
  const queueScroll = (
    top: number,
    atLatest: boolean,
    immediate = false,
    path = "scroll",
    input: string | null = null,
  ) => {
    if (atLatest && !followingRef.current) followTrace.armed(path, input, top);
    if (atLatest && !followingRef.current) resumeFollowMotion();
    if (atLatest && !followingRef.current) reachedLatest();
    // Keep the intent ref synchronous so a second scroll event before the next frame sees the
    // reader's latest state; React work itself is coalesced by scrollPacer.
    followingRef.current = atLatest;
    onFollowingChange?.(atLatest);
    // The pacer may already have committed this offset (a frame-driven scroll moves it before its
    // event comes): an event that brings no new offset keeps the direction the scroll has. Its delta
    // of 0 left the next render no lead, and a fling painted blank frames (transcript-fling on the
    // CI runner, mounted rows a step behind the view).
    scrollRef.current = {
      top,
      delta: top - scrollRef.current.top || scrollRef.current.delta,
    };
    scheduleScrollLeadReset();
    if (immediate) scrollPacer.current!.flush({ top, atLatest });
    else scrollPacer.current!.enqueue({ top, atLatest });
  };
  /// The chat's frame budget (frameBudget.ts): while it is busy its frames are read, and past the
  /// budget every chat motion goes minimal until they are healthy again.
  const frameBudget = useRef<FrameBudget>(undefined);
  useEffect(() => {
    // The chat's own pane is marked, never the page: the rest of the app keeps its motion.
    const node = ref.current;
    if (!node) return;
    const budget = shareFrameBudget(node.closest(".acpmux-shell") ?? node);
    frameBudget.current = budget;
    budget.poke();
    return () => {
      budget.dispose();
      if (frameBudget.current === budget) frameBudget.current = undefined;
    };
  }, []);
  // A commit that moves the rows is the chat doing work: its frames are read for a moment after.
  // Fresh row objects that change no row are no work (frameBudget.ts `rowsMoved`).
  const pokedRows = useRef<readonly AcpmuxRow[]>([]);
  useEffect(() => {
    const before = pokedRows.current;
    pokedRows.current = rows;
    if (rowsMoved(before, rows)) frameBudget.current?.poke();
  }, [rows]);
  useEffect(() => {
    transcriptMounted.current = true;
    guard.connect({
      read: () => guardRead.current(),
      // An offset handled a frame ago has had its scroll event by now (or never gets one).
      frame: () => {
        frameGuard.current.handled = undefined;
      },
      node: () => (transcriptMounted.current ? ref.current : null),
    });
    // The flicker detector's remount count (flickerLog.ts): a second mount on one page is a remount.
    noteTranscriptMount();
    return () => {
      transcriptMounted.current = false;
      scrollPacer.current?.cancel();
      clearTimeout(scrollLeadTimer.current);
      guard.stop();
    };
  }, [guard]);
  /// Where Jump to latest's glide is headed while it is in flight: its steps are the view following,
  /// not the reader's scroll, and nothing snaps it to the end before it arrives.
  const jumpTarget = useRef<number | undefined>(undefined);
  const wheelGlide = useRef<ReturnType<typeof installWheelGlide>>(undefined);
  /// Eases the followed view's steps with a streaming reply on the compositor (followGlide.ts).
  const followGlide = useRef<ReturnType<typeof createFollowGlide>>(undefined);
  if (followGlide.current == null) followGlide.current = createFollowGlide();
  /// The rows under what changed glide to their new place while the chase follows (tailGlide.ts),
  /// instead of jumping by what landed above them (the live line, a steer under its new footer).
  const tailGlide = useRef<TailGlide>(undefined);
  if (tailGlide.current == null) tailGlide.current = createTailGlide();
  /// A row in view and its layout top on screen (its box less the chase's translate) as of the last
  /// followed pass: the next pass measures how far the rows the reader sees moved from it.
  const chaseAnchor = useRef<{ id: string; top: number } | undefined>(undefined);
  /// Jump to latest landed: the reader asked for the latest row, so what streams on keeps it over the
  /// bottom stack (the chase draws it down at most the live line's room, in every arm, as base's glide
  /// did). Cleared by a send, by any stop of the jump (reader input, a chat switch), and away from the
  /// latest row; the chase then lets content pass under the composer again.
  const chaseHeld = useRef(false);
  /// The tail row (id and version) the chat opened on, until something new comes after the open:
  /// the passes before that are the open's settle (rows drawn at their measured heights, a late
  /// read), which land at once, as the open itself does (chat-open-long.test.ts). Undefined once armed.
  const chaseOpenTail = useRef<{ id: string; version: number } | undefined>(undefined);
  /// Until when (performance.now) the turn that just ended still draws its reply: the reveal drains
  /// what had arrived within StreamReveal.finishMs of the end, and those lines ride the chase.
  const chaseDrainUntil = useRef(Number.NEGATIVE_INFINITY);
  /// When (performance.now) a row last arrived at the tail of a followed running turn
  /// (`arrivedAtTail`): the chase holds what it brings back up to the trail bound.
  const arrivedAt = useRef(Number.NEGATIVE_INFINITY);
  /// The reply's drawn height while the turn's end folds and its last lines reveal (`chaseDrainUntil`).
  const drainReply = useRef<{ id: string; height: number } | undefined>(undefined);
  /// The turn's reply, its last assistant row near the end, and its drawn height. O(1): a few rows
  /// from the end and one element's height.
  const replyHeight = (shown: readonly AcpmuxRow[]) => {
    for (let index = shown.length - 1; index >= Math.max(0, shown.length - 6); index -= 1) {
      const row = shown[index]!;
      if (row.kind !== "assistant") continue;
      const name = typeof CSS === "undefined" ? row.id.replace(/["\\]/g, "\\$&") : CSS.escape(row.id);
      const node = thread.current?.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${name}"]`);
      return node ? { id: row.id, height: node.offsetHeight } : undefined;
    }
    return undefined;
  };
  /// Ends the follow motion in flight where the rows lay out, and forgets where they were.
  /// Followed again after the reader's input held it: the chase and the rows' glides go on.
  const resumeFollowMotion = useCallback(() => {
    followChase.current?.resume();
    tailGlide.current?.resume();
  }, []);
  const stopFollowMotion = useCallback(() => {
    followGlide.current?.stop();
    followChase.current?.stop();
    tailGlide.current?.stop();
    chaseAnchor.current = undefined;
  }, []);
  /// The scroller's physical offset and height as the placement pass last read or wrote them, while
  /// that pass runs: its chase takes them from here instead of reading the scroller after the pass
  /// wrote to the page. Undefined outside it (a send's chase reads).
  const pinView = useRef<{ top: number; height: number } | undefined>(undefined);
  /// The followed view's pass moved the rows (or may have): how far the row in view the last pass
  /// noted moved on screen is one move of the chase, which draws the thread back by it and chases
  /// home; then the row now in view is noted for the next pass. O(1): one row looked up by id, one
  /// box read, after the pass's own layout. A row that left (or none noted) moves nothing.
  const chaseFollow = (
    node: HTMLElement,
    placed: Parameters<typeof visibleLayoutRange>[0],
    shown: readonly AcpmuxRow[],
    below = Number.POSITIVE_INFINITY,
    moveAtOnce = false,
    held = false,
    arrived = false,
    sent = false,
  ) => {
    const chase = followChase.current!;
    // An at-once pass cannot shift a chase: the rows have already landed and the next
    // animated pass must establish a fresh anchor. Avoid reading row geometry here; on
    // every streamed update the old path paid two getBoundingClientRect() calls even
    // though `moveAtOnce` skipped the only branch that used their result.
    if (moveAtOnce) {
      chaseAnchor.current = undefined;
      resumeFollowMotion();
      chase.fit(below);
      return;
    }
    const rowTop = (id: string) => {
      const name = typeof CSS === "undefined" ? id.replace(/["\\]/g, "\\$&") : CSS.escape(id);
      const row = thread.current?.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${name}"]`);
      return row ? row.getBoundingClientRect().top - chase.outstanding() : undefined;
    };
    const before = chaseAnchor.current;
    // Read only for a move it chases: a pass that moves at once never uses it.
    const now = before && !moveAtOnce ? rowTop(before.id) : undefined;
    // Followed again after the reader's input held it: it goes on home from where it is drawn.
    resumeFollowMotion();
    chase.fit(below);
    // A turn's end folding moves the rows itself (turnEndFold.ts): their motion is no move to chase.
    const turnEnding = thread.current?.hasAttribute(TURN_END_ATTR) === true;
    if (before && now !== undefined && !moveAtOnce && !turnEnding)
      chase.shift(thread.current, now - before.top, below, held, arrived, sent);
    const view = pinView.current;
    const first = visibleLayoutRange(
      placed,
      view ? view.top - scrollOrigin(node) : layoutScrollTop(node),
      view ? view.height : node.clientHeight,
      0,
    ).first;
    const id = shown[Math.min(first, shown.length - 1)]?.id;
    const top = id === undefined ? undefined : rowTop(id);
    chaseAnchor.current = id !== undefined && top !== undefined ? { id, top } : undefined;
  };
  /// When the view last changed size: the passes that settle the rows after it never glide.
  const resizedAt = useRef(Number.NEGATIVE_INFINITY);
  /// A live resize (a divider or window edge dragged): the box's width changed again within
  /// LIVE_RESIZE_MS of its last change. Each frame of it measures only the rows around the view
  /// (layoutConversation `resizing`); the whole chat is measured once, when the width holds.
  /// `flow`: the row width the rows were placed at when the drag began to flow. While it is set the
  /// mounted rows sit in normal flow (`FLOW_CLASS`) and the browser lays them out at each new width
  /// as it does a web page; React places nothing until the width holds (Leo, 2026-11-11: "the
  /// dragging responsiveness is slow for agent chat but fast for browser hmmm").
  const liveResize = useRef<{
    at: number;
    live: boolean;
    /// Width steps in a row, each promptly after the one before was served.
    steps: number;
    /// When the last width step's own work finished (conversation/liveResizeStep.ts): the next
    /// width is judged against this, never against when the last step began, which is the cost
    /// this judgement is used to avoid.
    served?: number;
    flow?: number;
    /// The chat the rows flow in: another chat ends the flow.
    flowSession?: string;
    /// The box's effect was cleaned up inside a live resize (its inputs changed): its next run starts
    /// the settle's timer that the cleanup cleared, so the width's settle is not lost.
    rearm?: boolean;
    /// While rows flow from their top: the row the reader looks at, where it showed in the view,
    /// and the thread's padding that keeps it there (`holdFlow`).
    /// `top` is the scroll offset `at` was read at: a scroll by the reader moves the row with it.
    hold?: {
      row: HTMLElement;
      at: number;
      pad: number;
      first: number;
      top: number;
    };
    /// The flow lengths as last written on the thread (`writeFlow`).
    wrote?: FlowWritten;
  }>({
    at: Number.NEGATIVE_INFINITY,
    live: false,
    steps: 0,
  });
  /// `liveResize.flow` as the render reads it: set and cleared in the same update as the ref, which
  /// the handlers and effects read (a render reads no ref).
  const [flowWidth, setFlowWidth] = useState<number | undefined>();
  const [resizeSettled, settleResize] = useReducer((count: number) => count + 1, 0);
  /// The chat of the last commit, for a flow that starts from the box's observer.
  const sessionIdRef = useRef(sessionId);
  // The last transcript box on this page until this one is measured (before its first paint, below).
  const [height, setHeight] = useState(() => lastTranscriptBox.height);
  // The native pane's width, distinct from the transcript scroller's width when Push always reserves
  // a Session Info column. The pane-pinned rail uses this so its inset never follows that column.
  const [paneWidth, setPaneWidth] = useState(() => lastTranscriptBox.width);
  /// The scrollbar's lane (scrollers.ts SHOWN_SCROLLER_ATTRIBUTE: always there, its thumb drawn while
  /// the chat overflows). The rows lay out across it, against the scroller's full width as the
  /// composer does, so the column matches the composer's and nothing reflows as a chat starts to scroll.
  const [lane, setLane] = useState(0);
  const ref = useRef<HTMLDivElement>(null);
  // Tab into the rows lands on one in view, never on a row mounted past the view's edge, which
  // focusing would scroll to (ui/tabReach.ts keepTabOnScreen, #38090).
  useLayoutEffect(() => (ref.current ? keepTabOnScreen(ref.current) : undefined), []);
  const stopJump = useCallback(() => {
    // Find, reveal and an asynchronous send own their new placement, even without a jump in flight.
    wheelGlide.current?.stop();
    stopFollowMotion();
    jumpTarget.current = undefined;
    chaseHeld.current = false;
    // A footnote also owns the shared runner and must end on session/send/Find transitions.
    if (ref.current) stopScroll(ref.current);
  }, [stopFollowMotion]);
  // The shared animation owns one RAF and its input listeners. Leaving this chat or unmounting
  // cancels that ride before the next session can reuse this scroller.
  useLayoutEffect(() => stopJump, [sessionId, stopJump]);
  /// The bottom stack's height over the view's foot: room under the last row, out of the view.
  const [dockSpace, setDockSpace] = useState(0);
  /// The view mask's holes behind the stack's clear rows (conversation/dockClear.ts).
  const [dockHoles, setDockHoles] = useState("");
  const dockSpaceRef = useRef(0);
  dockSpaceRef.current = dockSpace;
  const topInsetRef = useRef(topInset);
  topInsetRef.current = topInset;
  /// The room the rows keep over a floating stack: its height, and the rest gap's share past the last
  /// row's own turn gap (model.ts `restRoom`), so the newest row rests the same gap over whatever the
  /// stack's top is. Read once per transcript; the masks, Jump to latest and the scroll-into-view
  /// clearance keep the stack's own height (`dockSpace`).
  const [restExtra] = useState(restRoom);
  const dockRoom = dockSpace > 0 ? dockSpace + restExtra : 0;
  const dockRoomRef = useRef(0);
  dockRoomRef.current = dockRoom;
  // Full stack height is distinct from the overlap room: a tall dock can extend beyond the
  // viewport, while an after-latest tray still needs the whole stack reserved in stage flow.
  const [dockHeight, setDockHeight] = useState(0);
  const dockHeightRef = useRef(0);
  dockHeightRef.current = dockHeight;
  /// The composer card's height, in that stack: what grows a line at a time (Shift-Return, a wrap).
  const [dockCard, setDockCard] = useState(0);
  const dockCardRef = useRef(0);
  dockCardRef.current = dockCard;
  /// The running tray's height, in that stack: what its header, View all and a command's live tail
  /// open and fold. What the reader opens or folds there the room under the last row takes only once
  /// the rows move anyway (`trayHold`).
  const [dockTray, setDockTray] = useState(0);
  const dockTrayRef = useRef(0);
  dockTrayRef.current = dockTray;
  /// The reader opened or folded something in the tray, and the room has not taken it yet.
  const trayToggled = useRef(false);
  /// The notices in that stack (noticeSlotModel.ts `DOCK_NOTICE`): the host's line (HostError.tsx:
  /// "Reconnecting…", or a refusal and its Retry), which comes and goes while the pane finds acpmux, an
  /// app notice (PaneNotices.tsx), the daemon's Retrying… (AutoResumeNotice.tsx) and the rest a relaunch
  /// can bring late: the room under the last row takes them only once the rows move anyway (`noticeHold`).
  const [dockNotice, setDockNotice] = useState(0);
  /// The same, as the stack's observer last measured it (it writes both), for the handlers below.
  const dockNoticeRef = useRef(0);
  /// The host line's height the room under the last row last took (`noticeHold` below). State, not a
  /// ref read in render: the pass that changes it renders once more before the frame paints, with the
  /// same hold (the base it writes is the one that hold was made against), so nothing moves. It changes
  /// only when the line comes taller than the room lets it lie over, goes and the rows move, or Jump to
  /// latest takes it.
  const [noticeBase, setNoticeBase] = useState(0);
  /// The same, for the handlers below (written where the state is).
  const noticeBaseRef = useRef(0);
  /// The tray's height the room under the last row was last given (`trayHold` below), and the rows'
  /// own height as of the last pass, which tells a pass whose rows grew.
  const foldBase = useRef(0);
  const rowsSeen = useRef(0);
  /// A queued prompt left the bottom stack this frame: a sent one is about to come in as the latest
  /// row; a withdrawn one (deleted from the queue) never does.
  const queueLeft = useRef(false);
  const queuedIds = useRef(new Set<string>());
  /// The prompts whose cards left, which the room under the last row is kept for (`floor`).
  const heldFor = useRef(new Set<string>());
  const withdrawnSet = useMemo(() => new Set(queueWithdrawn), [queueWithdrawn]);
  const withdrawn = useRef(withdrawnSet);
  withdrawn.current = withdrawnSet;
  const dockRef = useRef(dock);
  dockRef.current = dock;
  // The wheel over the stack's parts scrolls nothing (wheelPassThrough.ts installDockWheelHold).
  useEffect(() => (dock ? installDockWheelHold(dock) : undefined), [dock]);
  const queueSession = useRef(sessionId);
  queueSession.current = sessionId;
  /// The chat and the stack `queuedIds` were noted in.
  const notedIn = useRef<{ sessionId?: string; dock?: HTMLElement | null }>({});
  /// Notes the stack's queued prompts; called first by each size observer (the stack's, and the
  /// view's, for a stack laid out under the transcript), so the render a size change makes knows,
  /// and by each change of the queue (below). A prompt the queue's fold hides (ComposerQueue
  /// `data-folded-ids`) is still queued: closing the fold is not its card leaving, and no room is
  /// kept under the last row for a prompt that stays queued (Leo 2026-10-21: the queue closed left a
  /// hole over the stack, then the rows dropped).
  const noteQueue = useCallback(() => {
    const dock = dockRef.current;
    const now = new Set([
      ...[...(dock?.querySelectorAll<HTMLElement>(".acpmux-queued") ?? [])].map((card) => card.dataset.promptId ?? ""),
      ...[...(dock?.querySelectorAll<HTMLElement>("[data-folded-ids]") ?? [])].flatMap((list) =>
        (list.dataset.foldedIds ?? "").split(" "),
      ),
      ...(queueIds ?? []),
    ]);
    // Another chat's queue, or another stack, starts over: the last one's prompts never left this
    // one, and no room is held for them (#24182: switched to a chat with its own queue, the last
    // chat's prompts read as cards that left, and a prompt withdrawn later kept room as a sent one).
    if (notedIn.current.sessionId !== queueSession.current || notedIn.current.dock !== dock) {
      notedIn.current = { sessionId: queueSession.current, dock };
      queuedIds.current = now;
      heldFor.current.clear();
      queueLeft.current = false;
      return;
    }
    const left = [...queuedIds.current].filter((id) => !now.has(id));
    queuedIds.current = now;
    if (!left.length) return;
    for (const id of left) heldFor.current.add(id);
    if (queueLeft.current) return;
    queueLeft.current = true;
    // Only the size change of this frame is the card leaving.
    requestAnimationFrame(() => requestAnimationFrame(() => (queueLeft.current = false)));
  }, [queueIds]);
  // The rows beside the stack stay in sight (conversation/useBesideStack.ts).
  useBesideStack(dock, ref, TRAY_GHOST);
  useLayoutEffect(() => {
    if (!dock) {
      setDockSpace(0);
      setDockHoles("");
      setDockHeight(0);
      setDockCard(0);
      setDockTray(0);
      dockNoticeRef.current = 0;
      setDockNotice(0);
      return;
    }
    // Before the frame paints, as the viewport's own size is: a composer that grew a line, or a
    // queue that appeared, never draws a frame with the latest row under it. The room is how far
    // the stack reaches over the view: none for a stack in the flow under it, or with no box
    // (display: contents).
    const over = () => {
      const stack = dock.getBoundingClientRect();
      const view = ref.current?.getBoundingClientRect();
      return stack.height > 0 && view ? Math.max(0, Math.min(stack.height, view.bottom - stack.top)) : 0;
    };
    const height = () => Math.max(0, dock.getBoundingClientRect().height);
    // Where the stack's clear rows let the transcript show, while it reaches over the view.
    const holes = (space: number) => {
      const view = ref.current?.getBoundingClientRect();
      return space > 0 && view ? dockClearStops(dockClearSpans(dock, view.bottom)) : "";
    };
    // The composer card's height, while the stack reaches over the view.
    const card = (space: number) =>
      space > 0 ? (dock.querySelector(".acpmux-composer-box")?.getBoundingClientRect().height ?? 0) : 0;
    // The tray, at its drawn height while what it opens plays (useFold animates it); not the copy
    // of one that left (trayMotion.tsx), which fades over the stack and takes no room.
    const tray = (space: number) =>
      space > 0
        ? (dock.querySelector(`:scope > .acpmux-running-tray:not(.${TRAY_GHOST})`)?.getBoundingClientRect().height ?? 0)
        : 0;
    // The stack's notices (the host's line, an app notice, Retrying…: noticeSlotModel.ts DOCK_NOTICE),
    // while the stack reaches over the view.
    const notice = (space: number) => {
      if (space <= 0) return 0;
      let height = 0;
      for (const line of dock.querySelectorAll(DOCK_NOTICE)) height += line.getBoundingClientRect().height;
      return height;
    };
    // A click on one of its disclosures (the header, View all, a command's line) is the reader's.
    // One that changes no height (or a tray that goes) holds nothing: the flag goes after two frames
    // unless the tray's height changed meanwhile, or its fold is still to move it (useFold's motion
    // can sit pending at its start height for those frames: the hat's fold starts at 0px).
    const folding = () =>
      dock
        .querySelector(`:scope > .acpmux-running-tray:not(.${TRAY_GHOST}) > .acpmux-running-tray__fold`)
        ?.getAnimations()
        .some((animation) => animation.playState !== "finished") ?? false;
    const toggled = (event: MouseEvent) => {
      const target = event.target instanceof Element ? event.target : null;
      const toggle = target?.closest("[aria-expanded]");
      if (!toggle || toggle.closest(".acpmux-running-tray")?.parentElement !== dock) return;
      trayToggled.current = true;
      const at = tray(1);
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          if (Math.abs(tray(1) - at) < 0.5 && Math.abs(dockTrayRef.current - foldBase.current) < 0.5 && !folding())
            trayToggled.current = false;
        }),
      );
    };
    dock.addEventListener("click", toggled, { capture: true });
    // The prompt field's growth motion (composer/fieldGrowth.ts), while it runs: the field and the
    // height it lands on, and the rows' own move on its curve. The stack is measured as it will be
    // once the field lands (its drawn height plus what the field has yet to grow), so the motion's
    // frames render nothing here: the room takes the end height once, as the motion starts, and the
    // rows go home on the compositor with the field.
    let growth: { field: HTMLElement; to: number } | undefined;
    let rowsMove: Animation | undefined;
    // The reader's input wins over the rise: the rows freeze where they are painted (the rise's part
    // handed to the follow chase, held as it holds), and the card grows on over them, as `cardHold`
    // does. Played on, the rise moved the rows while the reader scrolled up. Two style reads, on input
    // only while a rise plays.
    // The stack's own moves (below) freeze the same way.
    const stackMoves = new Set<Animation>();
    freezeGrowthRise.current = () => {
      const rows = thread.current;
      const move = rowsMove;
      const playing = (one: Animation | undefined) => one && one.playState !== "finished" && one.playState !== "idle";
      if (!rows || (!playing(move) && stackMoves.size === 0)) return;
      const drawnY = () => {
        const value = getComputedStyle(rows).translate;
        return value && value !== "none" ? Number.parseFloat(value.split(" ")[1] ?? "") || 0 : 0;
      };
      const before = drawnY();
      move?.cancel();
      rowsMove = undefined;
      for (const one of stackMoves) one.cancel();
      stackMoves.clear();
      followChase.current?.carry(rows, before - drawnY());
    };
    /// What the field has yet to grow (px), 0 once it rests (and the growth is over).
    const toGrow = () => {
      if (!growth) return 0;
      if (growth.field.isConnected && growth.field.getAnimations().length > 0)
        return growth.to - growth.field.getBoundingClientRect().height;
      growth = undefined;
      // A motion cut short (Reduce Motion turned on, the chat left) lands the rows with the field.
      rowsMove?.cancel();
      rowsMove = undefined;
      return 0;
    };
    const take = () => {
      noteQueue();
      const rest = toGrow();
      const drawn = over();
      const next = drawn > 0 ? drawn + rest : 0;
      const nextHeight = height() + rest;
      const nextCard = card(drawn) + (drawn > 0 ? rest : 0);
      const nextTray = tray(drawn);
      setDockHoles(holes(drawn));
      const nextNotice = notice(drawn);
      const noticeChanged = Math.abs(nextNotice - dockNoticeRef.current) >= 0.5;
      dockNoticeRef.current = nextNotice;
      // A tray that went holds nothing: the room is the stack's again.
      if (nextTray <= 0) trayToggled.current = false;
      if (
        Math.abs(next - dockSpaceRef.current) >= 0.5 ||
        Math.abs(nextHeight - dockHeightRef.current) >= 0.5 ||
        Math.abs(nextCard - dockCardRef.current) >= 0.5 ||
        noticeChanged
      )
        flushSync(() => {
          setDockSpace(next);
          setDockHeight(nextHeight);
          setDockCard(nextCard);
          setDockTray(nextTray);
          setDockNotice(nextNotice);
        });
    };
    // The stack changed height on its own (an ask that left or came, the trust question answered
    // over the permission card under it): the room takes the new height at once, as above, and the
    // rows the room moved start where they were drawn and glide home on the fold's clock, one move
    // for every row (the same move the field's growth plays). A move the room did not make (the
    // tray, notice and card holds keep the rows still) has no delta and plays nothing.
    // A second change while one plays adds its own move on top (composite add), so the rows never
    // jump to where the first was headed.
    // An ask in the stack that folds or resizes on the fold's own clock (the trust question folding
    // out, a permission card's full command: `clipFold` marks the box while it plays) moves the stack
    // frame by frame: the room takes each frame's height and the rows ride with it on that one clock.
    // A glide of their own on top would trail the stack's edge by a fold.
    const asksFolding = () => dock.querySelector(":scope > .acpmux-asks-stack [data-fold-clip]") !== null;
    const resized = () => {
      const rows = thread.current;
      if (!rows || growth || asksFolding()) {
        take();
        return;
      }
      const before = rows.getBoundingClientRect().top;
      const cardBefore = dockCardRef.current;
      take();
      const delta = before - rows.getBoundingClientRect().top;
      // A send clearing a tall prompt gives its room back in the send's own frame (the field's height
      // changes at once, fieldGrowth.ts), and on the product's 0 send clock the send's rows land in
      // that frame too (the placement pass, `sendLands`). A glide here would move the rows a second
      // time after the composer already collapsed. Leo, 2026-11-22: "when i send it collapses the
      // compser then sends it to you... but i think we should be able to calculate it out to be like
      // one smooth motion."
      const sendGaveRoom =
        dockCardRef.current < cardBefore - 0.5 && performance.now() < sendRiseUntil.current && !(sendClockMs(rows) > 0);
      const ms = Math.abs(delta) < 0.5 || sendGaveRoom ? 0 : foldMs(rows);
      if (!(ms > 0)) return;
      const move = rows.animate([{ translate: `0 ${delta}px` }, { translate: "0 0" }], {
        duration: ms,
        easing: foldMotion.easing(rows),
        composite: "add",
      });
      stackMoves.add(move);
      move.addEventListener("finish", () => stackMoves.delete(move));
    };
    const observer = new ResizeObserver(resized);
    // perf-hot: one render and two layout reads per growth (not per frame) composer-field-growth
    const grew = (event: Event) => {
      const { detail, target } = event as FieldGrowthEvent;
      if (!(target instanceof HTMLElement)) return;
      growth = { field: target, to: detail.to };
      // After the edit's own task (ProseMirror's update, the composer's render), before the frame.
      queueMicrotask(() => {
        const rows = thread.current;
        if (!rows || growth?.field !== target) return;
        const before = rows.getBoundingClientRect().top;
        rowsMove?.cancel();
        rowsMove = undefined;
        take();
        // Where the rows now lie against where they were drawn: they start there and go home.
        const delta = before - rows.getBoundingClientRect().top;
        if (Math.abs(delta) < 0.5) return;
        const move = rows.animate(growthTranslate(detail, delta), {
          duration: detail.duration,
          easing: detail.progress ? "linear" : detail.easing,
          composite: "add",
        });
        if (detail.animation.startTime !== null) move.startTime = detail.animation.startTime;
        rowsMove = move;
        move.addEventListener("finish", () => {
          if (rowsMove === move) rowsMove = undefined;
        });
      });
    };
    dock.addEventListener(FIELD_GROWTH_EVENT, grew);
    observer.observe(dock);
    noteQueue();
    const space = over();
    const fullHeight = height();
    setDockSpace(space);
    setDockHoles(holes(space));
    setDockHeight(fullHeight);
    setDockCard(card(space));
    setDockTray(tray(space));
    dockNoticeRef.current = notice(space);
    setDockNotice(dockNoticeRef.current);
    return () => {
      observer.disconnect();
      dock.removeEventListener("click", toggled, { capture: true });
      dock.removeEventListener(FIELD_GROWTH_EVENT, grew);
      rowsMove?.cancel();
      for (const move of stackMoves) move.cancel();
      freezeGrowthRise.current = () => {};
    };
  }, [dock, noteQueue]);
  // And each time the queue changes, in the commit that draws it. A change that leaves the stack's
  // size as it was (a prompt the fold hides, or one an opened list's cap cuts off, run by another
  // client) runs neither observer: still noted as queued, the next resize took it for a card that
  // left then, and kept room above the stack for FLOOR_HOLD_MS that then glided away (#24182).
  useLayoutEffect(() => noteQueue(), [sessionId, queueIds, noteQueue]);
  const [width, setWidth] = useState(() => lastTranscriptBox.width);
  /// The width the box last measured at, read by its ResizeObserver to tell a width change.
  const widthRef = useRef(width);
  // The page zoom the column's cap is divided by: a new one measures every row again.
  const { scale: chatScale } = useChatSizing();
  // The user's chat look (font, sizes, width; chatDisplay.ts): a new one measures every row again.
  const chatLook = useChatDisplay();
  const measuredLook = useRef(chatLook);
  // The pane's attachment view moves a prompt's attachments between its bubble and the band above
  // it (UserBubble.tsx), so a new one estimates every prompt again (model.ts reads it).
  const { attachmentView } = useComposerSettings();
  const measuredView = useRef(attachmentView);
  // Rows place by their drawn height once drawn, and by the estimate until then.
  // One entry per row drawn, kept as a layered map: a measured row changes its layer, not a copy of
  // every row's entry (conversation/layeredMap.ts).
  const [drawn, setDrawn] = useState(LayeredMap.empty<DrawnHeight>);
  const pendingDrawn = useRef(new Map<string, DrawnHeight>());
  const pendingMeasures = useRef(new Map<HTMLElement, () => void>());
  const measurementCache = useRef(new Map<string, import("./model").PreparedRow>());
  /// The last estimate, whose unchanged leading rows the next one keeps.
  const lastEstimate = useRef<LastEstimate | undefined>(undefined);
  /// Estimated heights by row object, for the registry they were measured with.
  const rowHeights = useRef<{ registry: NativeRegistry; heights: RowHeights }>({
    registry,
    heights: new WeakMap(),
  });
  const measurementSession = useRef(sessionId);
  if (measurementSession.current !== sessionId) {
    // Row ids and versions are local to an acpmux session. A new session can reuse both, so
    // prepared markdown and DOM heights from the old transcript must never place the new one.
    // The chat shown takes the layout it left in this page, if any: its rows place at the heights they
    // drew, and its estimates measure none of them again (conversation/keptLayouts.ts).
    measurementSession.current = sessionId;
    measurementCache.current.clear();
    rowHeights.current = { registry, heights: new WeakMap() };
    pendingDrawn.current.clear();
    const shown =
      sessionId === undefined
        ? undefined
        : keptLayouts.show(sessionId, chatLook, attachmentView, registry, gridScale());
    // Its drawn heights name it (`DrawnHeight.sessionId`), so they place only its rows.
    if (shown && shown !== drawn) setDrawn(shown);
  }
  const drawnRef = useRef(drawn);
  drawnRef.current = drawn;
  const endReserve = Math.max(cardReserve, minimapBeside ? minimapReserve(width) : 0);
  // While a drag flows the rows keep the width they were placed at: nothing is estimated or placed
  // again until the width holds (`flowWidth`, the render's copy of `liveResize.flow`).
  const scaledRowWidth = flowWidth ?? transcriptRowWidth(width, chatColumnOf(chatLook, chatScale), endReserve);
  /// Whether the last commit was a flowing one: its rows are at a width it did not place at, so no
  /// height is read until a render that does not flow commits, even when the flow ended in between
  /// (an end from inside a commit renders only after it).
  const renderedFlowing = useRef(false);
  const flowing = flowWidth !== undefined;
  // Written as the render commits, before any layout effect's setup and any ref attach of that
  // commit (the rows' own among them): every reader runs from one of those, an observer or a timer.
  // A layout effect's CLEANUP of that commit runs before this write and still sees the commit before.
  useInsertionEffect(() => {
    renderedFlowing.current = flowing;
    sessionIdRef.current = sessionId;
  });
  /// A flow ended from a commit: the first commit that does not flow reads the mounted rows.
  const readAfterSettle = useRef(false);
  const rowWidthRef = useRef(scaledRowWidth);
  rowWidthRef.current = scaledRowWidth;
  const rowsRef = useRef(rows);
  /// The rows the render before this one drew, and its chat, for a turn's end (turnEndFold.ts).
  const rowsBefore = rowsRef.current;
  rowsRef.current = rows;
  /// Whether these rows are the last ones with only a streamed token in them (the same rows, a reply
  /// or the live thinking row at a new version: `arrivedAtTail`), which `queueDrawn` leaves to the
  /// rows' observer. Anything else (a row that came or left, a tool row's new state, the turn's
  /// end) reads its rows in the commit, so the pass that places them sees their heights: left to
  /// the observer's pass after it, the turn's end moved the rows by them at once (send-stream-motion
  /// tools and steer, 29 px). O(1): the tail window and the first row.
  /// Kept per rows list (`TokenRows`); `queueDrawn` reads the latest list's (`rowsRef`).
  const [tokenRows] = useState(() => new TokenRows(rows));
  tokenRows.draw(rows);
  /// Whether the render before this one drew any row: a send into a chat with none yet (a new
  /// chat's first prompt) has no latest row to become, and fades in place (conversation/sendMorph.ts).
  const drewRowsBefore = useRef(false);
  drewRowsBefore.current = rowsBefore.length > 0;
  const sessionBefore = useRef(sessionId);
  const sameChat = sessionBefore.current === sessionId;
  sessionBefore.current = sessionId;
  // Keyboard focus is a roving tab stop. A range is kept as stable row ids rather than DOM nodes
  // because the transcript virtualizes rows and can unmount either end while the reader moves.
  const [activeRowId, setActiveRowId] = useState(rows[0]?.id);
  const [transcriptRange, setTranscriptRange] = useState<TranscriptRange | undefined>();
  const activeRowRef = useRef(activeRowId);
  const transcriptRangeRef = useRef(transcriptRange);
  useInsertionEffect(() => {
    activeRowRef.current = activeRowId;
    transcriptRangeRef.current = transcriptRange;
  });
  /// The end rows of a selection a drag from the margin makes (gutterSelect.ts): they stay mounted
  /// while it lasts, so the selection keeps its ends when the view scrolls them out (at most two).
  /// Each with how far from the last row it was, which older history paging in above it keeps.
  const [heldRows, setHeldRows] = useState<{ session: string; rows: (HeldRow & { fromEnd: number })[] } | undefined>();
  /// The chat a hold is for: a hold from another chat (sessions reuse row ids) mounts nothing.
  const heldSession = useRef("");
  /// Ends a margin drag and lets its held rows go (gutterSelect.ts `release`).
  const gutterRelease = useRef<(() => void) | undefined>(undefined);
  const pendingFocus = useRef<string | undefined>(undefined);
  const sessionKey = sessionId ?? "";
  useInsertionEffect(() => {
    heldSession.current = sessionKey;
  });
  // Keep the key in state so a StrictMode render cannot consume the session transition before the
  // reset effect commits. The keyed values below make the first new-session paint fresh as well.
  const [selectionSessionKey, setSelectionSessionKey] = useState(sessionKey);
  const sessionChanged = selectionSessionKey !== sessionKey;
  /// A new chat taking the session its first prompt started is the same chat: that prompt's row and
  /// its Thinking line, drawn from the send (startingSends.ts), finish their entrance across it.
  const tookSession = sessionChanged && selectionSessionKey === "";
  /// The session a row frame's key names: the chat's own, except that a new chat keeps the
  /// sessionless key it drew its first prompt under once it takes its session, so those frames stay
  /// mounted (a remount would draw them again with no entrance). A later switch keys afresh.
  /// Derived from the last render's (React's "storing information from previous renders"), not a ref
  /// read in render.
  const [frameSession, setFrameSession] = useState({
    session: sessionKey,
    key: sessionKey,
  });
  const frameKey = frameSession.session === sessionKey || frameSession.session === "" ? frameSession.key : sessionKey;
  if (frameSession.session !== sessionKey) setFrameSession({ session: sessionKey, key: frameKey });
  /// A row can be newly arrived but outside the mounted virtual range. Pending entrances are
  /// page-scoped: hiding or switching chats must drop them before that row can mount later.
  /// Each entry is kept with its arrival time, and a row that mounts long after it arrived (scrolled
  /// back to) draws in place (conversation/pendingEntrances.ts).
  const enteringRows = useRef(new PendingEntrances());
  /// Where the tab stop and the selection's ends were found last (rowPresence `hints`).
  const presenceHints = useRef<RowPresenceHints>({});
  useEffect(() => {
    if (sessionChanged) {
      setSelectionSessionKey(sessionKey);
      setActiveRowId(rows[0]?.id);
      setTranscriptRange(undefined);
      // A margin drag, or the selection it left, belongs to the chat it was made in.
      gutterRelease.current?.();
      setHeldRows(undefined);
      pendingFocus.current = undefined;
      if (!tookSession) enteringRows.current.clear();
      return;
    }
    const currentRange = transcriptRangeRef.current;
    const presence = rowPresence(
      rows,
      activeRowRef.current,
      currentRange?.anchorId,
      currentRange?.focusId,
      presenceHints.current,
    );
    setActiveRowId((current) => (current && presence.active ? current : rows[0]?.id));
    setTranscriptRange((current) => {
      if (!current) return current;
      return presence.anchor && presence.focus ? current : undefined;
    });
  }, [rows, sessionChanged, sessionKey, tookSession]);
  useEffect(() => {
    const clearHiddenEntrances = () => {
      if (document.visibilityState === "hidden") enteringRows.current.clear();
    };
    document.addEventListener("visibilitychange", clearHiddenEntrances);
    return () => document.removeEventListener("visibilitychange", clearHiddenEntrances);
  }, []);
  // Rows that arrive live (a reply, a tool call, a status line) enter once. The rows at the first
  // render, and many at once (a session switch, older history), are a load and do not.
  const knownRows = useRef<Set<string> | null>(null);
  /// A "Worked for" (or subagent group) the reader toggled, while its rows slide and fade
  /// (conversation/turnFold.ts), and the drawn copies of rows a close hid, while they fade out.
  const turnFold = useRef<TurnFold | undefined>(undefined);
  const foldGhosts = useRef(new Set<HTMLElement>());
  const knownFor = useRef<readonly AcpmuxRow[] | null>(null);
  /// Where this snapshot first differs from the last, found once below; the rail reads it instead
  /// of comparing the rows again (model.ts minimapTurns).
  const rowsChange = useRef<RowsChange | undefined>(undefined);
  /// The minimap's hook for this commit's settled offset (ThreadMinimap `placed`).
  const minimapPlaced = useRef<((top?: number) => void) | undefined>(undefined);
  const [olderRows] = useState(() => new OlderRowFade(() => ref.current));
  /// The mounted rows' frame elements, kept while what each is drawn from holds (`RowFrameCache`).
  const [rowFrameCache] = useState(() => new RowFrameCache());
  // Row ids are local to a session: one still waiting to fade belongs to the chat that was shown.
  if (sessionChanged) olderRows.clear();
  /// The room above the rows for history not loaded yet, and the row it is held against.
  const olderRoom = useRef<OlderReserve | undefined>(undefined);
  const olderDragPending = useRef(false);
  const [scrollbarRange, setScrollbarRange] = useState<{ session: string; height: number } | undefined>(undefined);
  const draggedHeight = scrollbarRange?.session === sessionKey ? scrollbarRange.height : undefined;
  useLayoutEffect(() => {
    olderDragPending.current = false;
    setScrollbarRange(undefined);
  }, [sessionKey]);
  /// How far the reader has scrolled up among the rows while room was owed (olderReserve.ts `rose`),
  /// in total, and the offset the last scroll event read: each rise pays some of what is owed.
  /// offset the last scroll event read.
  const [roomRose, setRoomRose] = useState(0);
  const roomPaidFrom = useRef<number | undefined>(undefined);
  /// What the reader rose since the room last took a rise, paid once their input is quiet
  /// (`payRoomWhenQuiet`): nothing changes room mid-scroll (transcript-motion-model.md step 3).
  const roomRosePending = useRef(0);
  const roomRoseTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(roomRoseTimer.current), []);
  useLayoutEffect(() => {
    clearTimeout(roomRoseTimer.current);
    roomRoseTimer.current = undefined;
    roomRosePending.current = 0;
  }, [sessionKey]);
  /// Rows that arrived while the chat loaded (blank or partly blank, then text): their first mount
  /// fades in once (Leo, 2026-11-07, ask-69299b9711: "blank to fast fade in to text").
  const [loadFade] = useState(() => new LoadFadeWindow());
  if (sessionChanged) loadFade.clear();
  loadFade.phase(loading);
  /// What the row frames read their entrance and fades from (`drawRowFrames`): the entering ref is read there.
  const [rowFrameSources] = useState<RowFrameSources>(() => ({
    entering: enteringRows,
    loadFade,
    older: olderRows,
  }));
  // The tick the reader opened this chat (a click into it, a restart's first load): what it held
  // before is history and never enters; only what happened after it does (openBreakpoint.ts).
  // One per open of a chat: the page's record of it is read here and written only on commit.
  const opened = useMemo(() => openChat(sessionKey), [sessionKey]);
  const chatRowsDrawn = opened.drawn;
  // A switched chat starts over: its row ids are its own, and may repeat the last chat's.
  // Keyed by frame (model.ts `rowFrameKey`): a row drawn in a frame already on screen is not new.
  if (knownRows.current === null || sessionChanged) {
    const mounting = knownRows.current === null;
    knownRows.current = new Set(rows.map(rowFrameKey));
    // An empty chat draws no transcript: it mounts with the first prompt the reader just sent (and
    // its thinking line), and those rows enter on the send's clock as every later prompt's do
    // (conversation.css SEND-ENTRANCE). A transcript mounted again over an older chat does not.
    // A prompt drawn while its chat still starts (startingSends.ts, harnessSwitch.ts: pending, `queued`) is
    // this pane's send too, drawn before the send that counts it (`sends`) goes, once the chat started.
    if (
      mounting &&
      // A transcript mounted again over rows this page drew for the chat is not a first send.
      !opened.drewBefore &&
      (sends > 0 || rows.some((row) => row.kind === "user" && row.pending === true && row.queued !== undefined)) &&
      coldOpen === undefined &&
      rows.length <= LIVE_ROWS_PER_UPDATE &&
      rows.some((row) => row.kind === "user" && Date.now() - row.at < FIRST_SEND_FRESH_MS) &&
      entranceAllowed()
    )
      for (const row of rows) enteringRows.current.add(rowFrameKey(row));
  }
  // Scroll frames render the same rows: only a new row list can bring new rows.
  else if (knownFor.current !== rows) {
    // Rows before the first one that changed were all there last time.
    const previous = knownFor.current ?? [];
    let from = 0;
    while (from < rows.length && from < previous.length && rows[from] === previous[from]) from += 1;
    rowsChange.current = { base: previous, rows, from };
    // A page of older history lands above the first row that was already there (a date divider
    // moves up to the page's first turn, so the first known row, not the first row): those rows never
    // take a live row's entrance. They draw in place, as if they had always been there, unless the
    // page came late: the reader already reached the top of the loaded rows and stopped there, and
    // only then do they fade in as they are first seen (Leo 2026-10-31: no fade unless it's the
    // worst case). A page landing under a scroll draws in full ink.
    const oldFirst = rows.findIndex((row) => knownRows.current!.has(rowFrameKey(row)));
    const arrived: AcpmuxRow[] = [];
    let olderLate: boolean | undefined;
    // The chat still loads (or its read just landed): what arrives fills a blank or partly blank
    // view, so it fades in rather than popping. A cold open's first rows fade with the whole
    // transcript instead (fadeInOpenedChat), so they take no row fade on top of it. During a reader
    // gesture, history is part of that motion and must draw settled so its first frame is complete.
    // Only new arrivals need this snapshot; a gesture ending must not reanimate an existing row.
    const readerIsMoving = readerScroll.read();
    const loadArrival = loadFade.open && coldOpen === undefined && !readerIsMoving;
    // The running turn's live line keeps one id from turn to turn (turns.ts LIVE_THINKING): a line
    // the last rows did not end with came now, with the prompt that opened it, so it enters on the
    // send's clock with the prompt (conversation.css SEND-ENTRANCE). O(1): the last rows' tail only.
    const liveBefore = previous.at(-1)?.below ? rowFrameKey(previous.at(-1)!) : undefined;
    for (let index = from; index < rows.length; index += 1) {
      const row = rows[index]!;
      const key = rowFrameKey(row);
      // A row that takes over a frame on screen (OrderedRows `adoptFrames`) is drawn all the same.
      const redrawn = chatRowsDrawn.has(drawnKey(row));
      if (knownRows.current.has(key) && !(row.below && index === rows.length - 1 && key !== liveBefore)) continue;
      knownRows.current.add(key);
      // A row this page already drew for the chat, under another frame now (a reconnect's replay, a
      // transcript cleared and refilled), draws in place: it is not news and does not fade again.
      if (redrawn) continue;
      if (index < oldFirst) {
        // A page that lands while the reader scrolls is part of that motion: it draws in full ink,
        // with no 0.35 start (transcript motion model step 3: "no 0.35 fade for rows mounted while
        // scrolling"). Only a page that lands with the reader at rest at the top fades in.
        olderLate = olderLate ?? (!readerIsMoving && readerAtLoadedTop(ref.current, olderRoom.current?.room ?? 0));
        if (olderLate) olderRows.add(row.id);
        else if (loadArrival) loadFade.arrive(row.id);
      } else if (loadArrival) loadFade.arrive(row.id);
      // History the chat held before the reader opened it (the read behind the first slice, a
      // reconnect's replay) is not live: it draws in place (Leo, 2026-11-12: "you don't bother
      // trying to replay the animations").
      else if (!readerIsMoving && happenedAfterOpen(row, opened.at, clockOffset)) arrived.push(row);
    }
    // A row that arrived while the chat is hidden (another tab or workspace shows), or that lands
    // before its first frame back, came while the user was away: it draws in place. WebKit
    // suspends a hidden page's animations, so its entrance would play on return (shared/pageReveal.ts).
    // The rows a "Worked for" the reader opened reveals fade in with its fold (turnFold.ts) instead.
    if (entranceAllowed() && !turnFold.current?.opening) {
      // A live update's rows all enter.
      const live = arrived.length <= LIVE_ROWS_PER_UPDATE;
      // A turn that ends and the next that starts in one update (other agents' messages run as the
      // next turn: "Received 2 messages", then "Thinking") bring more rows than a live update, the
      // turn's regrouped work among them, and none entered: the new lines at the chat's end popped in
      // under the reply (Leo, 2026-11-11, on his NIGHTLY's end of a turn: "the animation system is so
      // borked and unintegrated"). The lines at the end that open nothing of the turn's work (a
      // received message's line, the live line) still enter, on the same fade as any live row; the
      // regrouped work stays the turn end's fold's (turnEndFold.ts). O(arrived).
      const entering = enteringRows.current;
      for (const row of arrived) if (live || row.below || isLineRow(row)) entering.add(rowFrameKey(row));
    }
  }
  knownFor.current = rows;
  // The rows a commit drew are the page's (openBreakpoint.ts `ChatDrawn`): those from the first one
  // that differs from the last commit's on, so a render React drops leaves no trace and a StrictMode
  // second render records what the first one did. O(changed rows).
  const committedRows = useRef<{ drawn: ChatRows; rows: readonly AcpmuxRow[] } | undefined>(undefined);
  useLayoutEffect(() => {
    const last = committedRows.current?.drawn === chatRowsDrawn ? committedRows.current.rows : NO_ROWS;
    let from = 0;
    while (from < rows.length && from < last.length && rows[from] === last[from]) from += 1;
    for (let index = from; index < rows.length; index += 1) chatRowsDrawn.add(drawnKey(rows[index]!));
    committedRows.current = { drawn: chatRowsDrawn, rows };
  }, [rows, chatRowsDrawn]);
  const onEntered = useCallback((id: string) => enteringRows.current.delete(id), []);
  const onLoadFaded = useCallback((id: string) => loadFade.shown(id), [loadFade]);
  const onOlderShown = useCallback((id: string) => olderRows.shown(id), [olderRows]);
  useEffect(() => () => olderRows.disconnect(), [olderRows]);
  const reportDrawn = useCallback<ReportDrawn>(
    (id, version, drawnHeight, actions, status, collapsing) => {
      // A flowing drag's rows are at a width they were not placed at: nothing is read until it holds.
      if (liveResize.current.flow !== undefined || renderedFlowing.current) return;
      // A row not laid out (hidden, or no layout at all) has no height yet; 0 is one (drawnHeightOf).
      if (drawnHeight !== undefined)
        pendingDrawn.current.set(id, {
          sessionId,
          version,
          width: rowWidthRef.current,
          height: drawnHeight,
          ...(actions ? { actions } : {}),
          ...(status ? { status } : {}),
          ...(collapsing ? { collapsing: true as const } : {}),
        });
    },
    [sessionId],
  );
  const queueDrawn = useCallback<QueueDrawn>(
    (node, id, version, actions, status, versionOnly) => {
      // A streamed token: no height read in the commit (a forced layout after React's writes, the top
      // one per token in a long chat). A row it resized is reported by the row's observer, in the
      // browser's own layout pass, before the frame paints (`observer` below); one it left at its
      // height keeps the height already placed, whose version differs only in a field placement
      // never reads. Read here only when no height is kept for the row as it is drawn now.
      if (versionOnly && tokenRows.get(rowsRef.current) === true && typeof ResizeObserver !== "undefined") {
        const known = drawnRef.current.get(id);
        if (
          known &&
          known.sessionId === sessionId &&
          known.width === rowWidthRef.current &&
          Boolean(known.actions) === Boolean(actions) &&
          known.status === (status || undefined)
        )
          return noQueue;
      }
      const measure = () => {
        if (!node.isConnected || node.dataset.rowId !== id) return;
        reportDrawn(
          id,
          version,
          acpmuxPerf.timed("row.measure", () => drawnHeightOf(node)),
          actions,
          status,
          collapsingRow(node),
        );
      };
      pendingMeasures.current.set(node, measure);
      // A changed row or an unmount cannot leave an old version queued for a later commit.
      return () => {
        if (pendingMeasures.current.get(node) === measure) pendingMeasures.current.delete(node);
      };
    },
    [reportDrawn, sessionId, tokenRows],
  );
  // All of a commit's reports land in one update, before the frame paints.
  /// Rows whose drawn height changed since the last placement, which places again from the first.
  const changedDrawn = useRef(new Set<string>());
  /// The last placement, and the mounted range it was drawn with.
  const lastPlaced = useRef<
    | {
        rows: readonly AcpmuxRow[];
        drawn: DrawnHeights;
        layout: PlacedLayout;
        width: number;
        sessionId?: string;
        /// A new registry estimates every row again, so nothing is kept.
        registry: NativeRegistry;
        /// A new chat look (Minimal Mode included) estimates every row again too: nothing is kept.
        look: ReturnType<typeof useChatDisplay>;
        /// So does a new attachment view (inline or strip, UserBubble.tsx).
        view: typeof attachmentView;
        /// Placed over a live resize's partial estimate (rows out of view at the last width's heights).
        partial: boolean;
        first: number;
        last: number;
        /// Rows mounted outside that range because a margin drag's selection holds them (at most two).
        held: readonly number[];
      }
    | undefined
  >(undefined);
  /// The rows under a disclosure's height fold, moved by translate while only folding rows change
  /// size, and placed by one render when the fold ends (conversation/foldRide.ts).
  const foldRide = useRef<FoldRide | undefined>(undefined);
  const flushDrawn = useCallback(() => {
    if (!pendingDrawn.current.size) return;
    // Rows placed at their new heights drop a ride's translate first, or they move by it twice.
    foldRide.current?.release();
    const updates = pendingDrawn.current;
    pendingDrawn.current = new Map();
    // An equal report can correct a different height still queued at a lower priority.
    // Compare in the updater, against the state React rebases it onto, not drawnRef.
    setDrawn((current) => {
      let changes: Map<string, DrawnHeight> | undefined;
      for (const [id, entry] of updates) {
        if (sameDrawn(current.get(id), entry)) continue;
        changedDrawn.current.add(id);
        changes = changes ?? new Map();
        changes.set(id, entry);
      }
      return changes ? current.with(changes) : current;
    });
  }, []);
  /// Where a flowing drag's rows hang from (`FLOW_CLASS`). A view that follows the latest row shows
  /// what it shows once the width holds: the rows hang from the end of a box that ends where the
  /// latest row rests when the chat fills the view, and a strut above them takes the box's free
  /// room first, up to the room above the first row of a chat the view holds whole. So a chat that
  /// fits keeps its first row in place (#41170 F1), one that stops fitting goes up from its end, as
  /// the scroll to the end then shows it, and one that starts fitting comes down to its top and no
  /// further. The strut is for the chat's first row only: with older rows unmounted above, the rows
  /// hang from the end. Any other view hangs from the first mounted row's placed top, with
  /// `holdFlow` keeping the row the reader looks at where it shows. Set again
  /// by every commit while the rows flow, so a row that arrives or mounts during the drag moves the
  /// anchor with it. A placement over a live resize's partial estimate flows too: its mounted rows
  /// sit where it placed them, and the settle places every row again (#41170 F2). False when the
  /// mounted rows cannot flow (more than one range, a held row, a fold riding, rows in the thread
  /// that are not the placed ones).
  const anchorFlow = useCallback((): boolean => {
    const placed = lastPlaced.current;
    const threadNode = thread.current;
    const scroller = ref.current;
    if (!placed || !threadNode || !scroller) return (acpmuxPerf.span("flow.refused.unplaced", 1), false);
    if (placed.held.length > 0) return (acpmuxPerf.span("flow.refused.held", 1), false);
    if (placed.last <= placed.first) return (acpmuxPerf.span("flow.refused.empty", 1), false);
    if (foldRide.current?.riding) return (acpmuxPerf.span("flow.refused.riding", 1), false);
    const mounted = threadNode.querySelectorAll<HTMLElement>(":scope > .acpmux-row");
    if (mounted.length !== placed.last - placed.first) return (acpmuxPerf.span("flow.refused.mounted", 1), false);
    acpmuxPerf.span("flow.anchored", 1);
    const geometry = placed.layout.geometry;
    // Each mounted row's gap under it, its margin in the flow; the last one has no row under it there.
    // Written here and not by the row's render: outside a drag a row that arrives must cost what it
    // cost before the rows could flow. A length on every row's style, set again as the row under it
    // changed, made the page style the row before an arriving reply again in the commit of the
    // arrival, and in WebKit under load the reply then drew over that row's fold for a frame more
    // often (test/agent-pane-stream-row-overlap.test.ts: 8 first tries of 15 against 1 of 15).
    // A row keeps the length after the drag, where no rule reads it; the next drag writes only the
    // ones that changed.
    for (let at = 0; at < mounted.length; at += 1) {
      const gap = at + 1 < mounted.length ? `${geometry.gapAt(placed.first + at + 1)}px` : "0px";
      const style = mounted[at]!.style;
      if (style.getPropertyValue(FLOW_ROW_GAP) !== gap) style.setProperty(FLOW_ROW_GAP, gap);
    }
    const end = followingRef.current;
    // Read before a length is written below, where it was read to choose the anchor.
    const scrolled = end ? scroller.scrollTop : 0;
    const live = liveResize.current;
    if (end) {
      live.hold = undefined;
      const at = geometry.topAt(placed.last - 1) + geometry.heightAt(placed.last - 1);
      // The room under the latest row at rest, taken from the scroll content's own height (100%: the
      // taller of the placed height and the view). Over a chat taller than the view that is the
      // latest row's placed bottom; over one that fits, the same room above the view's lower edge.
      const under = latestLayout.current.layout.totalHeight - THREAD_TOP - at;
      writeFlow(live, threadNode, "end", `calc(100% - ${under}px)`);
      // The first row's place when the view holds the whole chat, in the thread's coordinates at
      // this scroll offset. No such place while older rows are unmounted above the first mounted
      // one: the strut then gets the box's own length, which leaves the rows at its end.
      const whole = placed.first === 0 ? geometry.topAt(0) + scrolled : at;
      writeFlow(live, threadNode, "start", `${THREAD_TOP + whole}px`);
    } else {
      // The same mounted rows under the same held row keep the padding `holdFlow` gave them.
      if (live.hold?.row.isConnected && live.hold.first === placed.first && threadNode.classList.contains(FLOW_CLASS))
        return true;
      // The row to hold: the one held so far while it is still mounted, else the first the view
      // shows, read where it shows now (before this sets the rows' padding).
      if (!live.hold?.row.isConnected) {
        const view = scroller.getBoundingClientRect().top;
        live.hold = undefined;
        for (const row of mounted) {
          const box = row.getBoundingClientRect();
          if (box.bottom <= view) continue;
          live.hold = {
            row,
            at: box.top - view,
            pad: 0,
            first: placed.first,
            top: scroller.scrollTop,
          };
          break;
        }
      }
      const pad = THREAD_TOP + geometry.topAt(placed.first);
      if (live.hold) Object.assign(live.hold, { pad, first: placed.first });
      writeFlow(live, threadNode, "start", `${pad}px`);
      writeFlow(live, threadNode, "end", undefined);
    }
    threadNode.classList.toggle(FLOW_END_CLASS, end);
    return true;
  }, []);
  /// Keeps the held row (`anchorFlow`) where the view showed it: rows above it that rewrapped taller
  /// or shorter take their difference from the thread's padding, so what the reader looks at holds
  /// still under the drag instead of drifting and snapping back once the width holds. Run by the
  /// commit each width step renders (its layout effect), so one row's box is read once a frame.
  /// Never below 0: at the chat's top the rows above grow down.
  const holdFlow = useCallback(() => {
    const hold = liveResize.current.hold;
    const threadNode = thread.current;
    const scroller = ref.current;
    if (liveResize.current.flow === undefined || !hold || !threadNode || !scroller) return;
    if (!hold.row.isConnected) return;
    // A scroll during the drag (a wheel, a fling still coasting) moves the held row by its own
    // distance: that is the reader's, not a rewrap, and the padding keeps it.
    hold.at -= scroller.scrollTop - hold.top;
    hold.top = scroller.scrollTop;
    const shift = hold.row.getBoundingClientRect().top - scroller.getBoundingClientRect().top - hold.at;
    if (Math.abs(shift) < 0.5) return;
    const pad = Math.max(0, hold.pad - shift);
    if (pad === hold.pad) return;
    hold.pad = pad;
    writeFlow(liveResize.current, threadNode, "start", `${pad}px`);
  }, []);
  // A live drag's rows go into normal flow from where they were placed, so the browser rewraps
  // them at each width in its own layout pass, with no React pass and no height read (Leo,
  // 2026-11-11: "the dragging responsiveness is slow for agent chat but fast for browser hmmm").
  const startFlow = useCallback(() => {
    if (!anchorFlow()) return;
    acpmuxPerf.span("flow.started", 1);
    thread.current!.classList.add(FLOW_CLASS);
    liveResize.current.flow = rowWidthRef.current;
    liveResize.current.flowSession = sessionIdRef.current;
    setFlowWidth(rowWidthRef.current);
    // The rows' first frame in flow keeps the held row where it showed.
    holdFlow();
  }, [anchorFlow, holdFlow]);
  /// Reports the height `target` (a drawn row) lays out at now.
  const reportRow = useCallback(
    (target: HTMLElement) => {
      const shown = rowsRef.current;
      const index = Number(target.getAttribute("aria-posinset")) - 1;
      const row = shown[index];
      // With the frame's own flag: a height reported without it is taken for a stale one.
      if (row && row.id === target.dataset.rowId)
        reportDrawn(
          row.id,
          row.version,
          drawnHeightOf(target),
          keepsReplyRoom(row, nextDrawnRow(shown, index)),
          statusEdge(row, nextDrawnRow(shown, index), prevDrawnRow(shown, index)),
          collapsingRow(target),
        );
    },
    [reportDrawn],
  );
  /// Places `target` at the height it lays out at now, in this task, before the browser scrolls: a
  /// fold that just landed (`settleFoldsIn`) must not wait for the observer's next delivery.
  const placeRowNow = useCallback(
    (target: HTMLElement) => {
      reportRow(target);
      if (changesDrawn(drawnRef.current, pendingDrawn.current)) flushSync(flushDrawn);
    },
    [reportRow, flushDrawn],
  );
  // The ride lives across renders; it reports through the current session's `reportRow`.
  const reportRowRef = useRef(reportRow);
  reportRowRef.current = reportRow;
  // The rows leave the flow and are placed at the width that holds, measured before the frame
  // paints, in this one task: no frame draws them at their old places at the new width.
  /// Reads every mounted row at the committed width, placing again only for a height that changed.
  const readMounted = useCallback(() => {
    const threadNode = thread.current;
    if (threadNode)
      for (const row of threadNode.querySelectorAll<HTMLElement>(":scope > .acpmux-row")) reportRowRef.current(row);
    if (changesDrawn(drawnRef.current, pendingDrawn.current)) flushDrawn();
    else pendingDrawn.current = new Map();
  }, [flushDrawn]);
  /// Ends a flowing drag: the rows leave the flow and are placed at the width that holds. From its
  /// timer (a task) that is one synchronous render before the frame paints, and its rows are read
  /// once it committed. From a commit (`inCommit`) no render can run inside it: the settle is
  /// scheduled, and the first commit that does not flow reads the rows (`readAfterSettle`).
  const endFlow = useCallback(
    (inCommit: boolean) => {
      const live = liveResize.current;
      const from = live.flow;
      if (from === undefined) return;
      acpmuxPerf.span("flow.ended", 1);
      live.flow = undefined;
      live.flowSession = undefined;
      live.hold = undefined;
      const threadNode = thread.current;
      threadNode?.classList.remove(FLOW_CLASS, FLOW_END_CLASS);
      threadNode?.style.removeProperty(FLOW_VARS.end);
      threadNode?.style.removeProperty(FLOW_VARS.start);
      live.wrote = undefined;
      if (inCommit) {
        readAfterSettle.current = true;
        setFlowWidth(undefined);
        settleResize();
        return;
      }
      // At a new width the settle's render measures its rows at it (RowFrame's rowWidth). A width
      // that came back to the one the rows were placed at renders nothing new: read them then.
      flushSync(() => {
        setFlowWidth(undefined);
        settleResize();
      });
      if (rowWidthRef.current === from) flushSync(readMounted);
    },
    [readMounted],
  );
  // Every commit while the rows flow moves their anchor with what it mounted; one that cannot flow
  // (another chat, a held row, a second range) ends the flow and places the rows after it.
  useLayoutEffect(() => {
    const live = liveResize.current;
    if (live.flow !== undefined) {
      if (live.flowSession !== sessionId || !anchorFlow()) endFlow(true);
      else holdFlow();
      return;
    }
    if (readAfterSettle.current && !renderedFlowing.current) {
      readAfterSettle.current = false;
      readMounted();
    }
  });
  // A transcript that unmounts mid-drag leaves no flow (the box's effect cleared the settle's timer).
  // The render's copy goes with it, for a transcript whose effects stop and start again.
  useEffect(
    () => () => {
      liveResize.current.flow = undefined;
      liveResize.current.hold = undefined;
      setFlowWidth(undefined);
    },
    [],
  );
  const rideOptions: FoldRideOptions = {
    placed: (row) => {
      const id = row.dataset.rowId;
      return id === undefined ? undefined : drawnRef.current.get(id)?.height;
    },
    height: drawnHeightOf,
    drawn: () => drawnRef.current,
    held: () => (foldHolding(foldAnchor.current) ? foldAnchor.current : undefined),
    finish: (rows) => {
      for (const row of rows) reportRowRef.current(row);
      if (changesDrawn(drawnRef.current, pendingDrawn.current)) flushSync(flushDrawn);
      else pendingDrawn.current = new Map();
    },
  };
  if (foldRide.current == null) foldRide.current = new FoldRide(rideOptions);
  // Another chat's rows ride nothing of this one's.
  useEffect(() => () => foldRide.current?.reset(), [sessionId]);
  /// Whether the row a held line sits in is drawn at a height the transcript has not measured yet (its
  /// observer reports it after the browser lays it out, which under load comes long after the click).
  /// One row, one read.
  const heldRowUnplaced = (line: HTMLElement): boolean => {
    const row = line.closest<HTMLElement>(".acpmux-row");
    if (!row) return false;
    const known = row.dataset.rowId ? drawnRef.current.get(row.dataset.rowId)?.height : undefined;
    const height = drawnHeightOf(row);
    return known !== undefined && height !== undefined && Math.abs(height - known) >= 0.5;
  };
  const observer = useMemo(
    () =>
      typeof ResizeObserver === "undefined"
        ? undefined
        : new ResizeObserver((entries?: ResizeObserverEntry[]) => {
            // A flowing drag's rows rewrap every frame at a width they were not placed at: their
            // heights are read once, when the width holds (`endFlow`).
            if (liveResize.current.flow !== undefined || renderedFlowing.current) return;
            const targets = (entries ?? []).map((entry) => entry.target as HTMLElement);
            const measure = () => {
              for (const target of targets) reportRow(target);
            };
            measure();
            // A late size change (a font loading) must not paint a frame of overlap first. Sizes
            // that did not change render nothing: a synchronous render here for nothing was the
            // "ResizeObserver loop completed with undelivered notifications" while streaming.
            // While the view follows the latest row the rows are placed before paint, and measured
            // again after each render until they hold: that render also commits a streaming reply's
            // next reveal step, which the observer (a target at the same depth once a frame) would
            // report a frame late. The observer fires only when a row's size changes (a streaming
            // reply: once a new line, not once a chunk). Batched (#24602), the render landed after
            // the paint whenever the main thread was busy: the frame drew the reply a line taller
            // over the live line under it, and the view a line short (agent-pane-stream-jitter's
            // settle, 23px on the CI runner). A reader scrolled up keeps the batch; a disclosure's
            // height animation is placed before paint too, or the rows below overlap its body.
            // A ride that gives way below takes its translates off now: the rows go to their places
            // before this frame paints too, not in a batch after it.
            const rode = foldRide.current!.riding;
            if (!changesDrawn(drawnRef.current, pendingDrawn.current)) {
              pendingDrawn.current = new Map();
              // Back at their placed heights: a ride keeps no translate for a change undone.
              foldRide.current!.settled(targets, !followingRef.current && !bottomStackFold.current);
            }
            // Only rows whose own fold plays changed, away from the bottom: the rows under them ride
            // the change by translate, and the transcript renders once when the fold ends, not on
            // every frame of it (Leo, 2026-11-09: "It just, like, lags pretty heavily").
            // Otherwise (and when a ride gives way) every translate goes before the rows are placed.
            else if (
              !followingRef.current && !bottomStackFold.current
                ? foldRide.current!.ride(targets)
                : foldRide.current!.release()
            )
              return;
            // A reader scrolled up keeps the batch only while the row that changed is out of sight:
            // a reply growing on screen while the view does not follow it (the reader scrolled up a
            // little to read it, or a jump or chase let go of the bottom) was placed in a task after
            // the paint, so the frame drew its new line over the tool call or live line under it,
            // and on a busy main thread for as long as that task waited (Leo, 2026-11-11: "esp when
            // it's lagging, there's a breif moment where ther'es overlapping text between the sent
            // out text (from you) and the subequent tool calls/thinking"). A row in sight is placed
            // before paint, as a followed view's is.
            // Not while a key or pointer event waits: a synchronous render here holds the typed
            // character behind it, so the frame's own commit places the rows instead.
            else if (
              !inputPending() &&
              (rode ||
                followingRef.current ||
                targets.some(heightFoldInFlight) ||
                foldHolding(foldAnchor.current) ||
                inSight(ref.current, targets))
            ) {
              // Placed, then read again, until the heights hold (at most 3 passes): the placement's
              // render also commits a streaming reply's next reveal step, which this observer (the
              // rows are one depth) reports only in the next frame. Left to a commit after the paint,
              // the turn's end moved the rows by that step at once (turn-transition-jumps `end`,
              // 29 px; send-stream-motion). A second pass runs only when a height moved under the
              // first, and none while input waits (above): a streamed token still places once.
              // Still moving after them (or input came): the next commit places it.
              for (let pass = 0; pass <= 3; pass += 1) {
                if (!changesDrawn(drawnRef.current, pendingDrawn.current)) {
                  pendingDrawn.current = new Map();
                  break;
                }
                if (pass === 3 || (pass > 0 && inputPending())) {
                  flushDrawn();
                  break;
                }
                acpmuxPerf.timed("flush.drawn", () => flushSync(flushDrawn));
                measure();
              }
            } else flushDrawn();
          }),
    [reportRow, flushDrawn],
  );
  useEffect(() => () => observer?.disconnect(), [observer]);
  // A CSS motion that starts out of the view draws at its end (cmuxterm-hq
  // docs/design/transcript-animation-rules.md, rule 1): the overscan's rows the reader cannot see play
  // nothing (conversation/offscreenMotion.ts).
  useLayoutEffect(() => endOffscreenMotion(ref.current), []);
  // Forget rows that left the transcript (a session switch, older history unloaded).
  const previousRowList = useRef<readonly AcpmuxRow[] | undefined>(undefined);
  const previousTail = useRef<readonly AcpmuxRow[]>(NO_ROWS);
  useEffect(() => {
    const previous = previousRowList.current;
    previousRowList.current = rows;
    // The tail these rows end with, against the one the previous rows ended with (kept with them,
    // whatever happened since: another view's rows in between are not this tail).
    const tail = queuedTail ?? NO_ROWS;
    const lastTail = previousTail.current;
    previousTail.current = tail;
    // Rows that only grew below the ones there (a streaming turn) left none behind, also when the
    // running turn's line stays last under them (`below`, conversation/turns.ts).
    if (previous && previous.length <= rows.length) {
      // So do the waiting agent messages after it (conversation/queuedMessages.ts), the same tail
      // array while the queue holds: checked by identity, not row by row. A changed tail scans.
      const keptTail = lastTail === tail ? tail.length : 0;
      const before = previous.length - 1 - keptTail;
      const line =
        keptTail +
        (before >= 0 &&
        previous[before]!.below === true &&
        rows[rows.length - 1 - keptTail]?.id === previous[before]!.id
          ? 1
          : 0);
      // `rowsChange` already found the first changed object while this render was prepared. Reuse
      // that boundary instead of copying the unchanged prefix and walking it a second time for
      // every streamed snapshot. Only the changed suffix can have lost a row id.
      const change = rowsChange.current;
      const start = change?.base === previous && change.rows === rows ? change.from : 0;
      let sameIds = true;
      for (let index = Math.min(start, previous.length - line); index < previous.length - line; index += 1) {
        if (previous[index]!.id !== rows[index]?.id) {
          sameIds = false;
          break;
        }
      }
      if (sameIds) return;
    }
    const ids = new Set(rows.map((row) => row.id));
    const cache = measurementCache.current;
    for (const id of cache.keys()) if (!ids.has(id)) cache.delete(id);
    setDrawn((current) => current.retain((id) => ids.has(id)));
  }, [rows, queuedTail]);
  useLayoutEffect(() => {
    // Child layout effects enqueue; all sibling DOM writes finish before this parent effect.
    // Read the dirty rows together, then apply the existing pre-paint placement correction.
    // No frame/task deferral, and no scan of the mounted window or full transcript.
    // A flowing drag keeps them for the render that ends it: a height read now is at another width.
    if (liveResize.current.flow !== undefined || renderedFlowing.current) return;
    const measures = pendingMeasures.current;
    pendingMeasures.current = new Map();
    for (const measure of measures.values()) measure();
    flushDrawn();
  });
  // Minimal Mode draws another agent's closed message as its line alone (IncomingMessageCard.tsx):
  // a toggle forgets those rows' drawn heights, so rows offscreen place by the new estimate instead of
  // their old card's height, and marks them changed so the placement starts from the first of them
  // (the toggle's own render places every row again: `look` above). One O(rows) pass, once per
  // Minimal Mode toggle, never per event or token; a mounted row reports its new height as usual.
  const drawnMinimal = useRef(chatLook.minimal);
  useLayoutEffect(() => {
    if (drawnMinimal.current === chatLook.minimal) return;
    drawnMinimal.current = chatLook.minimal;
    const incoming = new Set<string>();
    for (const row of rowsRef.current) if (row.incoming?.kind === "message") incoming.add(row.id);
    if (!incoming.size) return;
    for (const id of incoming) pendingDrawn.current.delete(id);
    setDrawn((current) => {
      let changes: Map<string, undefined> | undefined;
      for (const id of incoming) {
        if (!current.has(id)) continue;
        changes = changes ?? new Map();
        changes.set(id, undefined);
        changedDrawn.current.add(id);
      }
      return changes ? current.with(changes) : current;
    });
  }, [chatLook.minimal]);
  const didOpenAtLatest = useRef(false);
  /// The sends this chat's view has taken in (`sends`): a new one puts the view at the latest message.
  const seenSends = useRef(sends);
  /// Prompt identities captured on the send's first snapshot. Kept separately from enteringRows:
  /// a burst can exceed the live-entry threshold, while its thinking row still belongs to the send.
  const [sentPromptIds, setSentPromptIds] = useState(() => new Set<string>());
  /// Sends are counted before the async client registers its optimistic prompt. Keep a bounded number
  /// of sends waiting for that prompt to arrive so a later thinking row still gets the send marker.
  /// This is render-phase state, alongside `sendsAt`, so the counter does not add a mutable ref read
  /// to the render path (React Doctor's no-ref-current-in-render rule).
  const [pendingSentPromptCount, setPendingSentPromptCount] = useState(0);
  /// A prompt was sent before the chat opened (while its tail still fits): it opens at the latest
  /// message, not at the reader's old place.
  const sentBeforeOpen = useRef(false);
  /// Until when rows that come move the followed view on a send's glide (`followGlide.sent`): the
  /// sent prompt's row and its reply's first rows can land a commit or two after the send itself.
  const sendRiseUntil = useRef(Number.NEGATIVE_INFINITY);
  /// Until when rows that come join the send's own rise on the bubble's clock (`followChase` `sent`):
  /// the send motion's length. A row landing later in `sendRiseUntil` (a delayed thinking or tool
  /// row) arrives on the arrival step instead of starting the send curve over after the bubble rested.
  const sendClockUntil = useRef(Number.NEGATIVE_INFINITY);
  /// The latest send came while a turn ran (a steer): its row lands above the running work, an
  /// arrival like any other (followChase's arrival step), not the send's rise from the composer.
  /// Set while rendering, as React adjusts state on a prop change, so the passes after this
  /// render read it (`sendsAt`: the sends it was last set for).
  const [sendsAt, setSendsAt] = useState(sends);
  const [steered, setSteered] = useState(false);
  if (sends !== sendsAt) {
    setSendsAt(sends);
    setSteered(working);
  }
  // Under the scrollbar fade (the host theme sets it, applyPaneTheme), the scrollbar fades in and
  // out with the scrolling marks, and to its near look and back as the pointer reaches its bar and
  // leaves (scrollers.ts; thumbMotion.experiment.ts).
  useEffect(
    () =>
      ref.current ? followShownScrollerFade(ref.current, SHOWN_INK_PROPERTIES, experimentArm(thumbMotion)) : undefined,
    [],
  );
  // Read aloud speaks one of this chat's answers: moving to another session (or closing the
  // transcript) stops it, so it neither talks over the next chat nor says Stop reading on return.
  useEffect(() => () => stopReadingAloud(), [sessionId]);
  // A cold open's rows fade in on the first frame that draws them, before that frame paints.
  const fadedOpen = useRef<number | undefined>(undefined);
  /// The open (`opened` above) whose cold fade played: a later cold open of the same open does not.
  const fadedSession = useRef<ChatOpen | undefined>(undefined);
  /// The chat switch motion's arm, read once per transcript (a changed arm applies on reload).
  const [switchArm] = useState(() => experimentArm(chatSwitchMotion));
  /// The fade running on this transcript. The transcript stays mounted across a switch, so a fade
  /// ends with the chat it was for: a cached chat opened mid-fade shows whole on its first frame,
  /// not under the last chat's fade, and a transcript that unmounts leaves none running.
  const openFade = useRef<Animation | undefined>(undefined);
  /// A cold-opened chat held unseen until its parts settle (unsettledHeights.ts `holdUntilSettled`):
  /// it too ends with the chat it was for, so a chat opened during it is not held or faded in for it.
  const openHold = useRef<(() => void) | undefined>(undefined);
  useLayoutEffect(
    () => () => {
      openFade.current?.cancel();
      openFade.current = undefined;
      openHold.current?.();
      openHold.current = undefined;
    },
    [sessionId],
  );
  // CHAT SWITCH MOTION (experiment chat-switch-motion, off by default): opening another chat plays
  // its rows, title and Session Info in as one movement, on the first frame the new chat's rows draw
  // (cached: the frame the switch lands; cold: when its rows arrive). Not the first chat a page shows,
  // and not an empty chat's first send. This effect only notes the switch (before the cold-open fade
  // below reads it); the play runs in the transcript's last layout effect, after the new chat's rows
  // are placed and scrolled (search "CHAT SWITCH PLAY"). The play's animations end on their own; the
  // next switch starts from where they are, and the transcript unmounting cancels them.
  const switchPlay = useRef<ChatSwitchPlay | undefined>(undefined);
  const switchFrom = useRef(sessionId);
  const switchPending = useRef(false);
  const hasRows = rows.length > 0;
  useLayoutEffect(() => {
    if (switchArm === "off" || switchFrom.current === sessionId) return;
    // A chat with no rows and none on the way (coldOpen undefined) is an empty chat: its first send
    // is not a switch.
    switchPending.current =
      switchFrom.current !== undefined && sessionId !== undefined && (hasRows || coldOpen !== undefined);
    switchFrom.current = sessionId;
  }, [sessionId, hasRows, coldOpen, switchArm]);
  useLayoutEffect(
    () => () => {
      switchPlay.current?.stop();
      switchPlay.current = undefined;
    },
    [],
  );
  /// Ends the hold of an opening chat whose parts are still settling (`holdUntilSettled`).
  useLayoutEffect(() => {
    if (coldOpen === undefined || rows.length === 0 || fadedOpen.current === coldOpen) return;
    fadedOpen.current = coldOpen;
    openFade.current?.cancel();
    openHold.current?.();
    // A switch under a chat switch motion (chatSwitch.ts) is drawn by its own play instead. A chat
    // this page already drew, or already faded in since it was opened, shows at once: a reload over
    // it (a reconnect, a cleared and refilled transcript) is not a first load (openBreakpoint.ts).
    const shownBefore = opened.drewBefore || fadedSession.current === opened;
    fadedSession.current = opened;
    const show = () => {
      openHold.current = undefined;
      openFade.current = switchPending.current || shownBefore ? undefined : fadeInOpenedChat(ref.current);
      onColdOpenShown?.(coldOpen);
    };
    // A chat read cold shows once the parts of its rows that draw a moment late (math, diagrams,
    // images the host reads) have their height, so its first shown frame is its last: held unseen
    // until then, it is placed at its latest row as they land, and fades in once, in place
    // (https://github.com/manaflow-ai/cmux/issues/48498). One shown before is not held again.
    if (shownBefore || switchPending.current) show();
    else openHold.current = holdUntilSettled(ref.current, show);
  }, [coldOpen, rows.length, onColdOpenShown, opened]);
  const previousSession = useRef(sessionId);
  // A layout effect: the first measure lands before the first paint, so a mounted transcript (a page
  // load, a new chat's first send, back from Harnesses) never draws a frame at a guessed size.
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const live = liveResize.current;
    /// The settle's timer: this run's own, cleared by its cleanup.
    let timer: ReturnType<typeof setTimeout> | undefined;
    /// The width held for LIVE_RESIZE_MS: the live resize is over.
    const settle = () => {
      timer = undefined;
      live.live = false;
      if (live.flow !== undefined) endFlow(false);
      // Settle whatever left a partial layout, even a step that came late enough to end the drag.
      else if (lastEstimate.current?.partial) settleResize();
    };
    if (live.rearm) {
      // The run before had a settle on the way: it keeps its time, LIVE_RESIZE_MS after the last width.
      live.rearm = false;
      timer = setTimeout(settle, Math.max(0, (live.served ?? live.at) + LIVE_RESIZE_MS - performance.now()));
    }
    /// A new width from the box's observer or the page's show (never the first measure). A second
    /// width within LIVE_RESIZE_MS of the last one being served is a live resize: its frames measure
    /// the rows in view, and the whole chat is measured once LIVE_RESIZE_MS after the last width was
    /// served. Judged from when serving finished, never from when it began, so a chat long enough to
    /// make a frame cost more than the window cannot read its own drag as a series of one-off
    /// resizes (conversation/liveResizeStep.ts).
    const widthStep = () => {
      const now = performance.now();
      live.live = continuesLiveResize(live, now);
      const next = stepLiveResize(live, now);
      live.steps = next.steps;
      live.at = next.at;
      // The settle waits from the end of this step's work, not its start (`servedWidth` below): a
      // 120 ms timer placed here fired between a long chat's 300 ms frames, so the settle ended the
      // drag's flow once a frame.
      clearTimeout(timer);
      timer = undefined;
      // Rows flow from the drag's third step on: two width changes close together can be a
      // scrollbar or a column settling, never a drag.
      if (live.steps >= LIVE_FLOW_STEPS && live.flow === undefined) startFlow();
    };
    /// Closes a width step once its own work is done: the render it forced and the measuring with
    /// it. The settle waits from here, and the next width is judged from here
    /// (conversation/liveResizeStep.ts), so neither depends on what serving a width costs. `stepped`
    /// is false when the box changed height alone, which starts no live resize.
    const servedWidth = (stepped: boolean) => {
      if (!stepped) return;
      live.served = performance.now();
      clearTimeout(timer);
      timer = setTimeout(settle, LIVE_RESIZE_MS);
    };
    /// This transcript's box as last measured (`shown` below compares the box on show with it).
    const box = { height: -1, width: -1 };
    /// `resized`: the box changed (not the first measure); `stepped` then hears a new width.
    const measure = (resized: boolean, stepped?: () => void) => {
      box.height = node.clientHeight;
      box.width = node.offsetWidth;
      // A box not laid out yet (hidden, 0 high) keeps the last height rather than showing no rows.
      if (resized || node.clientHeight > 0) setHeight(node.clientHeight);
      // The column's width is the scroller's with its scrollbar's lane (`lane`). Measured as the
      // box past the content width, never below 0, so a box with no layout box (jsdom) keeps its
      // content width.
      const nextLane = Math.max(0, node.offsetWidth - node.clientWidth);
      const nextWidth = node.clientWidth + nextLane;
      if (resized && nextWidth !== widthRef.current) stepped?.();
      widthRef.current = nextWidth;
      setWidth(nextWidth);
      setLane(nextLane);
      const shellWidth = node.closest<HTMLElement>(".acpmux-shell")?.clientWidth;
      setPaneWidth(shellWidth && shellWidth > 0 ? shellWidth : node.clientWidth + nextLane);
      if (node.clientHeight > 0) lastTranscriptBox.height = node.clientHeight;
      if (node.clientWidth > 0) lastTranscriptBox.width = node.clientWidth + nextLane;
    };
    // Before the frame paints: a resized pane (its tab strip showing or hiding) otherwise drew the
    // transcript at its old offset and caught up a frame later.
    const observer = new ResizeObserver(() => {
      noteQueue();
      let stepped = false;
      runThen(
        () =>
          flushSync(() =>
            measure(true, () => {
              stepped = true;
              widthStep();
            }),
          ),
        // Even if the pass threw: widthStep cleared the settle's timer, and only this places it again.
        () => servedWidth(stepped),
      );
    });
    observer.observe(node);
    measure(false);
    // Shown again (a workspace switch back): the host sized the page while it was away, and the
    // ResizeObserver reports that size only in the rendering steps of the first frame back, after
    // that frame's own callbacks. When nothing committed at the new size while away, the first frame
    // drew the rows at the old box's offset, then the observer's pass moved them by the difference
    // (a shorter pane: 80 px up, the newest lines under the composer for a frame;
    // agent-pane-reveal-in-place.test.ts "hidden, shorter"). The box is read as the page shows, so
    // the placement pass for it runs before any frame draws (Leo, 2026-11-11: "a sliver of space at
    // the bottom that the newest few lines started from the top").
    const doc = node.ownerDocument;
    const shown = () => {
      if (doc.visibilityState === "hidden" || node.clientHeight <= 0) return;
      if (node.clientHeight === box.height && node.offsetWidth === box.width) return;
      noteQueue();
      let stepped = false;
      runThen(
        () =>
          flushSync(() =>
            measure(true, () => {
              stepped = true;
              widthStep();
            }),
          ),
        () => servedWidth(stepped),
      );
    };
    doc.addEventListener("visibilitychange", shown);
    return () => {
      observer.disconnect();
      doc.removeEventListener("visibilitychange", shown);
      // The timer is this run's: a next run (new inputs inside a live resize) starts it again.
      live.rearm = timer !== undefined;
      clearTimeout(timer);
    };
  }, [noteQueue, startFlow, endFlow]);
  const previousLayout = useRef<PlacedLayout | null>(null);
  const previousRows = useRef<readonly AcpmuxRow[]>(rows);
  let sentPromptIdsForRender = sentPromptIds;
  if (sessionChanged) {
    if (sentPromptIds.size !== 0) {
      sentPromptIdsForRender = new Set();
      setSentPromptIds(sentPromptIdsForRender);
    }
    if (pendingSentPromptCount !== 0) setPendingSentPromptCount(0);
  } else {
    let pending = pendingSentPromptCount;
    let promptIds = sentPromptIds;
    const observedSends = sendsAt;
    if (sends > observedSends) {
      pending = Math.min(SENT_PROMPT_ID_LIMIT, pending + sends - observedSends);
    } else if (sends < observedSends) {
      pending = 0;
    }
    // Only a send still waiting for its prompt row has anything to match. With none waiting, this
    // window was built and walked on every commit of a streaming chat for a result it could not use.
    if (pending > 0) {
      // "Which rows arrived since the last drawn pass": the rows the placement pass last committed
      // (`previousRows`, set in its layout effect, so it lags by a commit and not by a render pass).
      // A send's prompt row can land in the same commit that raises `sends` (a harness switch holds
      // it) or commits later, and this reads as an arrival either way. A row drawn a commit *before*
      // `sends` rises is not an arrival here, which is why a new chat's first prompt (startingSends
      // draws its row before `chat.new` answers) takes its send entrance from the mount path and not
      // from this matching, as it did before. Taking a snapshot of the send's own rows instead missed
      // the same-commit case, and taking one per row change was the render-phase setState this
      // change removes.
      const previous = previousRows.current;
      const first = Math.max(0, previous.length - ARRIVAL_TAIL);
      const last = Math.min(rows.length, previous.length + ARRIVAL_TAIL);
      const indexes = new Set<number>();
      for (let index = first; index < last; index += 1) indexes.add(index);
      for (let index = Math.max(0, rows.length - ARRIVAL_TAIL); index < rows.length; index += 1) indexes.add(index);
      for (const index of indexes) {
        const row = rows[index];
        // A later send can arrive before the row snapshot changes. A prompt already matched to
        // an earlier send must not consume that later send's pending slot again.
        if (
          pending > 0 &&
          row?.kind === "user" &&
          !isLineRow(row) &&
          row.id !== previous[index]?.id &&
          !promptIds.has(row.id)
        ) {
          if (promptIds === sentPromptIds) promptIds = new Set(sentPromptIds);
          rememberSentPromptId(promptIds, row.id);
          pending -= 1;
        }
      }
    }
    sentPromptIdsForRender = promptIds;
    if (promptIds !== sentPromptIds) setSentPromptIds(promptIds);
    if (pending !== pendingSentPromptCount) setPendingSentPromptCount(pending);
  }
  const previousViewport = useRef({ height, width, dockSpace, dockCard });
  /// `room`: the room kept under the last row (`room` below) as of the last placement pass.
  /// `reader`: the room the reader scrolled back down to (`readerKept` below): what the room held while they were
  /// scrolled up, kept under the last row once the view follows again, with the newest prompt it was
  /// kept under. Cut back to the stack's room there, it moved every row in view down by what was cut
  /// (Leo, 2026-11-20: "And then like we cut it out. We cut out the extra space. And so that is the
  /// jump."). It stays, a scroll away, until a send, Jump to latest or the next prompt's turn.
  /// `followed`: whether the last placement pass followed the latest row. `left`: the reader's own input
  /// (a wheel or key up, a scrollbar drag, a touch) let the latest row go since the view last followed it.
  /// Only then is there room they came back to: a layout pass that lets go and takes it again (the queue
  /// closing at the latest row) leaves none (agent-pane-queue-scroll-bottom).
  /// One ref for both, which the placement pass reads once (`roomUnderRows`).
  const heldRoom = useRef<HeldRoom>({ room: dockRoom, reader: { followed: false } });
  /// The composer card's height the room under the last row was last made for (`grown` below).
  const cardRest = useRef(0);
  /// The overlay dock (composer/dockMotion.experiment.ts): the composer card's height the room under
  /// the last row last took (`cardHold` below). Growth past it lies over the transcript's foot.
  const cardBase = useRef(0);
  /// How far the rows were drawn up by the composer's growth (`lift` below) as of the last pass.
  const appliedLift = useRef(0);
  /// The composer's growth kept out of the room under the last row (`lifted` below) as of that pass.
  const liftedBefore = useRef(0);
  /// Before the offset is written where rows lay out (a row's place), not where a lift draws them:
  /// the view stops following, and the commit that follows (from an event or a layout effect,
  /// before the frame paints) drops the lift without moving the offset by it.
  const unlift = useCallback(() => {
    if (!appliedLift.current) return;
    appliedLift.current = 0;
    followRef.current(false);
  }, []);
  const [, roomTaken] = useReducer((count: number) => count + 1, 0);
  /// Gives the room under the last row the stack's height again, at once, before Jump to latest
  /// follows again (`room` below).
  const takeRoom = useCallback(() => {
    const held =
      Math.abs(foldBase.current - dockTrayRef.current) > 0.5 ||
      Math.abs(cardBase.current - dockCardRef.current) > 0.5 ||
      Math.abs(noticeBaseRef.current - dockNoticeRef.current) > 0.5;
    foldBase.current = dockTrayRef.current;
    cardBase.current = dockCardRef.current;
    noticeBaseRef.current = dockNoticeRef.current;
    trayToggled.current = false;
    const kept = heldRoom.current.reader.kept !== undefined;
    heldRoom.current.reader = { followed: heldRoom.current.reader.followed };
    if (!held && !kept && Math.abs(heldRoom.current.room - dockRoomRef.current) <= 0.5) return;
    heldRoom.current.room = dockRoomRef.current;
    flushSync(() => {
      setNoticeBase(dockNoticeRef.current);
      roomTaken();
    });
  }, []);
  const thread = useRef<HTMLDivElement>(null);
  /// A turn's end folds its work in one motion (turnEndFold.ts): the rows drawn when it ended are
  /// read here, in the render that ends it, before its rows replace them; the fold plays once they
  /// are placed (the layout effect after the placement pass). It reads in render because the
  /// commit replaces those rows: by any effect they are gone. Only within one chat: another chat
  /// shown in their place is a switch, which draws whole on its first frame, never a fold.
  const turnEndCapture = useRef<TurnEndCapture | undefined>(undefined);
  const turnEnd = useRef<TurnEndFold | undefined>(undefined);
  // A turn that ended while the reader was away (its end among the frames held while the chat was
  // hidden) draws ended in place: folding from the rows drawn before they left moved its rows by
  // all that came since.
  // A Worked for held open while the reader was scrolled up over its work closes once they are back
  // at the latest row (App.tsx `heldWorked`). Closed in one frame, it brought everything above the
  // reply down by the work's height at once (Leo, 2026-11-14: "a resizing/re-adjustment of all chats
  // after tool calls get folded"): it folds in the turn's end motion instead, the rows over it
  // coming down together as the work leaves.
  const closingHeld = heldWorkedClosing?.current === true && rows !== rowsBefore;
  const turnEnds = endsTurn(rowsBefore, rows);
  if (sameChat && (turnEnds || closingHeld) && !pageAway())
    turnEndCapture.current = captureTurnEnd(thread.current, ref.current, rows, sessionId, !turnEnds);
  else if (!sameChat) turnEndCapture.current = undefined;
  // A subagent's view starts with its "Subagent of" pill (subagentRows.ts): pinned over the top, where
  // its row lies at rest: the scroller's top in the stage (under the header) and the thread's own top
  // padding. Read when it comes and as the view resizes, never per streamed token.
  const pinnedPill = paneRows[0]?.kind === SUBAGENT_OF ? paneRows[0] : undefined;
  const pinned = pinnedPill !== undefined;
  const [pinAt, setPinAt] = useState({ top: 0, pad: 0 });
  useLayoutEffect(() => {
    const scroller = ref.current;
    if (!pinned || !scroller || !thread.current) return;
    const style = thread.current.ownerDocument.defaultView?.getComputedStyle(thread.current);
    const pad = Number.parseFloat(style?.paddingTop ?? "") || 0;
    const top = scroller.offsetTop + pad;
    setPinAt((now) => (now.top === top && now.pad === pad ? now : { top, pad }));
  }, [pinned, height]);
  // What floats over the transcript's top (Jump to new, the pinned pill) starts at its clear line:
  // the lower of where the transcript shows (the scroller's top in the stage, plus the part a one-tab
  // pane's row floats over) and the header's bottom. The stage also holds the header (the pane's tab
  // row) above the scroller, so the stage's own top is the tab strip, and nothing placed from the
  // clear line can reach it, at any width or with any line under the header
  // (https://github.com/manaflow-ai/cmux/issues/40021). Observed: a header that resizes, or a
  // scroller that resizes (a line under the header pushes it down and shortens it, in a stage of
  // fixed height), moves the line before the frame paints.
  const overTop = pinned || (sinceKey !== undefined && onJumpToSince !== undefined);
  const [clearTop, setClearTop] = useState(topInset);
  useLayoutEffect(() => {
    const scroller = ref.current;
    if (!overTop || !scroller) return;
    const header = scroller.parentElement?.querySelector<HTMLElement>(":scope > .acpmux-header") ?? null;
    const measure = () => {
      const below = header ? header.offsetTop + header.offsetHeight : 0;
      const line = Math.max(scroller.offsetTop + topInset, below);
      setClearTop((now) => (now === line ? now : line));
    };
    const observer = new ResizeObserver(() => flushSync(measure));
    observer.observe(scroller);
    if (header) observer.observe(header);
    measure();
    return () => observer.disconnect();
  }, [overTop, topInset]);
  /// The footer of the turn the pointer is over (a turnSummary row's id).
  const pointedTurn = useRef<string | undefined>(undefined);
  /// Pointerover bubbles from every markdown descendant: moving between spans inside the same row
  /// does not scan for its turn's footer again.
  const pointedRow = useRef<string | undefined>(undefined);
  // The rows the cached footer was found in: a footer can appear, or stop being the last turn's,
  // while the pointer rests on the same row.
  const pointedRows = useRef<readonly AcpmuxRow[] | undefined>(undefined);
  const scrolledTo = useRef({ top: 0, atLatest: false });
  /// The disclosure line the reader just clicked, held where they clicked it while its fold plays
  /// (conversation/foldAnchor.ts).
  const foldAnchor = useRef<FoldAnchor | undefined>(undefined);
  // A disclosure at the very bottom keeps the bottom pinned while it opens or closes. A body in its
  // row (a tool group, a command, a received message) plays its own height (fold.ts), and each frame
  // of it is placed before paint with the offset moved to the new end, so the text above glides up
  // (or down) as one stack, on the fold's own clock, and the rows under the line keep their pixels
  // (Leo, 2026-10-31: "ANIMATION FOR IT GRACEFULLY ALL MOVING UP AS A STACK TOO FAST NO FLICKER
  // SMOOTH"). A toggle that adds or removes whole rows ("Worked for", `rows`) has no height to play:
  // that lays out once and the thread slides to it, its row marked so useFold settles at once. The
  // rows under it hold their pixels against that slide, and what rises is cut at the line they hold
  // (Leo 2026-11-03: "you guys adding fake space or whatever / it grows and shrinks right").
  type BottomStackFold = {
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
  const bottomStackFold = useRef<BottomStackFold | undefined>(undefined);
  const stopBottomStackFold = useCallback(() => {
    const stack = bottomStackFold.current;
    if (!stack) return;
    bottomStackFold.current = undefined;
    foldAnchor.current = undefined;
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
  useEffect(() => stopBottomStackFold, [stopBottomStackFold]);
  /// The content end a clicked disclosure keeps (foldAnchor.ts `foldRoomFor`): 0, or the view's end
  /// when the line was clicked. Closing a body at the transcript's end leaves that much room under
  /// the rows instead of letting the browser clamp the offset, which brought every row down by what
  /// closed (Leo, ask-a736047107: "WHEN I COLLAPSE IT JUMPS ME UP"). The room shrinks with the view's
  /// end as the reader scrolls up; a send or Jump to latest releases it. A close at the very bottom
  /// keeps none: it pins the bottom instead (`beginBottomStackFold`, Leo 2026-11-03).
  const [foldRoom, setFoldRoom] = useState(0);
  const foldRoomRef = useRef(0);
  foldRoomRef.current = foldRoom;
  /// The content's end without that room, as of the last render.
  const rowsEndRef = useRef(0);
  /// The prompt sent from the latest row that the view keeps at its top (`sendTopEnd`).
  const [sendTop] = useState(() => new SendTopHold());
  /// Shrinks the kept room to the view's end at `node`'s offset, and lets it go once nothing holds
  /// it (no fold in flight, the rows reach the view's end). O(1): a read of the offset and a compare.
  /// Lets the kept room go: a send or Jump to latest heads for the rows' own end. `now` commits it
  /// before the caller reads the layout (Jump to latest's target).
  const dropFoldRoom = useCallback(
    (now = false) => {
      if (!foldRoomRef.current) return;
      foldRoomRef.current = 0;
      if (now) flushSync(() => setFoldRoom(0));
      else setFoldRoom(0);
    },
    [setFoldRoom],
  );
  // Another chat starts with none (its first render already leaves it out, `keptEnd`).
  useLayoutEffect(() => dropFoldRoom(), [sessionId, dropFoldRoom]);
  /// Pins the bottom for what closes under `line`, its row's disclosure: the content's end stays at
  /// the view's end as the body shrinks, and the rows over it come down (the placement pass's
  /// `bottomStacking`). A close at the very bottom starts it at the click (`beginBottomStackFold`);
  /// a close a little over the end holds its line until the rows' end reaches the view's end, and
  /// pins the bottom from that pass on (`folding` below), so the line comes down only as far as the
  /// rest of the close would have left blank under the last row.
  const startBottomStack = useCallback(
    (node: HTMLElement, line: HTMLElement): boolean => {
      const row = line.closest<HTMLElement>(".acpmux-row");
      if (!row) return false;
      stopFollowMotion();
      stopJump();
      // The body itself supplies the height: any room kept by an older collapse goes, so neither
      // a second gap opens nor one stays after the close.
      dropFoldRoom();
      const drawn = new Map<Element, number>();
      for (const each of thread.current?.children ?? []) drawn.set(each, each.getBoundingClientRect().top);
      const stack: BottomStackFold = {
        toggle: line,
        row,
        beforeTop: layoutScrollTop(node),
        delta: 0,
        from: 0,
        drawn,
        pinned: node.scrollTop,
      };
      bottomStackFold.current = stack;
      // The gallery's shift gate reads this: the text above this row rises or falls on purpose.
      row.setAttribute("data-bottom-stack-fold", "");
      // The explicit toggle reacquires follow even a few pixels from the end. Streaming never does.
      followRef.current(true, "fold-close");
      stack.cleanupTimer = setTimeout(
        () => {
          if (bottomStackFold.current === stack) stopBottomStackFold();
        },
        Math.max(FOLD_HOLD_MIN_MS, foldMs(line) + FOLD_SETTLE_MS),
      );
      return true;
    },
    [dropFoldRoom, stopBottomStackFold, stopFollowMotion, stopJump],
  );
  /// The reader took the view (a wheel, a key, a drag up) from a fold at the very bottom: the fold
  /// lands at once and its row is placed at that height in this same task, so the browser clamps to
  /// the new end before the reader's scroll applies. What was left of a closing body's shrink never
  /// pulls a short scroll up back to the end, and no blank room stays under the rows.
  const landForReader = useCallback(
    (row: HTMLElement) => {
      settleFoldsIn(row);
      placeRowNow(row);
    },
    [placeRowNow],
  );
  /// A scroll made from code (scrollIntoView, Find, a link to a row) that moved the view off the end
  /// during a fold at the very bottom: the view is where the code put it. The fold lands there, as for
  /// the reader's own input (`cancelProgrammatic`), and the view stops following, or the stack's next
  /// pass (one per frame of the fold) or the follow pass after it pinned it back to the end (#34780).
  /// The stack's own pins and a closing body's clamp land at the end, so they never count, nor does
  /// the clamp to 0 when a close leaves the transcript shorter than the view (nothing left to scroll).
  const releaseBottomStackFold = (node: HTMLElement): boolean => {
    const stack = bottomStackFold.current;
    if (
      !stack ||
      Math.abs(node.scrollTop - stack.pinned) <= FOLLOW_BOTTOM_DEADBAND_PX ||
      node.scrollHeight - node.clientHeight <= FOLLOW_BOTTOM_DEADBAND_PX ||
      atFoldBottom(node.scrollTop, node.clientHeight, node.scrollHeight, FOLLOW_BOTTOM_DEADBAND_PX)
    )
      return false;
    stopBottomStackFold();
    // Before the landing: it can lay out again in its own pass (placeRowNow), which must not follow.
    if (followingRef.current) follow(false);
    scrolledTo.current = { top: node.scrollTop, atLatest: false };
    landForReader(stack.row);
    return true;
  };
  /// The scroller's offset as a held line (foldAnchor) last left it: the click, then each pass that
  /// put the line back.
  const holdTop = useRef<number | undefined>(undefined);
  /// A scroll made from code (scrollIntoView, Find, a link to a row) while a clicked line is held
  /// (foldAnchor; an open at the very end holds its line too, Codex parity): the view is where the
  /// code put it, so the hold lets go, or its next pass puts the line back (#34780, as
  /// `releaseBottomStackFold` does for a close at the end). Only the offset moving off where the
  /// hold left it counts: a layout change moves the line, not the offset, and a closing body's clamp
  /// lands at the end. A view still following the latest row moves its own offset down to the end
  /// until the hold's first pass lets go of it, so then only a move up counts: following never moves
  /// the offset up. A code scroll that lands before that first pass (the open's height reaches the
  /// layout a frame late under load) was put back by the hold, `put 736 -> 1408` (hq#10958).
  const releaseFoldHold = (node: HTMLElement): boolean => {
    const left = holdTop.current;
    if (
      !foldAnchor.current ||
      bottomStackFold.current ||
      left === undefined ||
      Math.abs(node.scrollTop - left) <= FOLLOW_BOTTOM_DEADBAND_PX ||
      (followingRef.current && node.scrollTop > left) ||
      atFoldBottom(node.scrollTop, node.clientHeight, node.scrollHeight, FOLLOW_BOTTOM_DEADBAND_PX)
    )
      return false;
    foldAnchor.current = undefined;
    holdTop.current = undefined;
    if (followingRef.current) follow(false);
    return true;
  };
  const trimFoldRoom = useCallback((node: HTMLElement) => {
    const kept = foldRoomRef.current;
    if (!kept) return;
    const holding = foldHolding(foldAnchor.current);
    // A view that follows the latest row again (the reader scrolled back to it) ends at the rows.
    if (followingRef.current && !holding) {
      foldRoomRef.current = 0;
      setFoldRoom(0);
      return;
    }
    const next = trimmedFoldRoom(
      kept,
      node.scrollTop + node.clientHeight,
      rowsEndRef.current,
      holding,
      node.clientHeight,
    );
    if (next === kept) return;
    foldRoomRef.current = next;
    setFoldRoom(next);
  }, []);
  /// Where the reader last saw it rest, measured in view; undefined until it is.
  const seenAnchor = useRef<ScrollAnchor | null | undefined>(undefined);
  /// The reader's place when the rows they were reading left the transcript while they were
  /// scrolled up (a reconnect or a rebuild drew a shorter tail, or no rows for a frame): held until
  /// those rows come back, then put back where it was (`heldReaderPlace`). Leo (2026-11-12): "THE
  /// PAGINATION/WHATEVER INFINITE SCROLL UP DOESN'T [...] WORK IT JUST [...] SENDS ME TO THE BOTTOM".
  /// The rows' going clamped the offset to the shorter tail's end, the bottom, and nothing found
  /// the reader's row again. Only the reader's own input, Jump to latest or a send lets it go.
  const heldPlace = useRef<ScrollAnchor | undefined>(undefined);
  /// When the reader last moved the transcript themselves (wheel, pointer, touch or key).
  const readerAt = useRef(Number.NEGATIVE_INFINITY);
  /// The last upward input has not yet been acknowledged by the native scroll event. A tiny real
  /// wheel at the old end must not be mistaken for the browser's clamp window during a layout correction.
  const readerUpPending = useRef(false);
  /// The reader's last downward scroll input, until an upward one: a wheel down that scrolls the
  /// transcript itself, a key that scrolls down (End, Page Down, the down arrow, Cmd-Down), or a
  /// scrollbar or touch drag down. Only a scroll that follows it within READER_SCROLL_MS and reaches
  /// the end brings following back. A press, a sideways wheel, a wheel an inner scroller takes, an
  /// up key or a stray pointer move after a lost release is no such input, and a layout change that
  /// lands at the end during their input hold leaves the reader where they are (Leo, 2026-11-07).
  const readerDown = useRef<{ at: number; input: string } | undefined>(undefined);
  // The room held above the loaded rows for the unloaded history (conversation/olderReserve.ts) goes
  // once the reader's view comes within a viewport of the loaded rows' top before a page has filled
  // it (`giveRoomNearTop` below), until the next page lands: the scroller then ends where the rows do,
  // so a scroll up stops there as at the top of any page. Held, a scroll up went into the room and
  // was put back at the loaded rows' top, which on a short tail is the bottom, at every wheel step
  // for as long as the page took (Leo, 2026-11-06: "it, like, thinks that I can, and then it doesn't
  // actually let me scroll up ... it pushes me back to the bottom"). `room` keeps a tail shorter than
  // the view where it was drawn, at the view's foot.
  const [roomGone, setRoomGone] = useState<{ sessionId?: string; firstId: string; room: number } | undefined>();
  // Scroll frames re-render with the same rows; only rows, width or the registry
  // change an estimate.
  const estimated = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    // Keep the session in this memo's inputs: its cache is cleared synchronously above even
    // when a host reuses the same rows array for a newly selected chat.
    const sameSession = measurementSession.current === sessionId;
    const cache = sameSession ? measurementCache.current : new Map();
    const lookChanged = measuredLook.current !== chatLook || measuredView.current !== attachmentView;
    measuredLook.current = chatLook;
    measuredView.current = attachmentView;
    const fresh = rowHeights.current.registry !== registry || !sameSession || lookChanged;
    if (rowHeights.current.registry !== registry || lookChanged) {
      rowHeights.current = { registry, heights: new WeakMap() };
      // A kept layout was measured with the look and registry before: none of it places a row now.
      if (sessionId !== undefined) keptLayouts.forget(sessionId);
    }
    const rowWidth = scaledRowWidth;
    // A live resize's frame at a new width: only the rows around the mounted ones are measured, the
    // rest keep the last layout's heights (O(rows in view), not O(rows)). Its settle (`resizeSettled`)
    // measures every row at the width that held; a partial layout is never a base to keep rows from.
    void resizeSettled;
    // What the last pass left, read once for this one (`estimateFrom`).
    const { kept, resizing, partial } = estimateFrom(
      fresh ? undefined : lastEstimate.current,
      lastPlaced.current,
      liveResize.current.live,
      rowWidth,
      sessionId,
      rows.length,
    );
    const layout = layoutConversation(
      rows,
      rowWidth,
      cache,
      (row, measureWidth) => registry[rowKind(row)]?.measure?.(row, measureWidth),
      // A chat shown again takes its rows' heights from the layout it left, by id, version and text: its
      // estimate measures only the rows that changed since (conversation/keptLayouts.ts).
      sameSession ? keptLayouts.seed(sessionId, rows, rowHeights.current.heights, gridScale()) : undefined,
      kept,
      sessionId,
      resizing,
      nearView(lastPlaced.current, rows, sessionId),
    );
    lastEstimate.current = {
      rows,
      layout,
      width: rowWidth,
      sessionId,
      partial,
    };
    // Prepared text is kept for the PREPARED_ROWS most recently measured rows (model.ts), whatever the
    // chat's length.
    return {
      layout,
      partial,
      ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0,
    };
  }, [rows, registry, sessionId, chatLook, attachmentView, scaledRowWidth, resizeSettled]);
  // What this chat laid out, for its next show in this page (conversation/keptLayouts.ts): references
  // only, so recording after each commit is O(1).
  useLayoutEffect(() => {
    const last = lastEstimate.current;
    if (sessionId === undefined || last?.sessionId !== sessionId) return;
    keptLayouts.record(sessionId, {
      drawn,
      rows: last.rows,
      heights: rowHeights.current.heights,
      look: chatLook,
      view: attachmentView,
      registry: rowHeights.current.registry,
    });
  }, [sessionId, drawn, estimated, chatLook, attachmentView]);
  // A row that draws moves only the rows below it: place them again, measuring none.
  const measured = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const rowWidth = scaledRowWidth;
    const last = lastPlaced.current;
    // The ids flushed into `drawn` since the last placement; kept until `drawn` itself changes.
    const drawnChanged = drawn !== last?.drawn;
    const changed = drawnChanged ? changedDrawn.current : new Set<string>();
    if (drawnChanged) changedDrawn.current = new Set();
    // Rows before the first that changed (by object, or by drawn height) keep their places. A
    // drawn height comes from a mounted row, so its index is looked for around the mounted range.
    let kept = 0;
    let rowsKept = 0;
    const changedAt: number[] = [];
    if (
      last &&
      last.width === rowWidth &&
      last.sessionId === sessionId &&
      last.registry === registry &&
      last.look === chatLook &&
      last.view === attachmentView &&
      // A placement over a live resize's partial estimate keeps nothing once every row is measured.
      !last.partial &&
      drawn.size > 0
    ) {
      const limit = Math.min(rows.length, last.rows.length);
      while (kept < limit && rows[kept] === last.rows[kept]) kept += 1;
      // A row after the kept ones can give the last kept reply its own action row (a steer or a
      // message after it): that reply is placed again, as layoutConversation estimates it again.
      let reply = kept - 1;
      while (reply >= 0 && rows[reply]!.incoming?.kind === "hidden") reply -= 1;
      if (
        reply >= 0 &&
        rows[reply]!.kind === "assistant" &&
        keepsReplyRoom(rows[reply]!, nextDrawnRow(rows, reply)) !==
          keepsReplyRoom(last.rows[reply]!, nextDrawnRow(last.rows, reply))
      )
        kept = reply;
      // The rows from here on are new or follow a new row: all placed again. Before it, only the
      // rows whose drawn height changed are (placeRowsIndexed's `from` and `changed`).
      rowsKept = kept;
      if (changed.size > 0) {
        let found = 0;
        const from = Math.max(0, last.first - DRAWN_SEARCH_ROWS);
        const to = Math.min(rows.length, last.last + DRAWN_SEARCH_ROWS);
        for (let index = from; index < to && found < changed.size; index += 1)
          if (changed.has(rows[index]!.id)) {
            kept = Math.min(kept, index);
            if (index < rowsKept) changedAt.push(index);
            found += 1;
          }
        // A held row (a margin drag's selection end) is mounted far from that range: looked up itself.
        for (const index of last.held)
          if ((index < from || index >= to) && rows[index] && changed.has(rows[index]!.id)) {
            kept = Math.min(kept, index);
            if (index < rowsKept) changedAt.push(index);
            found += 1;
          }
        if (found < changed.size) kept = 0;
      }
    }
    // Placed at the room the last pass held (conversation/olderReserve.ts), so kept rows keep their
    // places; the room is moved below only when a page lands or a row above the pin draws.
    const placedOrigin =
      last && last.sessionId === sessionId && last.width === rowWidth ? (last.layout.origin ?? 0) : 0;
    // Placed through the gap-aware index (placedHeightIndex.ts): a streamed token or a drawn
    // height reads only the rows it changed, in O(log rows) each, and copies no row's place.
    const placed =
      drawn.size === 0
        ? placedFromEstimate(estimated.layout, placedOrigin)
        : placeRowsIndexed(
            estimated.layout,
            // A row keeps its last drawn height until its new version is drawn: a streaming reply's
            // text appears after the version that holds it, so an estimate of the version ran ahead
            // of the drawn text, and its drawn height then pulled the view back a line or more at
            // every chunk (agent-pane-chat-column.test.ts under load). Growth comes from what is drawn.
            (index) => {
              const row = rows[index]!;
              const known = drawn.get(row.id);
              if (!known || known.sessionId !== sessionId || known.width !== rowWidth) return undefined;
              // A reply drawn before (or after) the row that gives it its own action row: its estimate
              // holds until it is drawn again (`hasReplyActions` reads only the next drawn row).
              const next = nextDrawnRow(rows, index);
              if (
                (row.kind === "assistant" && Boolean(known.actions) !== keepsReplyRoom(row, next)) ||
                known.status !== statusEdge(row, next, prevDrawnRow(rows, index))
              )
                return undefined;
              return known.height;
            },
            last && kept > 0
              ? {
                  layout: last.layout,
                  kept,
                  from: rowsKept,
                  changed: changedAt,
                }
              : undefined,
            placedOrigin,
            (index) => {
              const known = drawn.get(rows[index]!.id);
              return known?.collapsing === true && known.sessionId === sessionId && known.width === rowWidth;
            },
          );
    // Rows that left the top of a window the reader scrolls down (direct.ts `shedWindowTop`): their height goes
    // into the room above, so the rows in view and the scrollbar's thumb stay where they were.
    const leftAbove =
      last && last.sessionId === sessionId && last.width === rowWidth
        ? heightLeftAbove(last.rows, (index) => last.layout.geometry.topAt(index), rows)
        : 0;
    // A rail jump made another page the held window (direct.ts `jumpWindow`): no row is the last pass's, so the
    // room above is estimated again for the rows there now.
    if (last && last.sessionId === sessionId && canLoadNewer && rowsReplaced(last.rows, rows))
      olderRoom.current = undefined;
    else if (leftAbove > 0 && olderRoom.current)
      olderRoom.current = {
        ...olderRoom.current,
        room: olderRoom.current.room + leftAbove,
        end: olderRoom.current.end + leftAbove,
        height: olderRoom.current.height,
        unseeded: undefined,
      };
    // Gone until a page lands above the first row (a new first row): then estimated again, from the
    // rows that page brought.
    const gone =
      canLoadOlder && roomGone && roomGone.sessionId === sessionId && rows[0]?.id === roomGone.firstId
        ? roomGone
        : undefined;
    const reserved = gone
      ? { reserve: gone.room, state: undefined }
      : olderReserve(olderRoom.current, {
          sessionId,
          rows,
          rowTop: (index) => placed.geometry.topAt(index) - placedOrigin,
          rowsHeight: placed.totalHeight - placedOrigin,
          canLoadOlder,
          earlier: earlier?.length,
          promptCount,
          rose: roomRose,
          dragging: draggedHeight !== undefined,
          // Exact where this chat was held whole before at this width (transcriptHeights.ts).
          knownAbove: hasPromptTops(sessionId, rowWidth)
            ? (row) => knownPromptTop(sessionId, rowWidth, row.id)
            : undefined,
        });
    olderRoom.current = reserved.state;
    const layout = placedWithOrigin(placed, reserved.reserve);
    lastPlaced.current = {
      rows,
      drawn,
      layout,
      width: rowWidth,
      sessionId,
      registry,
      look: chatLook,
      view: attachmentView,
      partial: estimated.partial,
      first: last?.first ?? 0,
      last: last?.last ?? 0,
      held: last?.held ?? [],
    };
    return {
      layout,
      ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0,
    };
  }, [
    estimated,
    drawn,
    registry,
    rows,
    sessionId,
    chatLook,
    attachmentView,
    scaledRowWidth,
    canLoadOlder,
    earlier,
    promptCount,
    roomGone,
    roomRose,
    canLoadNewer,
    draggedHeight,
  ]);
  // A chat held whole keeps each prompt's measured place (transcriptHeights.ts), so the next open on
  // its tail holds exactly the older history's room. In idle time, once the rows stop changing for
  // PROMPT_TOPS_QUIET_MS: one pass over the rows per placement that settles, never per frame. Each
  // pass reads every prompt's top (O(rows)); armed on every placement, it ran between the frames of
  // a stream, about 3 ms of each token in a 35,000-row chat (bench/transcript-replay.bench.ts, god).
  useEffect(() => {
    // Rows away from the view still at another width's height (layoutConversation `near`) would keep
    // tops that are not this width's.
    if (canLoadOlder || canLoadNewer || !sessionId || rows.length === 0 || estimated.layout.remembered) return;
    const placed = measured.layout;
    const width = scaledRowWidth;
    const keep = () => {
      const origin = placed.origin ?? 0;
      const prompts: { id: string; top: number }[] = [];
      for (let index = 0; index < rows.length; index += 1)
        if (rows[index]!.kind === "user")
          prompts.push({
            id: rows[index]!.id,
            top: placed.geometry.topAt(index) - origin,
          });
      keepPromptTops(sessionId, width, prompts);
    };
    let idle: number | undefined;
    const quiet = setTimeout(() => {
      if (typeof requestIdleCallback === "function") idle = requestIdleCallback(keep, { timeout: 2000 });
      else keep();
    }, PROMPT_TOPS_QUIET_MS);
    return () => {
      clearTimeout(quiet);
      if (idle !== undefined) cancelIdleCallback(idle);
    };
  }, [canLoadOlder, canLoadNewer, sessionId, rows, measured, estimated, scaledRowWidth]);
  // The transcript's height is the rows' as drawn, under the thread's top padding: the rows' total
  // alone placed the latest row's bottom that far under the view.
  // The bottom stack's room follows the rows, so the latest row ends above it.
  // A followed view does not move down when a queued prompt's card leaves the stack: its offset stays,
  // and the room the card leaves stays under the last row for the prompt, which arrives as the latest
  // row a moment later. Dropping it moved the view down a card's height, and the prompt moved it back
  // up. That holds for a stack over the view's foot (its room shrinks) and under it (the view grows).
  // The room goes once rows grow into it, the reader leaves the latest row, the rows rewrap, or after
  // FLOOR_HOLD_MS (a prompt deleted from the queue never arrives), when the view moves down with it.
  // `rows`: the rows' own height the last pass held it over (`rowsShrank` below).
  const floor = useRef({ height: 0, width, sessionId, rows: 0 });
  const [, releaseFloor] = useReducer((count: number) => count + 1, 0);
  const floorTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(floorTimer.current), []);
  // Kept for a prompt that was sent, or while the reply streams, which fills it. A prompt withdrawn
  // with nothing streaming brings nothing: the room goes now (the queue's update can come before
  // acpmux's `queue_removed`, which then lets it go).
  const keptFor = working || [...heldFor.current].some((id) => !withdrawn.current.has(id));
  const kept = following && keptFor && floor.current.width === width && floor.current.sessionId === sessionId;
  const box = previousViewport.current;
  const footDropped = height - dockSpace > box.height - box.dockSpace;
  // Held as the end the view would have with all the stack's room (the composer's growth not taken
  // out, `lifted` below): the content end the reader sees is that less the lift on screen.
  // The room held is the stack's, never the rows': rows that got shorter under it (older history
  // landing above folds the turn it completes, a rebuild redraws the tail) bring the end up with them.
  // Held at the old end, the view kept its offset over the shorter rows and showed the room instead
  // of the latest rows until FLOOR_HOLD_MS let it go (agent-pane-settled-load, cold open after a
  // restart: the last turn's rows 3,221 px over the view for a second while the queue came back).
  const floorHeight = floorEnd({
    kept,
    height: floor.current.height,
    rowsBefore: floor.current.rows,
    rows: measured.layout.totalHeight,
    queueEnd:
      queueLeft.current && footDropped && previousLayout.current
        ? previousLayout.current.totalHeight + liftedBefore.current - box.height + height
        : undefined,
  });
  // The room under the last row is the stack's height while the view follows the latest row, so
  // the latest row ends above a composer that grows. Scrolled up, nothing under the stack is in view:
  // the room stays as it was, and a composer that grows or shrinks a line (Shift-Return, a wrap)
  // leaves the scroller's height, offset and scrollbar where they were (Leo 2026-10-20: a newline
  // made the transcript's scrollbar jump). Back at the latest row, the room is the stack's again.
  // Followed, the composer card's own growth since the view began following stays out of the room
  // too (`lifted` of it): the rows are drawn up by it instead (`lift`), so the latest row still ends
  // above the card while the scroller's height, offset and scrollbar stay as they were. The rest of
  // the stack (a queue, an ask) still makes room as before.
  const sessionSwitched = previousSession.current !== sessionId;
  // Overlay (the default; composer/dockMotion.experiment.ts, Leo, 2026-11-11: "do we even want stuff
  // to push up vs just simple... covering stuff?"): the composer growing a line as the person types
  // reflows no layout. While the view follows the latest row, the rows are drawn up with the card
  // (`lift`) in the frame it grows, on its own curve, so the rest gap holds over the taller card and
  // the line the reader is watching stays in sight: covering it while a reply streams hid what they
  // were reading (agent-pane-composer-rest-gap, the composer grown two lines: 10.5 px). A rise on the
  // card's clock is the fast version Leo asked about ("if we can get it fast, MAYBE"). Scrolled up,
  // the card's growth lies over the transcript's foot as glass and moves no row: the room stays as it
  // was (`heldRoom`). Where the view follows but cannot lift (`cardHold`: no rest height yet), the
  // growth is held out of the room until the rows move anyway, and Jump to latest or the reader's
  // wheel past the end gives it (`takeRoom`, `giveTrayRoom`). Push (the before) lifts the same way.
  const overlayDock = experimentArm(composerDockMotion) === "overlay";
  // What the last pass left (its layout effect writes them), read once for this pass.
  const openedAtLatest = didOpenAtLatest.current;
  // The room under the last row is one number with one owner (conversation/roomUnder.ts, model rule 9):
  // the stack's holds (`trayHold`, `cardHold`, `noticeHold`), the composer's `lifted`, the reader's
  // `heldRoom`, the sent prompt's `floor` and the collapse's `foldRoom` are its terms, and a hold the
  // stack keeps goes in the pass whose rows move (`rowsMoved`). What each term is for:
  // The content's end with all the stack's height as room, as the view would hold it unlifted.
  // The last row's turn gap and the rest gap's share (`dockRoom`) make the rest gap over the
  // floating stack, which the room keeps however tall the stack grows. The old permanent TRANSCRIPT_RUNWAY (removed after #23094) kept an extra blank
  // band here; the pinned-bottom layout below already follows streaming growth before paint.
  // What the reader opens or folds in the running tray moves no row (Leo, 2026-11-01: "there's a
  // layout shift when i expand it"): what it opens lies over the transcript's foot, as a menu over
  // the composer would, and the room under the last row keeps what it was (`trayHold`, the tray's
  // change since the room last took it). The room takes it once the rows move anyway: the next pass
  // whose rows grow (a reply streaming on, a send) gives it all (what opened) or as far as they grew
  // (what folded, whose room the rows fill), and Jump to latest or the reader's wheel past the end
  // gives it at once (`takeRoom`, `giveTrayRoom`). A line that joins or leaves the tray, and the
  // tray coming or going, make room as before; scrolled up the room is held anyway.
  // The rows' own growth: room taken or given above them for older history is none.
  // Never over the running turn's live line, though: while it is the last row, what the reader opens
  // lies over at most half the line's rest gap, and the rows make room for the rest at once, so the
  // line stays in sight over the stack from the send to the reply (Leo, 2026-11-04: "why does it
  // not display Thinking or anything here???", then "it appears and disappears????", the line under
  // a tray he had opened). What folds still moves no row.
  // The host's line above the composer moves no row either (Leo, 2026-11-16, after a restart: "it said
  // something went wrong with a retry button just above the composer ... and then it layout shifted"):
  // the line lies over the transcript's foot, within the rest gap the newest row keeps over the stack
  // (`restExtra`), so a line covers no row. A taller notice (its Details open, an app notice card)
  // moves no row either (Leo, 2026-11-22: "that message should not shift layout"): it lies over the
  // newest row's foot too, and the room takes all of it only once the rows move anyway (`noticeHold`,
  // the notice's height the room has not taken). So too at the chat's
  // first draw: after a restart the chat's saved copy drew without the line, and the live page that took
  // over with it as room drew every row up by it (first-load-after-restart.bench.ts MODE=refused). The
  // room a line leaves when it goes stays under the last row (a negative hold) until the rows move anyway
  // (they grew: a reply streaming on, a send) or Jump to latest gives it back (`takeRoom`).
  // Another chat starts from none taken: the last chat's base is not this one's.
  // Scrolled up the room is held anyway (`heldRoom`), and the base waits for the view to follow again.
  // Over a floating stack the newest line rests the rest gap over it (`dockRoom`, model.ts `restRoom`);
  // a turn footer's action row lies in the band under its reply, so that band comes first
  // (transcriptGrid.ts `restBand`). Docked in flow, the composer gap is the rows' own (`tailGap`).
  // A card that grew is drawn up by at most what the offset can take back: the view keeps more than
  // the follow deadband to scroll, so the reader's scroll up still leaves the latest row (and the
  // lift with it) in a transcript about a screen tall; the rest of the growth is room. While a room
  // held for a sent prompt (`floor`) reaches past the rows, it already covers the card: the lift on
  // screen stays as it is (shrinking it drew every row down by the queue card that left, and up
  // again as its prompt came), and growth meanwhile never adds to it. A card shorter than it was
  // draws the rows down within the room it left. The lift is the card's growth exactly, not rounded:
  // a composer line is fractional (22.75px at the chat font, #26523), and a rounded lift changed the
  // room under the rows by a fraction each line, which moved the content's rounded height and the
  // followed offset a pixel. The cap is whole pixels, as the offset.
  // Back at the latest row by the reader's own scroll, the room held while scrolled up stays under the
  // last row (`heldRoom.reader`) instead of being cut to the stack's while they look at it. A send or Jump
  // to latest gives the stack's room before following (`takeRoom`, the send), so theirs keeps none.
  // The content's end without the room a collapse left (`foldRoom`), which it is released against.
  // The held room less the lift, as the rows' end is: what the reader sees stays where it was drawn.
  // A collapse near the end keeps the content as tall as the view's end (`foldRoom`), so the offset
  // never clamps and the line the reader clicked stays on its pixel.
  // Where the rows draw against where they lay out: the followed offset of this layout against the
  // one the unlifted layout would hold. Negative draws them up, positive down.
  const tailGap =
    dockSpace > 0
      ? (measured.layout.restBand ?? 0)
      : (measured.layout.tailGap ?? TRANSCRIPT_COMPOSER_GAP * (measured.layout.scale ?? 1));
  // The rows' own growth: room taken or given above them for older history is none.
  const rowsGrew = measured.layout.totalHeight - (measured.layout.origin ?? 0) - rowsSeen.current;
  // The room under the rows for the newer history a reader scrolled far up let go of (conversation/newerReserve.ts).
  const newerRoomState = useRef<NewerReserve | undefined>(undefined);
  const newerRoom = useMemo(() => {
    const next = newerReserve(newerRoomState.current, {
      sessionId,
      height: measured.layout.totalHeight,
      canLoadNewer,
    });
    newerRoomState.current = next;
    return next.room;
  }, [measured, sessionId, canLoadNewer]);
  // Send to top (Leo, 2026-11-20, of how Claude Code desktop does its tool calls and sends: "it doesn't
  // layout shift... we shouldnt either!"): a prompt sent from the latest row goes to the top of the
  // view, and the turn fills the room under it. The content is kept at least as tall as that view's
  // end, so the follow rests there while the reply grows into the room and nothing in view moves. Once
  // the turn outgrows the view the room is gone and the follow goes on to the latest line, as before:
  // a long reply is still followed to its end (agent-pane-follow-live, dogfood run 6: a view left at a
  // reply's top had later turns arrive out of sight).
  // Held while the view follows; the reader scrolling, Jump to latest or another chat lets it go.
  // Only a prompt this pane sent (`sentPromptIds`): one from another device, a queued prompt the
  // agent took, a reconnect's or a hidden chat's rows land as before, followed at the latest row.
  // Outgrown: the rows reach past the held view's end, so there is no room left to keep.
  // The last pass's rows (its layout effect writes them), read once for this pass.
  const placedRows = previousRows.current;
  const under = roomUnder({
    following,
    sessionSwitched,
    openedAtLatest,
    overlayDock,
    dockSpace,
    dockRoom,
    dockTray,
    dockCard,
    dockNotice,
    restExtra,
    lineLast: rows.length > 0 && isLiveLine(rows[rows.length - 1]!),
    rowsGrew,
    rowsHeight: measured.layout.totalHeight,
    over: THREAD_TOP + topInset + tailGap,
    height,
    floor: floorHeight,
    liftedBefore: liftedBefore.current,
    deadband: FOLLOW_BOTTOM_DEADBAND_PX,
    held: heldRoom.current,
    prompt: following && !sessionSwitched ? newestPromptId(rows) : undefined,
    foldRoom,
    newerRoom,
    sendTop: (rowsHeight) =>
      sendTop.update(
        following && !sessionSwitched,
        openedAtLatest,
        placedRows,
        rows,
        sentPromptIdsForRender,
        measured.layout,
        topInset,
        height,
        rowsHeight,
      ),
    dragged: draggedHeight,
    bases: {
      tray: foldBase.current,
      trayToggled: trayToggled.current,
      card: cardBase.current,
      cardRest: cardRest.current,
      notice: noticeBase,
    },
  });
  const { room, lifted, lifting, lift, rowsHeight, rowsEnd, kept: readerKept } = under;
  rowsEndRef.current = rowsEnd;
  const totalHeight = under.total;
  const layout = useMemo(() => ({ ...measured.layout, totalHeight }), [measured, totalHeight]);
  // Each commit: what this pass kept for the reader (`readerKept`), and whether it followed, for the next.
  useLayoutEffect(() => {
    const followed = following && !sessionSwitched;
    heldRoom.current.reader = {
      followed,
      kept: readerKept,
      ...(!followed && heldRoom.current.reader.left ? { left: true as const } : {}),
    };
  });
  const liftRef = useRef(lift);
  liftRef.current = lift;
  const reportedLayout = useRef<typeof measured | null>(null);
  const reportedEstimate = useRef<typeof estimated | null>(null);
  // The old scroll state remains in React until the transition layout effect runs. Render the
  // new session from the top once so its first paint cannot reuse the previous chat's mounted rows.
  const unplacedScroll = sessionSwitched ? { top: 0, delta: 0 } : scrollRef.current;
  const origin = !sessionSwitched && ref.current ? scrollOrigin(ref.current) : 0;
  // Select the rows at this commit's anchored position before React reconciles them. Correcting
  // scrollTop only in the placement effect unmounted visible rows and flashed new copies on prepend.
  // Reader intent is synchronous; React's following state may still lag the wheel by one frame.
  // Followed, that position is the new layout's end: the placement pass settles there before this
  // commit paints. Read at the old offset, older history landing above a followed open picked the
  // rows that far down its new layout, turns above the view: the rows on screen unmounted, one frame
  // drew no row, and they came back as new nodes (Leo, 2026-11-11: "they just appear and disappear,
  // and then they constantly load and reload"). A follow the placement pass leaves where it is (a
  // jump's glide, the reader's held scroll input) keeps the old offset, as it does.
  // Each ref once, here: the last pass's layout and rows, and the scroller's input state.
  const placedBefore = previousLayout.current;
  const scroller = ref.current;
  const followHeld =
    jumpTarget.current !== undefined ||
    (scroller !== null && userScrollIntent(scroller).isHeld() && !followRequest.current?.());
  // A chat switched to opens where the placement pass will put it (the open below, `didOpenAtLatest`):
  // at the row it was left on (`openAt`), else at its latest row, or from the top when it fits. Its
  // first commit mounts the rows it shows there. Rendered from the top instead, a switch mounted the
  // chat's first rows, laid them out, placed the view at its end, and rendered and laid out again with
  // the rows there before its first paint: a second render, commit and forced layout of the whole
  // transcript (bench/settled-page.bench.ts chat_switch: about half of the switch).
  const switchedAt = sessionSwitched && openAt ? rows.findIndex((row) => row.id === openAt.rowId) : -1;
  const switchedLatest = Math.max(0, layout.totalHeight - height);
  const projectedTop = sessionSwitched
    ? layout.totalHeight <= height || draggedHeight !== undefined
      ? undefined
      : switchedAt < 0
        ? switchedLatest
        : Math.min(switchedLatest, layout.geometry.topAt(switchedAt) + openAt!.offset)
    : placedBefore === layout || draggedHeight !== undefined
      ? undefined
      : followingRef.current
        ? openedAtLatest && !followHeld
          ? Math.max(0, layout.totalHeight - height)
          : undefined
        : placedBefore
          ? preserveScrollAnchorTop({
              oldLayout: placedBefore,
              newLayout: layout,
              oldRows: placedRows,
              newRows: rows,
              liveTop: unplacedScroll.top - origin,
              anchorTop: unplacedScroll.top - origin,
              folds: foldRide.current?.handedFolds(placedRows, drawn),
            })
          : undefined;
  const renderScroll = projectedTop === undefined ? unplacedScroll : { ...unplacedScroll, top: projectedTop + origin };
  const renderFollowing = sessionSwitched || followingRef.current;
  // The content in view starts at the offset less `lift`: rows drawn up by it show content that much
  // further down.
  const shownTop = renderScroll.top - lift - origin;
  const ahead = scrollLeadRanges(
    layout,
    shownTop,
    renderScroll.delta,
    height,
    SCROLL_LEAD_STEPS,
    height * MAX_SCROLL_LEAD_VIEWPORTS,
    height * SCROLL_TRAIL_VIEWPORTS,
  );
  // The run of mounted rows the reader sees.
  const view = visibleLayoutRange(layout, shownTop, height);
  const range = ahead.find((each) => each.first <= view.first && view.first < each.last) ?? view;
  // The rows a viewport either side of where the reader was also mount, in a deferred render
  // between frames: a scroll then finds the rows it brings in already drawn and measured instead
  // of building them in its own frame. A jump past them mounts only what it shows.
  // The deferred offset moves in steps of WARM_STEP_VIEWPORTS: an offset that changed every pixel
  // gave each scroll frame a second render of the whole transcript (often restarted by the next
  // scroll event) that drew the same warm rows. The warm rows reach half a step past WARM_VIEWPORTS
  // either side, so a step leaves at least WARM_VIEWPORTS warm: the trail a scroll mounts behind the
  // view (SCROLL_TRAIL_VIEWPORTS) stays inside them, and a follow's rise that came and went with its
  // lead no longer took the row over the view out and put it back.
  // The deferred place is a row and a step into it (warmAnchor), from the place this commit draws:
  // a deferred offset into the stack, from a frame before older history landed above the view or a
  // followed reply grew, named rows that far down the new stack, and its warm rows came and went
  // at the edge of the view with every deferred render.
  // A scroll whose lead outruns the warm rows (a fling: half a viewport a frame or more) holds them
  // where they were: each frame's deferred render built a viewport either side of a view the next
  // frame had already left, a second transcript render and up to three viewports of rows a frame
  // that no frame showed. They catch up once the scroll's lead decays (SCROLL_LEAD_IDLE_MS).
  const warmStep = Math.max(1, height * WARM_STEP_VIEWPORTS);
  const liveWarmAt = Math.round((renderScroll.top - origin) / warmStep) * warmStep;
  const warmOutrun = Math.abs(unplacedScroll.delta) * SCROLL_LEAD_STEPS > height * WARM_VIEWPORTS;
  const warmAt =
    warmOutrun && heldWarmAt.current !== undefined
      ? heldWarmAt.current
      : warmAnchor(layout, rows, liveWarmAt, warmStep);
  heldWarmAt.current = sessionSwitched ? undefined : warmAt;
  const warmTop = warmAnchorTop(layout, rows, useDeferredValue(warmAt)) ?? liveWarmAt;
  // Above the view the warm rows reach HISTORY_VIEWPORTS: history to scroll up into, built between
  // frames as the rest of them are.
  const warm = visibleLayoutRange(
    layout,
    warmTop - height * HISTORY_VIEWPORTS - warmStep / 2,
    height * (1 + HISTORY_VIEWPORTS + WARM_VIEWPORTS) + warmStep,
  );
  // A followed view (a chat as it opens, at its latest row) mounts that history in the commit that
  // draws it, not a deferred render later: the deferred anchor of a chat's first commit is the top of
  // its rows, nowhere near the view, so its first painted frame held only the rows in view and
  // nothing to scroll up into. A followed view is anchored at its end, so rows drawn above it at their
  // estimate and measured move the offset, never a visible row. Scrolled up, the warm rows hold it.
  const history = renderFollowing
    ? visibleLayoutRange(layout, shownTop - height * HISTORY_VIEWPORTS, height * HISTORY_VIEWPORTS, 0)
    : undefined;
  const scrolledRanges = mergeRowRanges([
    ...(warm.last < range.first || warm.first > range.last ? ahead : [...ahead, warm]),
    ...(history ? [history] : []),
  ]);
  // A held row (gutterSelect.ts) is at its index, or as far from the end as it was when older history
  // pages in above it. At most two, so this reads two rows. Only when rows came in at both ends at once
  // is it looked for by id; the effect below then keeps where it was found (or drops a row that is
  // gone), so the next render reads it directly again.
  const held = heldRows?.session === sessionKey && !sessionChanged ? heldRows.rows : [];
  const heldAt = held.map(({ id, index, fromEnd }) =>
    rows[index]?.id === id
      ? index
      : rows[rows.length - fromEnd]?.id === id
        ? rows.length - fromEnd
        : rows.findIndex((row) => row.id === id),
  );
  const heldIndices = heldAt.filter((index) => index >= 0);
  // Where the moved rows were found, so the writeback runs again if rows move again before it commits.
  const heldMoved = held.some((each, at) => heldAt[at] !== each.index) ? `${rows.length}:${heldAt.join(",")}` : "";
  useEffect(() => {
    if (!heldMoved) return;
    setHeldRows(
      (current) =>
        current && {
          session: current.session,
          rows: current.rows.flatMap((each) => {
            const at = rowsRef.current.findIndex((row) => row.id === each.id);
            return at < 0 ? [] : [{ ...each, index: at, fromEnd: rowsRef.current.length - at }];
          }),
        },
    );
  }, [heldMoved]);
  // The row whose line a fold holds stays mounted while the hold lasts: a body that shrank under
  // the old offset (Show less on a long prompt) would otherwise drop the row, and the hold with it,
  // before the hold puts the line back (foldAnchor.ts).
  const foldAt = Number(foldAnchor.current?.toggle.closest(".acpmux-row")?.getAttribute("aria-posinset")) - 1;
  if (foldAt >= 0 && foldAt < rows.length && !heldIndices.includes(foldAt)) heldIndices.push(foldAt);
  const mountedRanges =
    heldIndices.length === 0
      ? scrolledRanges
      : mergeRowRanges([...scrolledRanges, ...heldIndices.map((index) => ({ first: index, last: index + 1 }))]);
  // A viewport either side of the view is never bare spacer: a row there that is not mounted in full
  // is a stand-in at its placed box (conversation/standIns.ts). Not while a drag flows the rows (they
  // leave their placed tops) nor as another chat loads.
  const standIns =
    flowing || sessionChanged
      ? []
      : standInRanges(
          visibleLayoutRange(layout, shownTop - height * STAND_IN_VIEWPORTS, height * (1 + 2 * STAND_IN_VIEWPORTS), 0),
          mountedRanges,
        );
  // Find highlights only need repainting when the query/target, row content, or mounted DOM
  // window changes. Keep this signature primitive so scroll and layout state updates that leave
  // the mounted rows alone do not walk every text node in the transcript again.
  const mountedRangeKey = mountedRanges.map(({ first, last }) => `${first}:${last}`).join(",");
  // The scrolled rows only: a held row far from the view would widen every drawn-height search
  // (`measured`) to the rows between them. The held rows are looked up by index instead.
  if (lastPlaced.current) {
    lastPlaced.current.first = scrolledRanges[0]?.first ?? 0;
    lastPlaced.current.last = scrolledRanges.at(-1)?.last ?? 0;
    lastPlaced.current.held = heldIndices;
  }
  // A session can reuse row ids. Until the reset effect commits, render the new session as a
  // fresh transcript so a stale focus or range never flashes on its first paint.
  const effectiveActiveRowId = sessionChanged ? rows[0]?.id : activeRowId;
  const effectiveTranscriptRange = sessionChanged ? undefined : transcriptRange;
  const selectedBounds = useMemo(() => {
    if (!effectiveTranscriptRange) return undefined;
    const anchor = rows.findIndex((row) => row.id === effectiveTranscriptRange.anchorId);
    const focus = rows.findIndex((row) => row.id === effectiveTranscriptRange.focusId);
    if (anchor < 0 || focus < 0) return undefined;
    return { first: Math.min(anchor, focus), last: Math.max(anchor, focus) };
  }, [rows, effectiveTranscriptRange]);
  const selectedRows = useMemo(() => {
    if (!selectedBounds) return new Set<number>();
    const selected = new Set<number>();
    for (let index = selectedBounds.first; index <= selectedBounds.last; index += 1) selected.add(index);
    return selected;
  }, [selectedBounds]);
  const selectedRowIds = useMemo(
    () => (selectedBounds ? rows.slice(selectedBounds.first, selectedBounds.last + 1).map((row) => row.id) : []),
    [rows, selectedBounds],
  );
  const focusRow = useCallback(
    (index: number) => {
      if (rows.length === 0) return;
      const nextIndex = Math.max(0, Math.min(rows.length - 1, index));
      const id = rows[nextIndex]!.id;
      setActiveRowId(id);
      pendingFocus.current = id;
      const node = ref.current;
      if (!node) return;
      const mounted = [...node.querySelectorAll<HTMLElement>(".acpmux-row")].find((row) => row.dataset.rowId === id);
      if (mounted) {
        focusRoute(mounted, "system", "a transcript row mounted");
        pendingFocus.current = undefined;
        return;
      }
      unlift();
      const top = layout.geometry.topAt(nextIndex);
      const maximum = Math.max(0, layout.totalHeight - node.clientHeight);
      const nextTop = Math.max(0, Math.min(maximum, top));
      const physicalTop = physicalScrollTop(node, nextTop);
      const before = node.scrollTop;
      node.scrollTop = physicalTop;
      const delta = node.scrollTop - before;
      scrollPacer.current?.cancel();
      setScrollAt(node.scrollTop, delta || node.scrollTop - scrollRef.current.top);
    },
    [layout, rows, unlift],
  );
  useLayoutEffect(() => {
    const id = pendingFocus.current;
    if (!id) return;
    const node = ref.current;
    const target = [...(node?.querySelectorAll<HTMLElement>(".acpmux-row") ?? [])].find(
      (row) => row.dataset.rowId === id,
    );
    if (target) {
      // focusRow already put the row in view; End's last row is in view at the end of its ride.
      focusRoute(target, "system", "the transcript's pending focus", {
        preventScroll: true,
      });
      pendingFocus.current = undefined;
    }
  }, [range, effectiveActiveRowId]);
  const copyRows = useCallback(
    async (rowIds: string[]) => {
      // A running command's output since the pane last drew is in liveToolOutput.ts, not `rows`.
      const text = transcriptRangeText(rowsWithLiveOutput(rows), rowIds);
      if (text && !(await copyTextResult(text))) throw new Error("copy.failed");
    },
    [rows],
  );
  /// Jump to latest (below), for the keys that go to the end.
  const jumpToLatestRef = useRef<(focused: boolean, path?: string) => void>(() => {});
  /// A Jump to latest asked while the rows end in history (canLoadNewer), run once the newest page is in.
  const latestAfterReturn = useRef<{ focused: boolean; path: string } | undefined>(undefined);
  const rowKeyDown = useCallback(
    (index: number, event: React.KeyboardEvent<HTMLElement>) => {
      // Buttons and links own their keyboard behavior. A focused row itself owns only the
      // navigation and copy keys below, so selecting prose never toggles a disclosure by accident.
      if (event.target !== event.currentTarget) return;
      // End and Cmd-Down go to the latest message, as Jump to latest does, and the last row takes
      // the keys: the reader asked for the end, and the reply streaming there is followed again.
      if (toLatestKey(event)) {
        event.preventDefault();
        setTranscriptRange(undefined);
        const lastId = rows.at(-1)?.id;
        if (lastId) {
          setActiveRowId(lastId);
          const mounted = [...(ref.current?.querySelectorAll<HTMLElement>(".acpmux-row") ?? [])].find(
            (row) => row.dataset.rowId === lastId,
          );
          if (mounted)
            focusRoute(mounted, "system", "the transcript's pending focus", {
              preventScroll: true,
            });
          else pendingFocus.current = lastId;
        }
        jumpToLatestRef.current(false, "end-key");
        return;
      }
      const move = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
      const jump = event.key === "Home" ? 0 : event.key === "End" ? rows.length - 1 : undefined;
      if (move || jump !== undefined) {
        event.preventDefault();
        const nextIndex = jump ?? index + move;
        const clamped = Math.max(0, Math.min(rows.length - 1, nextIndex));
        const nextId = rows[clamped]?.id;
        if (!nextId) return;
        setTranscriptRange((current) =>
          event.shiftKey
            ? {
                anchorId: current?.anchorId ?? rows[index]!.id,
                focusId: nextId,
              }
            : undefined,
        );
        focusRow(clamped);
        return;
      }
      if (event.key === "Escape") {
        if (effectiveTranscriptRange) {
          event.preventDefault();
          setTranscriptRange(undefined);
        }
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "c") {
        const native = window.getSelection?.();
        if (native && !native.isCollapsed) return;
        event.preventDefault();
        const rowIds = selectedRowIds.length > 0 ? selectedRowIds : [rows[index]!.id];
        void copyRows(rowIds).catch(() => undefined);
      }
    },
    [copyRows, effectiveTranscriptRange, focusRow, rows, selectedRowIds],
  );
  const rowFocus = useCallback((id: string) => setActiveRowId(id), [setActiveRowId]);
  // Keep the keyboard callback stable across transcript snapshots.
  const rowKeyDownRef = useRef(rowKeyDown);
  useInsertionEffect(() => {
    rowKeyDownRef.current = rowKeyDown;
  });
  const handleRowKeyDown = useCallback(
    (index: number, event: React.KeyboardEvent<HTMLElement>) => rowKeyDownRef.current(index, event),
    [],
  );
  // Avoid allocating a new slice on every scroll/follow commit. Long transcripts can dispatch
  // several state commits per frame while the reader is moving; the mounted range is already
  // bounded, so a direct scan keeps the check allocation-free.
  let activeVisible = false;
  if (effectiveActiveRowId) {
    for (let index = range.first; index < range.last; index += 1) {
      if (rows[index]?.id === effectiveActiveRowId) {
        activeVisible = true;
        break;
      }
    }
  }
  const tabStopId = activeVisible ? effectiveActiveRowId : rows[range.first]?.id;
  useLayoutEffect(() => {
    const spans = mountedRanges.map(({ first, last }): MountedSpan => [
      layout.geometry.topAt(first),
      layout.geometry.topAt(last - 1) + layout.geometry.heightAt(last - 1),
    ]);
    acpmuxPerf.mounted = spans;
    // A memo hit spent no time in geometry this render.
    const freshLayout = reportedLayout.current !== measured;
    reportedLayout.current = measured;
    const freshEstimate = reportedEstimate.current !== estimated;
    reportedEstimate.current = estimated;
    const layoutMs = (freshLayout ? measured.ms : 0) + (freshEstimate ? estimated.ms : 0);
    if (acpmuxPerf.enabled && freshLayout) acpmuxPerf.addLayout(layoutMs);
    if (acpmuxPerf.enabled && renderStart > 0) {
      const now = performance.now();
      acpmuxPerf.commit(now - renderStart, layoutMs, spans, now);
    }
  });
  // Reads `openAt` and the rest of this render as they are, run only on the inputs below.
  const anchorPass = useCommittedEvent(() => {
    // What the pinned live line is drawn held back by, before this pass's chase moves the thread.
    notePinPass(thread.current);
    /// This pass is the follow chase's (the last branch below): the rows under a change glide, against
    /// the row the chase measured from.
    let tailGlides = false;
    let tailAnchor: string | undefined;
    const switched = previousSession.current !== sessionId;
    if (switched) {
      if (ref.current) clearScrollOrigin(ref.current);
      // A single VirtualTranscript is reused while the selected chat changes. Discard every
      // scroll anchor from the old session before the placement pass chooses the new session's
      // openAt position or latest row.
      readerUpPending.current = false;
      readerDown.current = undefined;
      previousSession.current = sessionId;
      followDeferred.current = false;
      followRequest.current = undefined;
      wheelGlide.current?.stop();
      didOpenAtLatest.current = false;
      // Another chat's count (the subagent view takes none) is not a send in this one.
      seenSends.current = sends;
      setSentPromptIds((current) => (current.size === 0 ? current : new Set()));
      sentBeforeOpen.current = false;
      sendRiseUntil.current = Number.NEGATIVE_INFINITY;
      sendClockUntil.current = Number.NEGATIVE_INFINITY;
      previousLayout.current = null;
      previousRows.current = rows;
      scrolledTo.current = { top: 0, atLatest: false };
      seenAnchor.current = undefined;
      heldPlace.current = undefined;
      scrollPacer.current?.cancel();
      stopJump();
      stopBottomStackFold();
      setScrollAt(0, 0);
      follow(true, "session");
    }
    const old = switched ? null : previousLayout.current;
    const oldRows = previousRows.current;
    const node = ref.current;
    // The scroller's physical offset and height as this pass read or wrote them last (the read
    // phase in the branch that places the view), so the pass never reads the scroller back after
    // it wrote to the page: each such read laid the whole page out again, per streamed token.
    // Undefined where a branch moved the offset without keeping it here: the pass reads then.
    let passTop: number | undefined;
    let passHeight: number | undefined;
    pinView.current = undefined;
    // Code that scrolled the view since the last pass wins over a held line (releaseFoldHold).
    if (old && node) releaseFoldHold(node);
    // The view stopped following with its rows drawn up by the composer's growth (`lift`): that
    // growth is room now (`heldRoom`), and the offset moves by it in this same frame, so nothing the
    // reader sees moves.
    if (old && node && !following && appliedLift.current) {
      node.scrollTop -= appliedLift.current;
      scrolledTo.current = {
        ...scrolledTo.current,
        top: scrolledTo.current.top - appliedLift.current,
      };
      // The rows mounted for this frame read the offset too, before its scroll event comes.
      const moved = node.scrollTop;
      scrollPacer.current?.cancel();
      setScrollAt(moved);
    }
    // A disclosure the reader clicked stays where they clicked it while what it opens lays out: this
    // pass neither follows the latest row nor keeps the top row, it puts the clicked line back.
    if (old && node) releaseBottomStackFold(node);
    const stack = bottomStackFold.current;
    const bottomStacking = Boolean(old && node && stack && foldAnchor.current?.toggle === stack.toggle);
    // Only a held line reads it: a pass with none (each streamed token's) never does.
    const heldFrom = !bottomStacking && old && node && foldAnchor.current ? node.scrollTop : 0;
    // Under load the click's change reaches this pass late (the row's ResizeObserver runs after the
    // browser lays out what opened, and no pass may run in between): the hold waits for it, then runs
    // its span (foldAnchor.ts `notePlacement`), so a slow render never finds it over and follows the
    // latest row.
    if (old && node && foldAnchor.current)
      notePlacement(foldAnchor.current, heldRowUnplaced(foldAnchor.current.toggle));
    const folding = Boolean(!bottomStacking && old && node && foldAnchor.current && keepFold(foldAnchor.current, node));
    if (!folding && !bottomStacking) foldAnchor.current = undefined;
    if (folding && node) holdTop.current = node.scrollTop;
    if (folding && node && Math.abs(node.scrollTop - heldFrom) >= 0.5) {
      // The rows mounted for this frame read the held offset too, before its scroll event comes.
      const moved = node.scrollTop;
      scrollPacer.current?.cancel();
      setScrollAt(moved);
    }
    if (bottomStacking && node && stack) {
      // The body takes its final height before paint. Pin the scroller there, then play the
      // difference on the compositor. A late measure updates that same effect on its original clock,
      // never starts another animation or drives a per-frame layout/scroll loop.
      // No further than a sent prompt's view (`sendTopEnd`): what opens under it grows on below.
      const sendTopAt = sendTop.end > 0 ? Math.max(0, sendTop.end - height) : Number.POSITIVE_INFINITY;
      const latest = Math.min(Math.max(0, layout.totalHeight - height), sendTopAt);
      const pinned = settleFollowBottomAt(node, latest).top;
      const delta = pinned - scrollOrigin(node) - stack.beforeTop;
      const host = thread.current;
      // A control with no height fold of its own (a shell block's Show all output, a failure's
      // Details, Raw, Wrap lines) lays out in one step: the thread slides to it, as whole rows do.
      if (!stack.rows && !heightFoldInFlight(stack.row) && Math.abs(delta - stack.delta) > 0.5) {
        stack.rows = true;
        stack.row.setAttribute("data-bottom-fold", "");
      }
      // A body's own height fold: this pass, run on each of its frames before paint, already moved
      // the offset with it. Nothing else plays.
      if (host && stack.rows && Math.abs(delta - stack.delta) > 0.5) {
        if (stack.animation) {
          const effect = stack.animation.effect as KeyframeEffect;
          const progress = effect.getComputedTiming().progress;
          // The new layout moved the thread by -(delta - previousDelta). Add exactly that
          // displacement to its current transform without restarting the original animation clock.
          if (typeof progress === "number" && progress < 1) {
            stack.from += (delta - stack.delta) / (1 - progress);
            effect.setKeyframes([{ translate: `0 ${stack.from}px` }, { translate: "0 0" }]);
            // What grew late grew above the held rows: their line moves down the thread with it.
            if (stack.line !== undefined) stack.line += delta - stack.delta;
            holdUnderStack(host, stack, effect.getTiming(), stack.animation.currentTime);
          }
        } else {
          // Only what this pass added slides: what the fold's own frames already moved is drawn where
          // it is. A call that joined the group after its fold ended slid the whole fold again
          // from the row's first height, and the row jumped back and moved a second time
          // (Leo, 2026-11-06: "things clash with other things with animations going haywire").
          stack.from = delta - stack.delta;
          const frames = [{ translate: `0 ${stack.from}px` }, { translate: "0 0" }];
          const duration = foldMs(host);
          if (duration > 0) {
            const timing = { duration, easing: foldMotion.easing(host) };
            holdUnderStack(host, stack, timing);
            stack.animation = host.animate(frames, timing);
            stack.animation.onfinish = () => {
              if (bottomStackFold.current === stack) stopBottomStackFold();
            };
            stack.animation.oncancel = stack.animation.onfinish;
          } else stopBottomStackFold();
        }
      }
      // Every pass takes the offset it pinned as its base, a height fold's frames too: a late measure
      // after that fold ends slides only by what it adds, never by the whole fold again.
      stack.delta = delta;
      stack.pinned = pinned;
      passTop = pinned;
      scrollPacer.current?.cancel();
      setScrollAt(pinned);
    } else if (
      folding &&
      node &&
      foldAnchor.current &&
      !bottomStackFold.current &&
      foldRoomRef.current > Math.max(rowsEndRef.current, node.clientHeight) + 1 &&
      rowsEndRef.current < node.scrollTop + node.clientHeight - 1
    ) {
      // A close a little over the end: its line held this far, and the rows now end above the
      // view's end, so holding it on would leave blank room under the last row that nothing gives
      // back (Leo, 2026-11-07: the closed ones "didn't have the wherewithal to ... remove the space
      // at the bottom"). From here the bottom is pinned, as for a close at the very bottom.
      startBottomStack(node, foldAnchor.current.toggle);
    } else if (folding && node) {
      // What opened pushed the latest row out of view, or what closed left room under it
      // (`foldRoom`): the view is the reader's now, not following, so a reply that streams on
      // grows below the view instead of being followed past blank room.
      if (
        followingRef.current &&
        (node.scrollTop < layout.totalHeight - height - FOLLOW_BOTTOM_DEADBAND_PX ||
          foldRoomRef.current > rowsEndRef.current + 0.5)
      )
        follow(false);
    } else if (old && node && userScrollIntent(node).isScrollbarDragging()) {
      // The native thumb owns its offset until release; row anchoring must not write over it.
      scrollPacer.current?.cancel();
      if (Math.abs(scrollRef.current.top - node.scrollTop) > 0.5) setScrollAt(node.scrollTop, 0);
    } else if (old && node) {
      // Content that shrank under the viewport has already clamped the live offset to
      // the new end; the offset recorded before this commit is where the reader was.
      // A clamp lands exactly on the scroller's own end, which rounds the layout's
      // fractional height, so compare with that rather than allow for the rounding.
      // A viewport that grew clamps at the end the content had then: the room a queued prompt's
      // card leaves (`floor`) can make the content taller again in this same commit.
      const live = node.scrollTop;
      const previousOrigin = scrollOrigin(node);
      // The scroller as it is now, not as last measured: a chat shown again after its workspace was
      // away (hidden, parked) draws what landed meanwhile in the first frame back, before its
      // ResizeObserver reports a size that changed while it was away (the window or the sidebar
      // moved). The browser already clamped the offset to the new box, so against the old height
      // that clamp read as the reader scrolling up: the view stopped following and the turn went on
      // under the composer behind Jump to latest, or a smaller one moved the rows on the follow chase,
      // down from where the old box drew them, leaving a sliver at the bottom (Leo, 2026-11-11: "a
      // new message from you seemed to come down from the heavens ... a sliver of space at the bottom
      // that the newest few lines started from the top"; agent-pane-reveal-in-place.test.ts). That
      // pass is a resize: the offset is held to the box as it is, nothing reads as the reader's, and
      // nothing glides. One read; this pass already laid out.
      const liveHeight = node.clientHeight;
      const unmeasured = liveHeight > 0 && Math.abs(liveHeight - height) > 0.5;
      const viewHeight = unmeasured ? liveHeight : height;
      // The browser rounds the height it clamps to, so the old end allows a pixel either way.
      // The live extent may already have shrunk and clamped the offset before reconciliation.
      // Keep that boundary as well as the old total so the clamp never reads as upward input.
      const end = Math.min(node.scrollHeight, old.totalHeight) - viewHeight;
      // The pass's read phase ends here: from now on it knows the offset and height it reads below.
      passTop = live;
      passHeight = liveHeight;
      const recentUp = readerUpPending.current && live < scrolledTo.current.top;
      const clamped = !recentUp && live < scrolledTo.current.top - 0.5 && live >= end - 1;
      // A reader's move can reach the live offset before its scroll event. Layout changes alone
      // never release or reacquire follow; the input window only identifies this event race.
      // A reader can already be parked before the next wheel/default write. The live offset is
      // still authoritative for that recent upward input; gating this on `following` reused the
      // stale acknowledged top and produced a one-frame jump when an unseen row remeasured.
      // When already parked, only an unacknowledged upward input may explain a live offset above
      // the stored one. A click or downward input refreshes readerAt too, but must not turn a
      // layout correction into a new reader move (the base reader intent rule).
      const inputAt = followingRef.current || readerUpPending.current ? readerAt.current : Number.NEGATIVE_INFINITY;
      // A followed view whose offset rose past the deadband with the viewport unchanged and no clamp
      // to explain it was moved by the reader, even before any of their input reached the page. WebKit scrolls a
      // passive-wheel scroller on its scrolling thread and hands the page the wheel later; a streamed
      // snapshot that commits in between pinned the reader back to the bottom, gesture after gesture
      // (Lawrence, 2026-11-07: "scrolling up is broken"). The transcript never moves its own offset up
      // while following (no scroll anchoring, overflow-anchor: none), so only a reader or code can.
      const viewport = previousViewport.current;
      const unseenReaderMove =
        followingRef.current &&
        !clamped &&
        !unmeasured &&
        jumpTarget.current === undefined &&
        viewport.height === height &&
        viewport.width === width &&
        scrolledTo.current.top - live > UNSEEN_READER_MOVE_PX;
      // A parked view whose live offset is neither the last one handled nor the last one the transcript
      // wrote or committed (`scrollRef`, which its own writes set): a move nobody here made, a step of the
      // reader's scroll whose event has not come yet (a scrollbar thumb, which sends no wheel or key, a
      // fling's frame). Anchored from the handled offset instead, a pass that measured rows in between
      // put the view back where the step began: the row on screen stood still for a frame while the
      // offset went on, then leapt (transcript-scroll-up MODE=drag, a whole step every other frame).
      const unhandledMove =
        !followingRef.current &&
        !unmeasured &&
        Math.abs(scrolledTo.current.top - live) > 0.5 &&
        Math.abs(scrollRef.current.top - live) > 0.5;
      const readerLeft =
        !clamped &&
        (unseenReaderMove ||
          unhandledMove ||
          (performance.now() - inputAt <= READER_SCROLL_MS && scrolledTo.current.top - live > 0));
      if (readerLeft) follow(false);
      if (readerUpPending.current && readerLeft) readerUpPending.current = false;
      // A real wheel can move the live offset before its scroll event reaches React. Keep that
      // movement for this pass and mark the view away from the latest row; otherwise the stored
      // bottom offset would immediately snap the reader back. Once the event is acknowledged,
      // layout-only corrections use the stored offset because WebKit may already include a resize
      // adjustment in `live`.
      const top = scrollAnchorBase(live, scrolledTo.current.top, readerLeft);
      // Following is reader intent, not proximity. A token must not recapture a parked reader
      // just because the last recorded offset remains inside the bottom deadband.
      // A sent prompt held at the view's top (`sendTopEnd`): the follow goes no further than that view.
      const sendTopAt = sendTop.end > 0 ? Math.max(0, sendTop.end - viewHeight) : undefined;
      const atLatest = followingRef.current;
      // At the latest row also at offset 0: a new chat's first pass can overshoot on estimated
      // heights and settle back to fit, and its reply must still be followed once it overflows
      // (cx-ubd1y). Away from it, at the first row nothing above can move it.
      if (didOpenAtLatest.current && atLatest) {
        // At the latest row: stay there as rows settle to their drawn heights and as content grows,
        // in this pass, before the frame paints. Nothing glides: a glide held the new text below the
        // view's foot for its 180 ms at every streamed chunk, and on open it slid from a layout that
        // never painted (estimated heights) to the drawn one (Leo 2026-10-21: "IMMEDIATELY ... at the
        // bottom every single time").
        // Held at a sent prompt's view (`sendTopAt`): a prompt taller than the view still lands at its top.
        const latest = Math.min(Math.max(0, layout.totalHeight - viewHeight), sendTopAt ?? Number.POSITIVE_INFINITY);
        // Jump to latest's glide in flight heads for the new end instead of snapping there.
        const jumping = jumpTarget.current !== undefined;
        // The shared animation reads the moving end every frame on its original clock.
        // Retargeting a native smooth-scroll here restarted its easing at every measurement.
        if (jumping) jumpTarget.current = latest;
        followDeferred.current = !jumping && userScrollIntent(node).isHeld() && !followRequest.current?.();
        const settle = jumping || followDeferred.current ? undefined : settleFollowBottomAt(node, latest);
        // Where the view is from here: the settle's landed offset, else the one this pass read.
        const viewTop = settle ? settle.top : live;
        passTop = viewTop;
        // The chase below reads where the view is from here, not from the scroller it just wrote.
        pinView.current = { top: viewTop, height: liveHeight };
        const settled = jumping ? clamped : settle?.moved || clamped;
        if (settled) followTrace.set(latest);
        // The rise this pass took, eased on screen (followGlide.ts): the same rows, the reply's
        // new line landing in the room the live line keeps under it. Anything else (a row that came
        // or went, a resize, a fall) moves at once, as before.
        // In layout coordinates: the sub-pixel origin a settle keeps (scrollCoordinates.ts) moves the
        // rows on screen too, so a rise that only re-rounds the physical offset is no rise.
        const box = previousViewport.current;
        const rose = viewTop - scrollOrigin(node) - (scrolledTo.current.top - previousOrigin);
        const room = followRoom(rows, layout);
        // A resize (a window edge dragged, the dock growing) rewraps the rows, and they settle to
        // their drawn heights over the next passes at the same size: those are the resize too, not
        // growth, so nothing glides until the view has held its size for a motion step (cx-sqj3h).
        // The bottom stack's change (the composer growing a line or clearing after a send, a queue
        // card leaving) rewraps no row: no resize. The rows move with the stack at once in that pass
        // (the lift keeps the latest row over a growing card; a queue's room goes as it did), and
        // the chase goes on from there. The composer clearing as the reader sends is the send's own
        // move: the rows the send brings and the room it gives back move as one chase.
        // The composer card clearing (its draft sent or cleared) gives the room back with the rows it
        // brings as one chase too; only the stack growing and the rest of it shrinking (a queue
        // card leaving) move at once.
        const sendWindow = sends !== seenSends.current || performance.now() < sendRiseUntil.current;
        // Read only in a send's window: one style read per pass for at most SEND_RISE_MS.
        const sendLands = sendWindow && !(sendClockMs(node) > 0);
        const cardCleared = dockCard < box.dockCard && box.dockSpace - dockSpace <= box.dockCard - dockCard + 0.5;
        const dockMoved = box.dockSpace !== dockSpace && !((sendWindow || cardCleared) && dockSpace < box.dockSpace);
        const now = performance.now();
        if (unmeasured || box.height !== height || box.width !== width || (!chasing && box.dockSpace !== dockSpace)) {
          resizedAt.current = now;
          stopFollowMotion();
        }
        const resizing = now - resizedAt.current < MOTION_MS.standard;
        // What came while the reader was away (the chat hidden behind another workspace, whose held
        // frames land together as it shows: shared/pageReveal.ts), or a burst of rows in one update,
        // is a load, not live: it is placed at once, as its rows draw in place. Chased or glided, the
        // rows under it started where they were drawn before the reader left, a backlog's height up,
        // and slid down into a gap at the bottom (Leo, 2026-11-11: "a new message from you seemed to
        // come down from the heavens ... austin was navigating between workspaces").
        const caughtUp = pageAway(node.ownerDocument) || rows.length - oldRows.length > LIVE_ROWS_PER_UPDATE;
        // The turn ending folds its work in one motion (turnEndFold.ts) from the rows as they were
        // drawn: it moves the rows on its own frames, so nothing chases or glides with it (a chase
        // that drew the thread back by the swap, then by the fold's own steps, moved the rows twice).
        const turnEnding = turnEndCapture.current !== undefined || Boolean(thread.current?.hasAttribute(TURN_END_ATTR));
        // Every arm but `eased`: whatever moved the rows in view in this pass (a line, rows that came,
        // the composer's room) is one move of one chase (followChase.ts). A disclosure's fold and
        // the bottom stack's fold move the thread on their own frames, and Jump to latest rides on
        // its own: those end it.
        if (chasing) {
          // Those move the rows between passes on their own frames (the jump's ride, a fold, a
          // rewrap): it ends, and nothing is noted, so the first pass after them measures no move
          // from a row they moved (that drew the thread back by the ride's last step, under the card).
          // The turn ending (the live line leaves for the footer, and what ran folds above the reply)
          // joins the chase, and the chase lands (followChase `land`: at once when that frame stays
          // within a landing frame's move, else within 50 ms at no more than a line a frame): nothing
          // settles on after the turn rests (base's glide ended there too, its room gone).
          const lineLeft = Boolean(oldRows.at(-1)?.below) && !rows.at(-1)?.below;
          // Only a live turn moves on the chase: a reply streaming, a send's rows, what a running
          // turn brings. The open's settle and an idle chat's passes (rows drawn at their measured
          // heights, a late read) land at once, before the frame paints, as base's follow does.
          const tail = rows.at(-1);
          const opened = chaseOpenTail.current;
          if (opened && (sendWindow || !tail || tail.id !== opened.id || tail.version !== opened.version))
            chaseOpenTail.current = undefined;
          // The reply's last lines still revealing after the turn ended are the turn's too: they
          // chase, so the turn ending never moves the rows by them at once (send-stream-motion).
          const draining = now < chaseDrainUntil.current;
          const live = (working || sendWindow || draining) && chaseOpenTail.current === undefined;
          const riding = jumping || bottomStacking || heightFoldPlaying() || turnEnding;
          // The fold playing on after the pass that ended the turn: it moves the rows on its frames,
          // and the chase that took the reply's last lines lands on its own (a stop there moved what
          // it still held back at once).
          const foldRiding =
            turnEnding && turnEndCapture.current === undefined && !jumping && !bottomStacking && !heightFoldPlaying();
          const folding = Boolean(thread.current?.hasAttribute(TURN_END_ATTR));
          // The slim arm is the send's (Leo, 2026-11-09: "the scroll up is extremely sluggish"): the
          // turn's end still drains here on every arm, so its reply never steps at the end.
          if (folding && draining && !jumping && !bottomStacking && !heightFoldPlaying() && !resizing && !caughtUp) {
            // The fold plays and the reply's last lines still reveal: the fold takes every move but
            // theirs (it takes a late one only from its curve's remaining share, which moved the rest
            // at once, 12 to 18 px in a frame), and the chase takes the reply's growth, drawn back by
            // it and landing at no more than a line a frame. The fold reads the rows over the thread
            // drawn back, so it sees only the rest.
            const reply = replyHeight(rows);
            const grew = reply && drainReply.current?.id === reply.id ? reply.height - drainReply.current.height : 0;
            drainReply.current = reply;
            chaseAnchor.current = undefined;
            const chase = followChase.current;
            if (chase && grew > 0.5) {
              chase.resume();
              // After Jump to latest the reply's lines keep to the room (chaseHeld), as they do
              // while the turn runs: an unbounded draw-back drew the folded line under the card.
              const held = chaseHeld.current;
              chase.shift(thread.current, -grew, held ? room : Number.POSITIVE_INFINITY, held);
              chase.land();
            }
            // The rows under the reply (the turn's footer the fold brought) would move down by its
            // growth at once: they glide there instead (tailGlide.ts), in every pass of the drain, not
            // only the one that read the growth. The reply's drawn height can grow a pass before the
            // layout takes it (a pass the mounted range brings, as the scroll trail's does), and the
            // footer then moved by it in the next pass, at once (turn-transition-jumps `tool-group`,
            // end step: 19.2 and 32.2 px in a frame). Only a move against the reply glides, so a pass
            // where nothing moved plays nothing.
            if (reply) {
              tailGlides = true;
              tailAnchor = reply.id;
            }
          } else if (foldRiding && !resizing && !caughtUp) {
            // The fold playing on: nothing noted, and a chase still landing lands on its own.
            chaseAnchor.current = undefined;
          } else if (riding || resizing || caughtUp) {
            stopFollowMotion();
            // The turn's end rides on its fold (turnEndFold.ts), or rests where nothing moved: the
            // reply's last lines still revealing after it are the turn's all the same, and chase
            // (send-stream-motion), never move the rows at once. Its height now is where they start.
            if (turnEnding && lineLeft) chaseDrainUntil.current = now + StreamReveal.finishMs;
            // Whatever the reply grew by while a ride moved the rows (Jump to latest heads for the
            // moving end) is the ride's, never the drain's to chase after it: the drain measures
            // from the rows as this pass leaves them (a jump landing mid-fold drew the reply's
            // growth over its whole glide back at once, 100 to 200 px under the card).
            if ((turnEnding && lineLeft) || draining) drainReply.current = replyHeight(rows);
            // A resize settles in this pass: the next pass after it measures from the rows as they
            // lie now (none noted, the first move after an idle resize, a prompt landing, moved at
            // once). A ride, a fold and a jump move the rows on their own frames: nothing noted.
            if (!riding) chaseFollow(node, layout, rows, Number.POSITIVE_INFINITY, true);
          } else if (
            sendLands &&
            (broughtSentPrompt(oldRows, rows) ||
              (dockSpace < box.dockSpace &&
                rows.length === oldRows.length &&
                rows.at(-1)?.id === oldRows.at(-1)?.id &&
                rows.at(-1)?.version === oldRows.at(-1)?.version))
          ) {
            // A send on a 0 clock (the product's): its own rows (the prompt, its live line) and the
            // room the composer gives back are in place in this pass, and a chase still drawing the
            // thread back ends where it lands. Anything else in the send's window (the reply
            // streaming, a tool row, the dock growing) moves on the chase as ever.
            stopFollowMotion();
            chaseFollow(node, layout, rows, Number.POSITIVE_INFINITY, true);
          } else if (lineLeft) {
            // What the pass also brought (the reply's next revealed line) joins the trail first, and
            // the landing takes it home with the rest at no more than a line a frame.
            chaseDrainUntil.current = now + StreamReveal.finishMs;
            chaseFollow(node, layout, rows, Number.POSITIVE_INFINITY, slimFollow);
            followChase.current?.land();
          } else {
            // New text lands in the room the quiet live line keeps under the reply, and at most a line
            // under the bottom stack while it catches up (followGlide.ts kept it to the room and moved
            // the rest at once). A send's rows rise out from behind the composer they left: no cap.
            // Only the passes that bring the send's own rows (the prompt, the live line, as `sendRows`
            // below): a reply streaming right after it keeps to the room.
            const sentRows =
              (sends !== seenSends.current || now < sendRiseUntil.current) && rows.length > oldRows.length;
            // After Jump to latest what streams on keeps to the room (chaseHeld) until the reader
            // sends: the send's rows rise from behind the composer again.
            if (sentRows) chaseHeld.current = false;
            const held = chaseHeld.current;
            // A prompt's row that came at the tail (before the live line) outside a send's window (the
            // reader's other device, a queued prompt sent) rises from behind the composer as a sent
            // one does: kept to a line under the stack, its rise moved at once and the room the
            // composer gave back after it drew the rows down again (`spring`, `chunk`, `linear`).
            // O(rows that came).
            let promptCame = false;
            for (let index = rows.length - 1; index >= Math.max(0, oldRows.length - 2) && !sentRows; index -= 1) {
              const row = rows[index]!;
              if (row.kind === "user" && !isLineRow(row) && row.id !== oldRows[index]?.id) promptCame = true;
            }
            const below = held ? room : sentRows || promptCame ? Number.POSITIVE_INFINITY : room + CHASE_UNDER_STACK_PX;
            // The reply growing with no live line under it (no room: a line that names a call, a
            // queue's cards last, a view that draws none) steps as before (followRoom), as base's
            // glide did; rows that come and go, the send's among them, still chase.
            // Only the newest row's own growth (its version moved). A pass that moved the rows by
            // the bottom stack alone (the composer clearing as the reader sends, before the turn's
            // rows land: that stepped them 46 px down at once) is the send's move, and a row that
            // settles to its drawn height (a tool call's row measured shorter than its estimate:
            // that stepped the reply 15 px down while the chase held it) is the chase's too.
            const tailOld = oldRows.at(-1);
            const tailNew = rows.at(-1);
            const grewOnly =
              rows.length === oldRows.length &&
              rows.at(-2)?.id === oldRows.at(-2)?.id &&
              (tailNew?.id !== tailOld?.id || tailNew?.version !== tailOld?.version);
            const stepped = grewOnly && !(room > 0) && !held && !cardCleared;
            // The slim arm moves every pass's rows at once, the send's own among them: the sent prompt is
            // in place in the frame after Return, and nothing settles after it (Leo, 2026-11-09: "the
            // scroll up is extremely sluggish").
            const atOnce = dockMoved || !live || stepped || slimFollow;
            // A row that came above the live line (not the reply's own growth) holds back up to the
            // trail bound, while the live line glides under it (followChase CHASE_ARRIVAL_HOLD_LINES).
            // The arrived row's room often lands a pass later (its measured height), so the passes
            // within ARRIVAL_PASS_MS of it count too.
            if (arrivedAtTail(oldRows, rows)) arrivedAt.current = now;
            const arrived = now - arrivedAt.current < ARRIVAL_PASS_MS;
            tailAnchor = chaseAnchor.current?.id;
            // A send's own rows rise on the send motion, one clock with the bubble's entrance, while
            // that motion plays; rows landing after it arrive on the arrival step.
            const sentClock = sentRows && (sends !== seenSends.current || now < sendClockUntil.current);
            chaseFollow(node, layout, rows, below, atOnce, held, arrived, sentClock && !steered);
            tailGlides = !atOnce && !slimFollow && followChase.current?.arm !== "instant";
          }
        }
        // A glide holding the rows back further than the room now under the last row (the live line
        // came into view to name a call) rests at once, so nothing stays under the bottom stack.
        if (!chasing) followGlide.current?.fit(room);
        // The reader just sent a prompt from the latest row (a send in this commit, or one a moment
        // ago whose rows land now): the rows that came lift the thread on the send's glide, the
        // prompt rising out from behind the composer, instead of the view jumping a row in a frame.
        const sendRows = (sends !== seenSends.current || now < sendRiseUntil.current) && rows.length > oldRows.length;
        if (chasing) {
          // Moved above.
        } else if (
          sendRows &&
          !caughtUp &&
          !jumping &&
          !bottomStacking &&
          !resizing &&
          !heightFoldPlaying() &&
          !turnEnding &&
          rose > 0.5
        )
          followGlide.current?.sent(thread.current, rose);
        // A disclosure's height fold moves the rows on its own frames: easing them too lagged it.
        else if (
          !caughtUp &&
          !jumping &&
          !bottomStacking &&
          !resizing &&
          !heightFoldPlaying() &&
          !turnEnding &&
          rose > 0.5 &&
          rows.length === oldRows.length &&
          rows.at(-2)?.id === oldRows.at(-2)?.id
        )
          followGlide.current?.rise(thread.current, rose, room);
      } else if (top > 0 || rows[0]?.id !== oldRows[0]?.id) {
        // Away from the latest row nothing chases: the next followed pass measures from scratch.
        chaseAnchor.current = undefined;
        chaseHeld.current = false;
        // Keep the row at the top of the viewport where it is as rows above it change height.
        // Rows that arrived or left (a new reply segment below, older history above) move indexes,
        // so the row is found again by its id; at offset 0 too, when older history arrived above.
        // A row older history completed (a turn cut at the page's edge) has a new id: the next row
        // that kept its own anchors instead.
        const logicalTop = top - previousOrigin;
        const kept = heldPlace.current
          ? undefined
          : preserveScrollAnchorTop({
              oldLayout: old,
              newLayout: layout,
              oldRows,
              newRows: rows,
              liveTop: logicalTop,
              anchorTop: logicalTop,
              folds: foldRide.current?.handedFolds(oldRows, drawnRef.current),
            });
        // The rows went from the top and no row the reader saw is among them now (a reconnect's
        // shorter tail, a rebuild's empty frame): the reader's place is held, not the offset the
        // shrink clamped to the end (`heldPlace`). A row renamed in place keeps the first row.
        // Not for a rail jump that made the target's page the held window (canLoadNewer): the reader asked to leave.
        if (
          kept === undefined &&
          !heldPlace.current &&
          !canLoadNewer &&
          oldRows.length > 0 &&
          rows[0]?.id !== oldRows[0]?.id
        )
          heldPlace.current = seenAnchor.current ?? restingAnchor(logicalTop, false, old, oldRows) ?? undefined;
        const held = heldPlace.current ? heldReaderPlace(heldPlace.current, rows, layout) : undefined;
        // Found, or no older page can bring it back (the history is whole): the hold goes, the view
        // left at the oldest row, never the end.
        if (held?.found || (held && !canLoadOlder)) heldPlace.current = undefined;
        const nextTop = held ? held.top : kept;
        if (nextTop !== undefined && (clamped || held !== undefined || nextTop !== logicalTop)) {
          // The anchor's write, read back before its origin's style write (a scroll write alone
          // leaves the page laid out): nothing after it reads the scroller.
          node.scrollTop = nextTop;
          passTop = node.scrollTop;
          retainScrollOrigin(node, nextTop);
          // Keep React's rendered offset in the same frame as the anchor correction. Otherwise a
          // rounded DOM offset arrives through scroll later and can briefly show Jump to latest.
          // The move is the anchor's, not the reader's, so the reader's last move stays the lead: zeroed,
          // a fling's next render dropped its lead and the warm rows caught up to the view, a deferred
          // render of six views of rows each time an older page landed under it.
          scrollPacer.current?.cancel();
          setScrollAt(passTop, scrollRef.current.delta);
        }
      }
    }
    // Runs on height too: rows that fit and then overflow on a height-only shrink keep the same memoized layout.
    if (!didOpenAtLatest.current && node) {
      // The open writes the offset its own way: the pass reads it after.
      passTop = undefined;
      pinView.current = undefined;
      const latest = Math.max(0, layout.totalHeight - height);
      // A chat reopened where the reader left it (cx-6bgzj), else at the latest message, as it is
      // once the reader sent a prompt into it. Only a row the pane already holds counts: a chat opens
      // on its tail and shows what it has at once (Leo 2026-11-05: "you don't need to load the entire
      // thing ... Just load the recent bits and render, like, what you already have"). A row older
      // than the tail used to hold the chat unseen while older pages were read back to it (cx-odzaz):
      // on a long chat under load that was seconds of a blank pane, each page replaying the whole
      // transcript, and it often gave up and opened at the latest message anyway.
      const at = openAt && !sentBeforeOpen.current ? rows.findIndex((row) => row.id === openAt.rowId) : -1;
      if (layout.totalHeight <= height) {
        // A tail that fits shows from the top, as before; it opens once it overflows.
      } else if (folding) {
        // A disclosure the reader clicked in a tail that fit made it overflow: the chat opens where
        // the reader is, the clicked line held (above), not at the latest row. Jumping there put the
        // rows a frame up before the hold brought them back, or, past the hold, moved the whole
        // thread up under the line just clicked (#27650, an edit's diff opened in a short chat).
        followTrace.set(node.scrollTop);
        follow(node.scrollTop >= latest - 1, "open");
        didOpenAtLatest.current = true;
      } else {
        const top = at < 0 ? latest : Math.min(latest, layout.geometry.topAt(at) + openAt!.offset);
        const before = node.scrollTop;
        clearScrollOrigin(node);
        // At the latest row the end is written as a following view's is (rounded up): floored, it
        // rested a pixel short of a fractional end until the next following pass put it there, and
        // a switch that mounts its rows at the end in its first commit has no next pass.
        if (at < 0) node.scrollTop = Math.ceil(top - 0.01);
        else writeAnchorScrollTop(node, top);
        // A send made a tail that fit overflow (Leo, 2026-11-04: "from partially empty"): the
        // thread is drawn back by the rise and slides up on the send's glide, the prompt rising out
        // from behind the composer, instead of the whole chat moving up a row in one frame.
        // The send's own effect runs after this pass, so a send in this commit counts here too.
        // On a 0 send clock (the product's) the thread is in place at once, whichever commit the
        // prompt came in (review of #41550): no glide and no chase.
        const sentHere = sentBeforeOpen.current || sends !== seenSends.current;
        if (sentHere && at < 0 && node.scrollTop - before > 0.5 && sendClockMs(node) > 0) {
          // On the send motion, one clock with the bubble's entrance, while that motion plays.
          const sentClock = sends !== seenSends.current || performance.now() < sendClockUntil.current;
          if (chasing)
            followChase.current?.shift(
              thread.current,
              before - node.scrollTop,
              Number.POSITIVE_INFINITY,
              false,
              false,
              sentClock && !steered,
            );
          else followGlide.current?.sent(thread.current, node.scrollTop - before);
        }
        followTrace.set(node.scrollTop);
        scrollPacer.current?.cancel();
        setScrollAt(node.scrollTop, 0);
        follow(top >= latest - 1, "open");
        didOpenAtLatest.current = true;
        // The rows in view as the chat opens: the first move after it chases from them, once
        // something new comes after the open (`chaseOpenTail`); a send in this commit already is.
        if (chasing && top >= latest - 1) {
          const tail = rows.at(-1);
          chaseOpenTail.current = tail && !sentHere ? { id: tail.id, version: tail.version } : undefined;
          chaseFollow(node, layout, rows);
        }
      }
    }
    // The room a collapse kept follows the view's end, and goes once the rows reach it.
    if (node) trimFoldRoom(node);
    // The live line, the thread's last row, holds still at the bottom against the chase while the
    // rows above it grow or come (pinnedLiveLine.ts), for as long as it stays the last row: a pin
    // dropped and taken again a pass later left the line on its own glide, whose translate wins over
    // the pin's, under a reply clipped for where the pin would draw it (overlap). A send's rows rise
    // with theirs, and the turn's end folds them itself, so those let it go; the reader taking the
    // view holds it where it is drawn.
    const lastRow = rows.at(-1);
    const lineStays = oldRows.at(-1)?.id === LIVE_THINKING;
    // A prompt that comes over the line (a steer sent while a call runs) lets it go: the prompt's
    // rows rise with it as a send's do, and the pin takes the line again once they rest. Pinned
    // through it, the line was held back by the prompt's whole height at once, which the chase
    // brought home in a step (105 px in turn-transition-jumps steer-tools). The reply's own rows
    // (its text, a call's row) come under the pin as before.
    // Rows come at the tail (before the live line): O(rows that came), never the chat's length.
    let rowsCame = false;
    for (let index = rows.length - 2; index >= Math.max(0, oldRows.length - 2); index -= 1) {
      const row = rows[index]!;
      if (row.kind === "user" && row.id !== oldRows[index]?.id) rowsCame = true;
    }
    const pinLive =
      chasing &&
      followingRef.current &&
      lineStays &&
      !rowsCame &&
      lastRow?.id === LIVE_THINKING &&
      Boolean(lastRow.below) &&
      turnEndCapture.current === undefined &&
      !thread.current?.hasAttribute(TURN_END_ATTR) &&
      !(sends !== seenSends.current || performance.now() < sendRiseUntil.current);
    const carry = pinLiveLine(thread.current, pinLive, !followingRef.current);
    // The glide reads where the rows lie from this placement (each frame's `top` is set from it), not
    // from every mounted row's box. Rows that flow (a live resize) lie where the page puts them: read.
    const placedGeometry = layout.geometry;
    const placedRows: PlacedRows | undefined = thread.current?.classList.contains(FLOW_CLASS)
      ? undefined
      : {
          idAt: (index) => rows[index]?.id,
          indexOf: (id) => mountedIndexOf(rows, mountedRanges, id),
          topAt: (index) => THREAD_TOP + placedGeometry.topAt(index),
          heightAt: (index) => placedGeometry.heightAt(index),
          mounted: mountedRanges,
        };
    tailGlide.current?.place(
      thread.current,
      tailGlides && chasing,
      tailAnchor,
      chasing && followingRef.current,
      pinLive ? LIVE_THINKING : undefined,
      carry,
      placedRows,
    );
    refreshPinned(thread.current);
    finishCarry(thread.current, carry, (px) => {
      const style = thread.current ? getComputedStyle(thread.current) : undefined;
      const floor = cssTimeMs(style?.getPropertyValue("--agent-motion-arrive") ?? "") ?? MOTION_MS.quick;
      return {
        ms: floor > 0 ? arrivalStepMs(px, 1, floor) : 0,
        easing: ARRIVAL_EASE,
      };
    });
    previousLayout.current = layout;
    previousRows.current = rows;
    // The rows a fold ride moved are placed where they showed: its hand-over is spent.
    foldRide.current?.takeHanded(drawnRef.current);
    previousViewport.current = { height, width, dockSpace, dockCard };
    // With the composer's growth, which is room again once the view stops following.
    // A hold for a line that went is room the rows still have: it stays in the room once scrolled up.
    heldRoom.current.room = under.next.heldRoom;
    appliedLift.current = lift;
    liftedBefore.current = lifted;
    // A view that follows keeps the card height it began following at; any other takes the card's.
    if (!lifting) cardRest.current = dockCard;
    // The room a followed view keeps (`floor` above), until the rows fill it or it stops following.
    const holding = didOpenAtLatest.current && followingRef.current && floorHeight - lifted > rowsHeight;
    // Held for a sent prompt: once, for the prompt to arrive. Held only for a withdrawn one (the
    // reply was working): again at each pass, so it lasts while the reply grows and goes soon after.
    const forSent = [...heldFor.current].some((id) => !withdrawn.current.has(id));
    if (holding && (!floor.current.height || !forSent)) {
      clearTimeout(floorTimer.current);
      floorTimer.current = setTimeout(
        () => {
          floor.current = { ...floor.current, height: 0 };
          releaseFloor();
        },
        forSent ? FLOOR_HOLD_MS : WITHDRAWN_HOLD_MS,
      );
    } else if (!holding) clearTimeout(floorTimer.current);
    floor.current = {
      height: holding ? floorHeight : 0,
      width,
      sessionId,
      rows: measured.layout.totalHeight,
    };
    if (!holding && !queueLeft.current) heldFor.current.clear();
    if (node && (passHeight ?? node.clientHeight) > 0 && height > 0 && didOpenAtLatest.current) {
      const settledTop = passTop ?? node.scrollTop;
      scrolledTo.current = { top: settledTop, atLatest: followingRef.current };
      // While the reader's place is held, it is the place to reopen at, not where the view waits.
      seenAnchor.current =
        heldPlace.current ?? restingAnchor(settledTop - scrollOrigin(node), scrolledTo.current.atLatest, layout, rows);
    }
    followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);
    pinView.current = undefined;
    // The minimap's band reads the offset this pass settled on (`scrolledTo`, when this pass took it).
    minimapPlaced.current?.(
      node && (passHeight ?? node.clientHeight) > 0 && height > 0 && didOpenAtLatest.current
        ? scrolledTo.current.top - scrollOrigin(node)
        : undefined,
    );
  });
  // openAt is read once, at the first open.
  useLayoutEffect(
    () => anchorPass(),
    [anchorPass, layout, rows, range.first, height, width, dockSpace, room, lift, sessionId, followResume],
  );
  // The turn that just ended folds from the rows drawn then to the rows placed now (turnEndFold.ts).
  useLayoutEffect(() => {
    const capture = turnEndCapture.current;
    if (!capture) return;
    turnEndCapture.current = undefined;
    const host = thread.current;
    if (!host) return;
    settleTurnEnd(host, turnEnd.current);
    // The fold alone moves the rows from where they were drawn. The followed view's motion
    // (followGlide.ts, followChase.ts) drew the thread back on its own curve and clock under the
    // fold's rows: the two summed to a reply that rose past its place and dropped back (3 to 13 px,
    // agent-pane-stream-jitter). Where it drew them is already in the rows' starts. A reader who
    // took the view keeps the thread where the held chase drew it: nothing of theirs moves.
    if (followingRef.current) stopFollowMotion();
    // The tail glide's held translates and clips end either way: where they drew the rows is in the
    // fold's starts too, and the fold plays its own clip from what each row drew. A held clip left on
    // under it applied again once the fold ended, hiding the reply's last lines with nothing under
    // them, until some later pass let it go (review of cmux#41034: a paused 40 px clip after
    // `settleTurnEnd`, the reader scrolled up mid-glide with the live line still in view).
    else tailGlide.current?.stop();
    turnEnd.current = playTurnEnd(host, capture, sessionId, ref.current);
    // The reply's last lines still revealing after the turn ended chase while the fold plays: the
    // chase reads the fold's move on its own frames and keeps each frame of the two together to the
    // fold's bound (followChase `alongside`), so the rows move as one motion, never the sum of two.
    followChase.current?.alongside(turnEnd.current?.animations);
  }, [rows, sessionId, stopFollowMotion]);
  // The detector for a reply the chat holds but does not paint, for a turn this page saw end
  // (conversation/replyJudge.ts).
  useEndedReplyCheck({
    rows,
    sessionId,
    working,
    loading,
    dockSpace,
    scroller: ref,
    host: thread,
    follow: scrolledTo,
  });
  // Another chat shown, or the transcript unmounting: a fold still playing ends at once.
  useLayoutEffect(
    () => () => {
      settleTurnEnd(thread.current, turnEnd.current);
      turnEnd.current = undefined;
    },
    [sessionId],
  );
  // What this pass gave the room of the tray's open list (`trayHold`), and the rows it measured.
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- runs after every commit on purpose (it stores what this pass gave the room); its one setState call is guarded by the compare with noticeBase.
  useLayoutEffect(() => {
    const next = under.next.bases;
    foldBase.current = next.tray;
    cardBase.current = next.card;
    if (following || dockSpace <= 0) {
      noticeBaseRef.current = next.notice;
      if (noticeBaseRef.current !== noticeBase) setNoticeBase(noticeBaseRef.current);
    }
    rowsSeen.current = measured.layout.totalHeight - (measured.layout.origin ?? 0);
    if (under.next.trayTaken) trayToggled.current = false;
  });
  // The reader's wheel down at the end, over a tray list opened on it: the room under the last row
  // takes the list now, below the view, and the wheel scrolls into it (the view follows again once
  // it is at the end), so the rows under the list are a scroll away, not a fold.
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const giveTrayRoom = (event: WheelEvent) => {
      if (
        event.deltaY <= 0 ||
        !followingRef.current ||
        (dockTrayRef.current - foldBase.current <= 0.5 && dockCardRef.current - cardBase.current <= 0.5)
      )
        return;
      foldBase.current = dockTrayRef.current;
      cardBase.current = dockCardRef.current;
      trayToggled.current = false;
      // Room the reader came back down to stays under the list (`heldRoom.reader`).
      heldRoom.current.room = Math.max(dockRoomRef.current, heldRoom.current.reader.kept?.room ?? 0);
      flushSync(() => {
        followRef.current(false);
        roomTaken();
      });
    };
    node.addEventListener("wheel", giveTrayRoom, { passive: true });
    return () => node.removeEventListener("wheel", giveTrayRoom);
  }, []);
  // A toggled "Worked for" plays when its rows are placed again (watchTurnFold, started at the
  // toggle), not on every render. A render only checks, in O(1), whether the fold is over or another
  // chat shows, so nothing of it is left drawn over the new rows.
  useLayoutEffect(() => {
    const fold = turnFold.current;
    if (!fold || (performance.now() <= fold.until && fold.sessionId === sessionId)) return;
    settleTurnFold(thread.current, fold, foldGhosts.current);
    turnFold.current = undefined;
  });
  // Unmounted: the playing fold stops and lets go of its rows, and its copies go.
  useEffect(
    () => () => {
      settleTurnFold(thread.current, turnFold.current, foldGhosts.current);
      turnFold.current = undefined;
      for (const ghost of foldGhosts.current) ghost.remove();
      foldGhosts.current.clear();
    },
    [],
  );
  // Read at the click, so the callback stays the same across snapshots (rows compare it).
  const foldInputs = useRef({ layout, expanded, sessionId });
  foldInputs.current = { layout, expanded, sessionId };
  /// The reader's toggle of a row that opens or closes other rows ("Worked for", a subagent group):
  /// its motion starts from the rows as they are drawn now (turnFold.ts), then the pane toggles it.
  const toggleRow = useCallback(
    (id: string) => {
      const node = ref.current;
      const shown = rowsRef.current;
      const host = thread.current;
      settleTurnFold(host, turnFold.current, foldGhosts.current);
      // A turn's end still folding lands first: the reader's own fold starts from the rows drawn.
      settleTurnEnd(host, turnEnd.current);
      turnEnd.current = undefined;
      // At the very bottom (`beginBottomStackFold`, from this click) whole rows come or go: the
      // thread slides to their layout, and a body in the row settles at once.
      const stack = bottomStackFold.current;
      if (stack) {
        stack.rows = true;
        stack.row.setAttribute("data-bottom-fold", "");
      }
      // The clicked line: its open state, and the other keys a joined run's line is open under.
      const clicked = shown.find((row) => row.id === id);
      const fold =
        node && !stack
          ? startTurnFold(
              host,
              id,
              !(clicked?.foldOpen ?? foldInputs.current.expanded.has(id)),
              {
                count: shown.length,
                idAt: (index) => shown[index]?.id,
                geometry: foldInputs.current.layout.geometry,
              },
              foldInputs.current.sessionId,
            )
          : undefined;
      turnFold.current = fold;
      // The rows as placed by the latest render, read when a pass runs.
      const read = () => {
        const placed = rowsRef.current;
        const { layout, sessionId } = foldInputs.current;
        return {
          placed: {
            count: placed.length,
            idAt: (index: number) => placed[index]?.id,
            geometry: layout.geometry,
          },
          sessionId,
        };
      };
      if (fold && host)
        watchTurnFold(fold, host, read, foldGhosts.current, () => {
          if (turnFold.current === fold) turnFold.current = undefined;
        });
      onToggleActivity(id, foldCovers(clicked));
    },
    [onToggleActivity],
  );
  // Commit before this frame paints; deferring to the next animation frame left the edge blank.
  // The page picks adaptive rendering; the host supplies the display interval and applies it.
  const renderRate = useMemo(() => new AdaptiveRenderRate(), []);
  const pacing = useMemo(
    // Read only (a guest), the owner's host takes no pacing reports.
    () =>
      new ScrollPacing((intervals) => {
        if (!readOnly) void reportScrollPacing(intervals, callNative, renderRate);
      }),
    [renderRate, readOnly],
  );
  useEffect(() => () => pacing.stop(), [pacing]);
  // Find in Chat: a new current match scrolls its row in (it may not be mounted), then, once its
  // text is drawn, the match itself; every commit repaints the highlights over the mounted rows.
  const findQuery = find?.open ? find.query : "";
  const findTarget = find?.matches[find.active];
  const findTargetRowId = findTarget?.rowId;
  const findTargetOccurrence = findTarget?.occurrence;
  // Find matches the chat's rows; the transcript draws a match's row (or its copy in an open fold)
  // once its fold is open.
  const findIndex =
    findTargetRowId !== undefined ? findRowIndex(rows, findTargetRowId, rowHolds({ needle: findQuery })) : -1;
  const drawnId = rows[findIndex]?.id;
  const drawnCard = Boolean(rows[findIndex]?.ended);
  // Pending and delivered notice batches retain the matched member for disclosure and highlighting.
  const matchRowId = findMemberRowId(rows[findIndex], findTargetRowId);
  const inGroup = matchRowId !== undefined;
  const paintedId = matchRowId ?? drawnId;
  const revealing = useRef<string | undefined>(undefined);
  const targetKey =
    findTargetRowId !== undefined && findTargetOccurrence !== undefined && findQuery && drawnId !== undefined
      ? `${paintedId}:${drawnId}:${drawnCard}:${findTargetOccurrence}:${findQuery}`
      : undefined;
  // A group or call that opens to show the match asks for a render here, so the highlights and
  // the scroll below see its text.
  const [revealed, setRevealed] = useState(0);
  // Keyed on what it names, not the match object, which is new on each update while Find is open:
  // a new value would open again every group a reader closed.
  const findReveal = useMemo(
    () =>
      drawnId !== undefined && findQuery
        ? {
            rowId: drawnId,
            card: drawnCard,
            needle: foldFind(findQuery),
            repaint: () => setRevealed((count) => count + 1),
            ...(matchRowId !== undefined ? { matchRowId } : {}),
          }
        : undefined,
    [drawnId, drawnCard, findQuery, matchRowId],
  );
  // Find chooses the reader's new place. Discard the previous scroll owners synchronously;
  // closing Find, a query edit or a measurement must never put that old place back.
  const findMoved = useCallback(
    (node: HTMLDivElement) => {
      stopJump();
      stopScroll(node);
      stopBottomStackFold();
      foldAnchor.current = undefined;
      scrollPacer.current?.cancel();
      const top = node.scrollTop;
      const { layout: placed, rows: shown } = latestLayout.current;
      // A selected Find match is an explicit opening place, even when the initial transcript fit
      // the viewport. Complete that handoff now so the first later overflow preserves this place
      // instead of running the unopened-chat path to the latest row.
      if (!didOpenAtLatest.current) {
        didOpenAtLatest.current = true;
      }
      scrolledTo.current = { top, atLatest: false };
      seenAnchor.current = restingAnchor(top, false, placed, shown);
      scrollRef.current = { top, delta: top - scrollRef.current.top };
      setScroll(scrollRef.current);
      followRef.current(false);
      if (onAnchorRef.current) {
        clearTimeout(anchorTimer.current);
        anchorTimer.current = setTimeout(() => reportAnchorRef.current(), SCROLL_ANCHOR_SETTLE_MS);
      }
    },
    [stopBottomStackFold, stopJump],
  );
  // The current match's reveal window: 0 until it starts, then the window's own number.
  const revealWindow = useRef(0);
  const revealWindows = useRef(0);
  const findRequest = useRef<(() => boolean) | undefined>(undefined);
  const findFrame = useRef<number | undefined>(undefined);
  /// A row put a third down the view from code stays there through the momentum of a fling under
  /// way (holdMomentum), read by its id from the latest layout so a page landing above moves it too.
  const holdRowThird = (node: HTMLDivElement, rowId: string) => {
    const hint = { current: -1 };
    holdMomentum(node, () => {
      const { layout: placed, rows: shown } = latestLayout.current;
      const index = indexOfRow(shown, rowId, hint);
      return index < 0
        ? node.scrollTop
        : physicalScrollTop(node, Math.max(0, placed.geometry.topAt(index) - node.clientHeight / 3));
    });
  };
  useLayoutEffect(() => {
    findRequest.current = ref.current ? userScrollIntent(ref.current).request() : undefined;
  }, [findTargetRowId, findTargetOccurrence, findQuery]);
  const findTargetMoves = useCommittedEvent(() => {
    revealing.current = targetKey;
    revealWindow.current = 0;
    const node = ref.current;
    if (!node || !findTarget || !targetKey || !findRequest.current?.()) return;
    const top = layout.geometry.topAt(findIndex);
    const bottom = top + layout.geometry.heightAt(findIndex);
    // In view where it draws (`lift` from its place while the rows follow a grown composer).
    const drawn = layoutScrollTop(node) - liftRef.current;
    if (top >= drawn && bottom <= drawn + node.clientHeight - topInsetRef.current - dockSpaceRef.current) {
      findMoved(node);
      return;
    }
    unlift();
    node.scrollTop = physicalScrollTop(node, Math.max(0, top - node.clientHeight / 3));
    holdRowThird(node, rows[findIndex]!.id);
    findMoved(node);
  });
  // Only a new target scrolls, not a layout change.
  useLayoutEffect(() => findTargetMoves(), [findTargetMoves, targetKey]);
  // A row the running line's count names scrolls in once the transcript draws it (its fold may
  // open first), as a Find match does.
  const revealIndex = reveal ? findRowIndex(rows, reveal.rowId, rowHolds({ toolId: reveal.toolId })) : -1;
  const revealKey = reveal?.key;
  const revealDrawn = revealIndex >= 0;
  // One reveal per key, once its row is drawn.
  const countReveal = useHeldPer(`${revealKey}:${revealDrawn}`, () =>
    reveal && revealDrawn
      ? {
          rowId: rows[revealIndex]!.id,
          card: false,
          needle: "",
          toolId: reveal.toolId,
          repaint: () => {},
        }
      : undefined,
  );
  const rowRequest = useRef<(() => boolean) | undefined>(undefined);
  useLayoutEffect(() => {
    rowRequest.current = ref.current ? userScrollIntent(ref.current).request() : undefined;
  }, [reveal?.key]);
  const revealMoves = useCommittedEvent(() => {
    const node = ref.current;
    if (!node || revealIndex < 0 || !rowRequest.current?.()) return;
    const top = layout.geometry.topAt(revealIndex);
    const bottom = top + layout.geometry.heightAt(revealIndex);
    // In view where it draws (`lift` from its place while the rows follow a grown composer).
    const drawn = layoutScrollTop(node) - liftRef.current;
    if (top >= drawn && bottom <= drawn + node.clientHeight - topInsetRef.current - dockSpaceRef.current) return;
    unlift();
    // The reader asked for this row: the view stops following the reply, or the run opening below
    // would pull it back to the latest line.
    const next = Math.max(0, top - node.clientHeight / 3);
    stopJump();
    node.scrollTop = physicalScrollTop(node, next);
    holdRowThird(node, rows[revealIndex]!.id);
    scrolledTo.current = { top: node.scrollTop, atLatest: false };
    follow(false);
  });
  // Only a new reveal scrolls, not a layout change.
  useLayoutEffect(() => revealMoves(), [revealMoves, revealKey, revealDrawn]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    if (!findQuery) return clearFindHighlights();
    const current = paintFindHighlights(
      node,
      findQuery,
      findTargetRowId !== undefined && findTargetOccurrence !== undefined && drawnId !== undefined
        ? {
            rowId: paintedId!,
            card: inGroup ? false : drawnCard,
            occurrence: findTargetOccurrence,
          }
        : undefined,
    );
    if (!current || revealing.current !== targetKey || !findRequest.current?.()) return;
    // A match in a closed group is drawn before the group opens (with no size), and it moves as the
    // opened parts and the rows above it measure, so it is kept in view for a moment once drawn.
    if (!revealWindow.current) {
      const opened = (revealWindow.current = ++revealWindows.current);
      const start = performance.now();
      let frames = 0;
      const nextFrame = () => (frames += 1);
      let still = 0;
      let placed: number | undefined;
      const tick = () => {
        if (revealWindow.current !== opened) return;
        // The reader's own scroll, click or key ends the hold: the match is theirs to leave.
        if (!findRequest.current?.()) {
          revealing.current = undefined;
          return;
        }
        // Where the match sits in the transcript's content: it moves while what is above it measures,
        // and a move with no render (a block that grew) is brought back here, not only on a commit.
        const range = findActiveRange();
        if (range && range.getBoundingClientRect().height > 0) {
          scrollRangeInBoxes(node, range);
          const before = node.scrollTop;
          scrollRangeIn(node, range, dockSpaceRef.current);
          if (node.scrollTop !== before) findMoved(node);
        }
        const at = findMatchOffset(node);
        still = at !== undefined && placed !== undefined && Math.abs(at - placed) < 0.5 ? still + 1 : 0;
        placed = at;
        const elapsed = performance.now() - start;
        const settled = frames >= FIND_REVEAL_FRAMES && elapsed >= FIND_REVEAL_MS && still >= FIND_REVEAL_STILL_FRAMES;
        if (settled || nextFrame() >= FIND_REVEAL_MAX_FRAMES) revealing.current = undefined;
        else findFrame.current = requestAnimationFrame(tick);
      };
      findFrame.current = requestAnimationFrame(tick);
    }
    if (current.getBoundingClientRect().height === 0) return;
    // Inner scrollers first (a command's output scrolls on its own), then the transcript.
    scrollRangeInBoxes(node, current);
    const before = node.scrollTop;
    scrollRangeIn(node, current, dockSpaceRef.current);
    if (node.scrollTop !== before) findMoved(node);
    // Rows are immutable snapshots, so their identity changes when streamed text or a revealed
    // fold changes. The mounted-range signature catches virtualization entering/leaving rows.
  }, [
    drawnCard,
    drawnId,
    findQuery,
    findTargetOccurrence,
    findMoved,
    findTargetRowId,
    inGroup,
    mountedRangeKey,
    paintedId,
    revealed,
    rows,
    targetKey,
  ]);
  useEffect(() => clearFindHighlights, []);
  // Where the view rests, once a scroll settles; the latest message is null.
  const reportedAnchor = useRef<string | undefined>(undefined);
  const anchorTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const latestLayout = useRef({ layout, rows });
  latestLayout.current = { layout, rows };
  /// Lets the room above the loaded rows go when they are a tail shorter than the view and the view is
  /// within a viewport of their top with no page there yet (`roomGone` above). Runs after each
  /// placement and on every scroll event.
  ///
  /// Rows that fill the view keep the room: the reader stops at the loaded rows' top (`handleScroll`)
  /// until the page lands into it. Given up there, the room went at every page the reader caught up
  /// with and came back whole, the chat's estimated height, when the next page landed: the thumb leapt
  /// from the top to the bottom and back once a page, and the row on screen jumped by up to a viewport
  /// as the room came back (Leo, 2026-11-15: "this is super wack the way we're scrolling up
  /// infinitely :("; test/transcript-older-pages-anchor.test.ts).
  const giveRoomNearTop = () => {
    const node = ref.current;
    const room = layout.origin ?? 0;
    const first = rows[0];
    if (!node || !first || !canLoadOlder || room <= 0.5 || !didOpenAtLatest.current || node.clientHeight === 0) return;
    if (userScrollIntent(node).isScrollbarDragging()) return;
    if (node.scrollHeight - room >= node.clientHeight * OLDER_KEEP_ROOM_VIEWPORTS) return;
    if (layoutScrollTop(node) - room >= node.clientHeight * OLDER_LATE_VIEWPORTS) return;
    // A tail shorter than the view keeps its place at the view's foot: the room left is what lies
    // between the view's top and the rows, so nothing scrolls (read from the scroller itself, whose
    // height also holds the thread's own padding).
    const next = Math.max(0, Math.floor(room - Math.max(0, node.scrollHeight - node.clientHeight)));
    if (next >= room - 0.5) return;
    setRoomGone({ sessionId, firstId: first.id, room: next });
  };
  // After the placement pass above: its offset is the one this reads, and the state it sets renders
  // again before the frame paints.
  useLayoutEffect(giveRoomNearTop);
  useEffect(() => () => clearTimeout(anchorTimer.current), []);
  // A report that came due while the pane was hidden, sent once it has a viewport again.
  const anchorDeferred = useRef(false);
  useEffect(() => {
    clearTimeout(anchorTimer.current);
    anchorTimer.current = undefined;
    anchorDeferred.current = false;
    reportedAnchor.current = undefined;
  }, [sessionId]);
  const onAnchorRef = useRef(onAnchor);
  onAnchorRef.current = onAnchor;
  // WEB-SWAP: the transcript reopens at the place it reported (`chat.scrollAnchor`), so a web
  // update's reload waits only for a report still due (pages/shared/webSwap.ts). A hidden pane
  // reports where the reader last saw it (below), so it never holds the swap.
  useEffect(
    () =>
      holdWebSwap(() => (onAnchorRef.current && anchorTimer.current !== undefined ? "transcript.place-unsaved" : null)),
    [],
  );
  const reportAnchor = () => {
    anchorTimer.current = undefined;
    const node = ref.current;
    // Before the chat opens its offset is not the reader's: the kept place stays.
    if (!node || !onAnchor || !didOpenAtLatest.current) return;
    // A hidden pane (Home shown in its place) has no viewport: nothing it reads is where the reader is.
    anchorDeferred.current = node.clientHeight === 0;
    // Meanwhile it keeps where the reader last saw it (as `pane.wakeState` does); the report comes
    // again once it shows.
    if (anchorDeferred.current && seenAnchor.current === undefined) return;
    const { layout: placed, rows: shown } = latestLayout.current;
    const logicalTop = layoutScrollTop(node);
    const index = visibleLayoutRange(placed, logicalTop, 0, 0).first;
    const row = shown[index];
    const anchor: ScrollAnchor | null = anchorDeferred.current
      ? (seenAnchor.current ?? null)
      : scrolledTo.current.atLatest || !row
        ? null
        : { rowId: row.id, offset: logicalTop - placed.geometry.topAt(index) };
    const key = JSON.stringify(anchor);
    if (key === reportedAnchor.current) return;
    reportedAnchor.current = key;
    onAnchor(anchor);
  };
  // Find's stable callback reports through the latest sink, even if it appeared after mount.
  const reportAnchorRef = useRef(reportAnchor);
  reportAnchorRef.current = reportAnchor;
  useEffect(() => {
    if (height > 0 && anchorDeferred.current) reportAnchor();
  });
  // A page about to let go (pane.wakeState) is hidden: it has no viewport, so its place is where
  // the reader last saw it.
  useEffect(() => {
    if (!anchorNow) return;
    fillRef(anchorNow, () => seenAnchor.current);
    return () => fillRef(anchorNow, undefined);
  }, [anchorNow]);
  useEffect(() => {
    if (!inViewNow) return;
    fillRef(inViewNow, () => {
      const node = ref.current;
      if (!node || followingRef.current || node.clientHeight === 0) return null;
      const { layout: placed, rows: shown } = latestLayout.current;
      const view = visibleLayoutRange(placed, layoutScrollTop(node), node.clientHeight, 0);
      return shown.slice(view.first, view.last).map((row) => row.id);
    });
    return () => fillRef(inViewNow, undefined);
  }, [inViewNow]);
  // The reader sent a prompt: the view goes to the latest message before the frame paints, even
  // scrolled up, and follows the prompt's row and its reply in (Leo 2026-10-21). Only a scroll up
  // by the reader lets go of it again.
  const sendMoves = useCommittedEvent(() => {
    if (sends === seenSends.current) return;
    seenSends.current = sends;
    // The send's ride and the rows it brings are the motion the full rate is for: never a reason to cap it.
    renderRate.sent(performance.now());
    // The reader acted: the pinned Jump up mark goes, an idle stretch starts at the prompt's row once
    // it comes, and a way back a Jump up press held goes with the ride to the latest message (jumpUp.ts).
    if (jumpButton) dropJumpBack();
    if (jumpButton) idle.sent(promptScan.current.found);
    const node = ref.current;
    if (!node) return;
    if (!didOpenAtLatest.current) {
      // The chat has not opened yet (its tail still fits): it opens at the latest message once it
      // overflows, not at the reader's old place (the placement pass).
      sentBeforeOpen.current = true;
      // A tail that fits is at its latest row: the composer's prompt becomes the sent message
      // (conversation/sendMorph.ts). A chat that drew no row yet has none: its prompt fades in place.
      noteSendFromLatest(drewRowsBefore.current, node);
      // A tail that fit and overflows with this send opens at the latest row on the send's glide
      // (placement pass), and the reply's rows that land next rise on it too (`sendRows`).
      sendRiseUntil.current = performance.now() + SEND_RISE_MS;
      sendClockUntil.current = performance.now() + sendMotionMs(node);
      return;
    }
    revealing.current = undefined;
    revealWindow.current = 0;
    stopBottomStackFold();
    foldAnchor.current = undefined;
    dropFoldRoom();
    // Sent from the latest row: the view only moves by what came below, and the send's glide that
    // the placement pass may have started this commit (`followGlide.sent`) keeps playing.
    const fromLatest = followingRef.current && jumpTarget.current === undefined;
    // Only then does the composer's prompt become the sent message in place; scrolled up, it fades in
    // where it lands (conversation/sendMorph.ts, Leo 2026-11-08: "if you're at the bottom").
    noteSendFromLatest(fromLatest, node);
    if (fromLatest) {
      wheelGlide.current?.stop();
      stopScroll(node);
      // A send ends Jump to latest's hold here too (stopJump does it scrolled up): the placement pass
      // clears it only when the send's rows land on its chase branch, not on a ride, fold or resize.
      chaseHeld.current = false;
    } else stopJump();
    // The room the stack grew while scrolled up is room under the last row again (`room`), and the
    // room the reader came back down to goes with the send (`heldRoom.reader`).
    heldRoom.current.room = dockRoomRef.current;
    heldRoom.current.reader = { followed: heldRoom.current.reader.followed };
    // The placement pass already has the latest estimated total and measured viewport. Reusing
    // those values avoids forcing a style/layout flush from the send effect before the new row
    // paints; the following placement pass reconciles any drawn-height correction. A fractional
    // end is rounded up, as settleFollowBottomAt does, so WebKit's floor never rests a pixel short.
    clearScrollOrigin(node);
    const latest = Math.max(0, Math.ceil(layout.totalHeight - height - 0.01));
    const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    // The prompt's rows that land in the next commits glide in too (placement pass, `sendRows`).
    sendRiseUntil.current = performance.now() + SEND_RISE_MS;
    sendClockUntil.current = performance.now() + sendMotionMs(node);
    // Sent while scrolled up: on a page's own send clock the view glides down to the latest message
    // on Jump to latest's ride (one viewport at most), and the prompt's row and reply land on the
    // moving end. On the product's 0 clock (Leo, 2026-11-11: "that slow settle animation is just so
    // bad. Like, just do it."), Reduce Motion and motion off, it cuts there in this pass.
    if (!fromLatest && !reduce && sendClockMs(node) > 0) {
      rideToLatest(node, latest, false, false, true);
      followRequest.current = userScrollIntent(node).request();
      follow(true, "send");
    } else {
      const before = node.scrollTop;
      node.scrollTop = latest;
      holdMomentum(node, () => Math.max(0, node.scrollHeight - node.clientHeight));
      const top = node.scrollTop;
      scrolledTo.current = { top, atLatest: true };
      seenAnchor.current = null;
      followTrace.set(top);
      scrollPacer.current?.cancel();
      setScrollAt(top);
      // The commit this asks for places the rows with the stack's room and settles at that end, even
      // inside the hold that follows the reader's last input.
      followRequest.current = userScrollIntent(node).request();
      follow(true, "send");
      // Rows this commit added that the placement pass left unfollowed (a held follow): they rise on
      // the send's glide too.
      // On the product's 0 send clock the move to the new end is the send's own and lands in this
      // pass with its rows: chasing it drew the thread back by the whole rise (176 px) and brought it
      // home over 10 frames after the rows had landed (motion contract (c), `latest send`).
      if (chasing) {
        if (fromLatest && !(sendClockMs(node) > 0)) {
          stopFollowMotion();
          chaseFollow(node, layout, rows, Number.POSITIVE_INFINITY, true);
        } else if (fromLatest) chaseFollow(node, layout, rows, Number.POSITIVE_INFINITY, false, false, false, !steered);
      } else if (fromLatest && top - before > 0.5) followGlide.current?.sent(thread.current, top - before);
    }
    // The kept place is the latest message again: a relaunch opens there.
    if (onAnchor) {
      clearTimeout(anchorTimer.current);
      anchorTimer.current = setTimeout(reportAnchor, SCROLL_ANCHOR_SETTLE_MS);
    }
  });
  // Only a new send moves the view.
  useLayoutEffect(() => sendMoves(), [sendMoves, sends]);
  /// Jump to latest's ride from where the view is to `target` (the latest row's end), following the
  /// end as it moves: the button's, and a send's while scrolled up. `flush` mounts a skipped middle's
  /// rows at once from an event handler; a layout effect's own update already renders before paint.
  const rideToLatest = (node: HTMLDivElement, target: number, reduce: boolean, flush: boolean, send = false) => {
    // Use the rail's shared curve and distance duration, scaled by the host's move token. A send's
    // ride is the send motion instead (`--agent-motion-send`, its settling curve): the clock the sent
    // prompt's bubble and the thinking row come in on (conversation.css SEND-ENTRANCE).
    const style = node.ownerDocument.defaultView?.getComputedStyle(node);
    const move = cssTimeMs(style?.getPropertyValue("--agent-motion-move") ?? "");
    const sendMs = send ? (cssTimeMs(style?.getPropertyValue("--agent-motion-send") ?? "") ?? MOTION_SEND_MS) : 0;
    jumpTarget.current = target;
    // A long way from the end: skip the middle at once and glide only the last viewport, so the rows
    // in between never mount (jumpGlideStart). Set after jumpTarget, so its scroll reads as a glide step.
    const glideFrom = jumpGlideStart(node.scrollTop, target, node.clientHeight);
    if (!reduce && glideFrom !== node.scrollTop) {
      node.scrollTop = glideFrom;
      // Mount the rows at the new offset before this frame paints. Left to the scroll pacer, the
      // frame painted the skip with the rows of the old place, out of view: one blank frame
      // (transcript-cached-rows-browser "jump"). A layout effect's update renders before the paint.
      if (flush) flushSync(() => setScrollAt(node.scrollTop));
      else setScrollAt(node.scrollTop);
    }
    const duration = reduce
      ? 0
      : send
        ? sendMs
        : jumpDuration(target - node.scrollTop) * ((move ?? MOTION_MS.standard) / MOTION_MS.standard);
    animateScroll(
      node,
      () =>
        Math.max(
          0,
          node.scrollHeight > 0
            ? node.scrollHeight - node.clientHeight
            : latestLayout.current.layout.totalHeight - node.clientHeight,
        ),
      duration,
      send ? MOTION_SEND_CURVE : JUMP_CURVE,
      () => {
        jumpTarget.current = undefined;
        // What streams on after the landing keeps the latest row over the bottom stack.
        chaseHeld.current = chasing;
        scrolledTo.current = { top: node.scrollTop, atLatest: true };
        seenAnchor.current = null;
        followTrace.set(node.scrollTop);
        scrollPacer.current?.cancel();
        setScrollAt(node.scrollTop, 0);
      },
      () => {
        // A native turn/bookmark command can replace the shared ride without a DOM input event.
        // Explicit stopJump disowns first; only an external replacement releases bottom follow.
        if (jumpTarget.current === undefined) return;
        jumpTarget.current = undefined;
        scrolledTo.current = { top: node.scrollTop, atLatest: false };
        follow(false);
      },
      // A send's ride is the reader's newest input: it plays over the frames the page draws, never
      // spent before its first one (WebKit runs a ride started in the send's commit a frame later).
      { explicit: true, paced: send },
    );
  };
  // A scrollbar drag may cross the estimated room above the loaded rows while a page is in flight.
  // Keep that native drag target and consume the room as pages land; without it, handleScroll
  // clamps every pointer move to the same edge and a long chat appears to stop around its reserve.
  // Declared before the scroll handlers that write it, so React Compiler reads it as a ref.
  const olderScrollTarget = useRef<number | undefined>(undefined);
  /// The older-history check (below), which every scroll event runs too.
  const checkOlderNow = useRef<() => void>(() => {});
  const checkNewerNow = useRef<() => void>(() => {});
  /// The reader's speed up and how long pages take, which move the older-history ask further ahead.
  const [olderAhead] = useState(() => new OlderAhead());
  /// The room held above the loaded rows for history still to load (conversation/olderReserve.ts), 0 once
  /// it went (`roomGone`): what is left then is no history, only what keeps a short tail at the view's foot.
  const roomWent = () => roomGone !== undefined && roomGone.sessionId === sessionId && rows[0]?.id === roomGone.firstId;
  const roomAbove = () => (roomWent() ? 0 : (latestLayout.current.layout.origin ?? 0));
  /// The view is in that room, where no row is drawn, and no scrollbar drag holds it there (handleScroll
  /// gives it back).
  const inRoom = (node: HTMLDivElement, room: number) =>
    room > 0 && layoutScrollTop(node) < room && !userScrollIntent(node).isScrollbarDragging();
  /// The frame guard: while the reader scrolls, each frame reads the offset once more after its frame
  /// callbacks ran and before it paints and, if it moved since the last commit, handles it as its scroll
  /// event would and commits at once, so the frame paints the rows at the offset it paints. The scroll
  /// event of an offset written in a frame callback (a fling's or a drag's step, a wheel's default
  /// applied there) comes only in the next frame, and the scroll pacer's frame callback, run before that
  /// write or cancelled (an older page landing re-anchored the view) or not asked for (a scroll from
  /// rest), left the frame painting the rows the last commit mounted: a jump past them painted a view
  /// with no row, and a step into the room above the loaded rows was given back only after a frame had
  /// painted that room empty (Leo, 2026-11-17: "scrolling.. bit of blank screening when the content
  /// loads"). It mounts nothing the pacer would not: the same commit, earlier.
  /// The read runs in a ResizeObserver callback, the one hook after every frame callback and before the
  /// paint: a frame callback re-observes the scroller, whose new observation is delivered that frame.
  /// It runs until the offset has stood still SCROLL_GUARD_IDLE_MS. `handled` is the offset it handled,
  /// whose own scroll event (the next frame's) is then not handled again (`frameGuard`, above).
  const guardOffset = (node: HTMLDivElement) => {
    const state = frameGuard.current;
    const live = node.scrollTop;
    // Only a move restarts the idle clock: an offset the handler leaves unhandled (a chat not opened
    // yet, a hidden pane) would otherwise keep the guard running.
    if (live !== state.seen) guard.moved();
    // The pacer may have committed this offset already, inside the room: given back only by the handler.
    if (Math.abs(live - scrollRef.current.top) > 0.5 || (node.clientHeight > 0 && inRoom(node, roomAbove()))) {
      motionScroll.current(node, true);
      state.handled = node.scrollTop;
    }
    state.seen = node.scrollTop;
  };
  const armFrameGuard = () => guard.arm();
  /// Room a page showed short is paid for what the reader rose (olderReserve.ts `rose`) once their
  /// input is quiet, in one pass the anchor holds, never on each scroll event: a rise paid at every
  /// event changed the room above the rows mid-scroll and the offset with it (transcript-motion-model.md
  /// audit #6, step 3). Stops once paid; a scroll that comes in the meantime starts the wait again.
  const payRoomWhenQuiet = (node: HTMLDivElement) => {
    clearTimeout(roomRoseTimer.current);
    roomRoseTimer.current = setTimeout(() => {
      roomRoseTimer.current = undefined;
      if (userScrollIntent(node).isHeld()) {
        payRoomWhenQuiet(node);
        return;
      }
      const rise = roomRosePending.current;
      roomRosePending.current = 0;
      if (rise > 0) setRoomRose((total) => total + rise);
    }, SCROLL_GUARD_IDLE_MS);
  };
  const handleScroll = (node: HTMLDivElement, immediate = false) => {
    armFrameGuard();
    pacing.scrolled();
    // A row whose glide the reader's input held, scrolled out of view, lands now where nobody sees it,
    // so it never plays on under the view when they come back to the latest row (tailGlide.ts).
    if (!followingRef.current) tailGlide.current?.dropUnseen(() => node.getBoundingClientRect());
    // Before the chat opens its offset moves only as pages land unseen: none of it is the reader's.
    if (!didOpenAtLatest.current) return;
    // A hidden scroller has no height, so every offset would read as scrolled up (cx-t0zqt): the view
    // keeps following until the reader scrolls a visible one.
    if (node.clientHeight === 0) return;
    // The room above the loaded rows holds history still to load (conversation/olderReserve.ts):
    // the reader stops at the loaded rows' top, as at the top of the chat, until a page lands into
    // the room. A view inside it showed nothing, and the pages then landed under it unseen.
    // Once it went (`roomGone`), what is left is no history to load, only what keeps a short tail at
    // the view's foot: nothing to hold the reader from.
    const gone = roomWent();
    const room = roomAbove();
    if (inRoom(node, room)) {
      // Only a pointer held on the scroller (a thumb drag the scrollbar check missed) keeps its target
      // for the page to bring into reach. A wheel's step into the room is given back here and stays
      // given back: kept, it was replayed in one frame when the page landed, and the row being read
      // leapt by that step on top of the wheel's own (test/transcript-older-pages-anchor.test.ts).
      olderScrollTarget.current = noteOlderScrollTarget(
        olderScrollTarget.current,
        layoutScrollTop(node),
        room,
        userScrollIntent(node).isPressed(),
      );
      wheelGlide.current?.stop();
      node.scrollTop = physicalScrollTop(node, room);
    }
    // Room a page showed short (conversation/olderReserve.ts `owed`) is paid back as the reader rises,
    // under each step's height, so the thumb keeps moving up with them instead of stepping down once.
    // Read among the rows (less the room above them), so room paid or a page landing is no rise.
    const paidAt = layoutScrollTop(node) - room;
    const paidFrom = roomPaidFrom.current;
    roomPaidFrom.current = paidAt;
    if (!gone && paidFrom !== undefined && paidFrom > paidAt && !followingRef.current && olderRoom.current?.owed) {
      roomRosePending.current += paidFrom - paidAt;
      payRoomWhenQuiet(node);
    }
    giveRoomNearTop();
    olderAhead.scrolled(paidAt, performance.now());
    checkOlderNow.current();
    checkNewerNow.current();
    const next = node.scrollTop;
    trimFoldRoom(node);
    // A step of Jump to latest's glide: the view is following on its way to the end, not snapped
    // there (a first step inside the deadband read as layout work), and not stopped (a longer one
    // read as the reader's scroll up).
    if (jumpTarget.current !== undefined) {
      scrolledTo.current = { top: next, atLatest: true };
      seenAnchor.current = null;
      followTrace.set(next);
      queueScroll(next, true, immediate);
      // The kept place is the latest message again (a reopened chat opens there, not where the
      // reader was before the jump).
      if (onAnchor) {
        clearTimeout(anchorTimer.current);
        anchorTimer.current = setTimeout(reportAnchor, SCROLL_ANCHOR_SETTLE_MS);
      }
      return;
    }
    const programmatic = !userScrollIntent(node).isHeld();
    // Its event can come before the stack's next pass does.
    if (programmatic && !releaseBottomStackFold(node)) releaseFoldHold(node);
    // The right-hand card holds what it shows until the reader's scroll settles
    // (summary/heldWhileScrolling.ts): older history paged in under the scroll lands there once.
    if (!programmatic) noteReaderScroll();
    // ResizeObserver/layout work can emit a scroll event after the stack below the transcript
    // changes. While the reader is following, keep the viewport at the new end and do not let
    // that synthetic event clear the follow state. A real wheel/touch/key event marks itself first.
    // A layout-driven scroll keeps the previous offset; a reader scroll changes it. The latter is
    // also what the jsdom behavior tests dispatch without a wheel event, so do not classify every
    // programmatic-looking event as layout work.
    // A held disclosure (foldAnchor) keeps the view where it is, not at the latest row.
    const layoutDriven =
      followingRef.current &&
      programmatic &&
      !foldAnchor.current &&
      Math.abs(next - scrolledTo.current.top) <= FOLLOW_BOTTOM_DEADBAND_PX;
    if (layoutDriven) {
      // No further than a sent prompt's view (`sendTopEnd`).
      const sendTopAt = sendTop.end > 0 ? Math.max(0, sendTop.end - node.clientHeight) : Number.POSITIVE_INFINITY;
      const latest = Math.min(Math.max(0, layout.totalHeight - node.clientHeight), sendTopAt);
      // The offset it settled on, read before its origin's style write (never after it).
      const resting = settleFollowBottomAt(node, latest).top;
      scrolledTo.current = { top: resting, atLatest: true };
      followTrace.set(resting);
      queueScroll(resting, true, immediate);
      return;
    }
    const was = scrolledTo.current;
    const upPending = readerUpPending.current;
    if (readerUpPending.current) readerUpPending.current = false;
    const measured = scrollPosition(node, layout.totalHeight);
    // A fall that still rests at or past the scroller's own end, with no upward input behind it, is
    // the browser's spring back, not the reader leaving: a trackpad scroll down at the end stretches
    // the scroller on macOS, WebKit reports the stretch in the offset, and its return is a run of
    // scroll events falling back to the end inside the reader's input hold. Read as the reader's
    // scroll up, each stopped following at the very end, and the reply streaming on grew under the
    // composer behind Jump to latest until the next wheel at the end armed it again (Leo, 2026-11-18:
    // "did we fix this scroll bounce at the bottom yet?"; agent-pane-bottom-rebound-follow.test.ts).
    // The layout pass reads the same fall as a clamp (`clamped`). A reader's own step up leaves the end.
    // A scroller with no layout (scrollHeight 0) ends at the rows' own height, as the jump's end reads it.
    const scrollEnd = (node.scrollHeight > 0 ? node.scrollHeight : layout.totalHeight) - node.clientHeight;
    const sprangBack = !upPending && next >= scrollEnd - 0.5;
    // A recent upward input is authoritative even when it moved only a pixel or two. The
    // deadband absorbs layout rounding, but must not turn a real trackpad step into bottom follow.
    const movedUp = !sprangBack && next < was.top - 0.5;
    const recentUp = !programmatic && movedUp;
    // Only the reader's own downward scroll input brings following back at the end; the input hold
    // alone (`programmatic`) is any input of the last second, a press or a hover after a lost
    // release too, and a layout change landing at the end inside it is not the reader's.
    const down = readerDown.current;
    const readerMovedDown = down !== undefined && performance.now() - down.at <= READER_SCROLL_MS;
    // The scroller's own end counts too (Leo, 2026-11-11: "I scroll down to the bottom. I have to,
    // like, scroll down again because it didn't realize"): a row that lands as the reader gets
    // there (the thinking row, a tooltip's room) puts the layout's end past the offset the browser
    // could still reach, and a later wheel at the end scrolls nothing, so no scroll event came to
    // arm it.
    const atEnd = next >= node.scrollHeight - node.clientHeight - FOLLOW_BOTTOM_DEADBAND_PX;
    const readerReachedBottom =
      !programmatic && readerMovedDown && next > was.top + 0.5 && (measured.atLatest || atEnd);
    scrolledTo.current = {
      top: next,
      atLatest: recentUp || (movedUp && !measured.atLatest) ? false : followingRef.current || readerReachedBottom,
    };
    const latest = Math.max(0, layout.totalHeight - node.clientHeight);
    if (was.atLatest && !scrolledTo.current.atLatest)
      followTrace.stopped({
        top: next,
        previous: was.top,
        latest,
        scrollHeight: node.scrollHeight,
        clientHeight: node.clientHeight,
      });
    followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);
    seenAnchor.current = restingAnchor(layoutScrollTop(node), scrolledTo.current.atLatest, layout, rows);
    // The reader's own scroll: an idle stretch starts where it rests, a third down the view where a
    // press puts it back (Jump up, jumpUp.ts), the mark it pinned goes, and a way back Jump up held is
    // theirs no longer.
    // Only an input that scrolls (userScroll.ts `scrolledByHand`): a press on text holds the view as
    // any input does, but a row settling or a page landing inside that hold is not the reader moving.
    // Jump up's own move (`placeView`) lands inside the press's input hold, so it reads as the
    // reader's: the offsets its glide steps through and the one it lands on are not stops, and it
    // keeps the way back it holds.
    const placed = placedTop.current;
    placedTop.current = undefined;
    const byHand = !programmatic && userScrollIntent(node).scrolledByHand();
    if (byHand && !placing.current && (placed === undefined || Math.abs(next - placed) > 1)) {
      idle.scrolled(restingAnchor(layoutScrollTop(node) + node.clientHeight / 3, false, layout, rows) ?? undefined);
      if (jumpBack.current) {
        jumpBack.current = undefined;
        setJumpBackHeld(false);
      }
    }
    queueScroll(next, scrolledTo.current.atLatest, immediate, "reader-scroll", down?.input ?? null);
    if (onAnchor) {
      clearTimeout(anchorTimer.current);
      anchorTimer.current = setTimeout(reportAnchor, SCROLL_ANCHOR_SETTLE_MS);
    }
  };
  const motionScroll = useRef(handleScroll);
  motionScroll.current = handleScroll;
  useLayoutEffect(() => {
    guardRead.current = () => {
      const node = ref.current;
      if (node && transcriptMounted.current) guardOffset(node);
    };
  });
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    // The shared motion clock emits only from RAF callbacks, after writing scrollTop. Mount
    // the visible rows before that frame paints; native scroll arrives a frame too late.
    const moved = () => motionScroll.current(node, true);
    node.addEventListener(MOTION_SCROLL_EVENT, moved);
    return () => node.removeEventListener(MOTION_SCROLL_EVENT, moved);
  }, []);
  const onScroll = (event: React.UIEvent<HTMLDivElement>) => {
    const node = event.currentTarget;
    // The frame guard handled this offset in the frame that wrote it: handled again, its zero move would
    // read as the reader stopping (OlderAhead's speed) and the older pages would ask late.
    const handled = frameGuard.current.handled;
    frameGuard.current.handled = undefined;
    if (handled !== undefined && Math.abs(node.scrollTop - handled) <= 0.5) return;
    handleScroll(node);
  };
  // Jump to latest: transcript/jumpWiring.ts `jumpToLatestWith`.
  const jumpToLatest = (focused: boolean, path?: string) =>
    jumpToLatestWith(
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
        idle,
        dropJumpBack,
        stopJump,
        rideToLatest,
      },
      focused,
      path,
    );
  jumpToLatestRef.current = jumpToLatest;
  // Jump up's glide to a place: transcript/jumpWiring.ts `placeViewWith`.
  const placeView = (top: () => number) =>
    placeViewWith(
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
      },
      top,
    );
  const pressUp = () =>
    pressUpWith({
      ref,
      jumpBack,
      setJumpBackHeld,
      followingRef,
      jumpToLatest,
      placeView,
      upTopRef,
      latestLayout,
    });
  const pressUpRef = useRef(pressUp);
  pressUpRef.current = pressUp;
  // Esc goes back while Jump up holds a way back, unless something before it took the key (the
  // composer's Esc that arms Stop, a menu, a picker): those call preventDefault.
  useEffect(() => {
    if (!jumpBackHeld) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      pressUpRef.current();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [jumpBackHeld]);
  // Another chat: its own places (its idle stretch loads with it, above), nothing held from this one.
  useLayoutEffect(() => {
    jumpBack.current = undefined;
    setJumpBackHeld(false);
  }, [sessionId]);
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const intent = userScrollIntent(node);
    // The motion model's watcher (docs/design/transcript-motion-model.md): warn-only, flags a move no
    // transition declared; on with perf, `cmux.layoutWatch`, or a dev build.
    const stopLayoutWatch = layoutWatchWanted(acpmuxPerf.enabled)
      ? startLayoutWatch(node, {
          streaming: () => workingRef.current,
          lastRowId: () => rowsRef.current.at(-1)?.id,
          onFlag: () => acpmuxPerf.render("layout.unexplained_shifts"),
          overlay: true,
        })
      : undefined;
    // The list the motion owner drives (conversation/motionOwner.ts). The fold hold still keeps the
    // line on its pixel, so a fold's transition only declares its move; the anchored list takes the
    // scroll write over at step 10.
    const motionList: MotionList = {
      offsetOf: (rowId) => {
        const row = node.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(rowId)}"]`);
        return row ? row.getBoundingClientRect().top - node.getBoundingClientRect().top : undefined;
      },
      scrollBy: () => {},
      rowsAfter: (rowId) => {
        const ids = rowsRef.current.map((row) => row.id);
        const at = ids.indexOf(rowId);
        return at < 0 ? [] : ids.slice(at + 1);
      },
      settle: () => {},
    };
    const declareFold = (line: Element | null | undefined) => {
      const rowId = line?.closest<HTMLElement>("[data-row-id]")?.dataset.rowId;
      if (rowId)
        transition(motionList, { cause: "disclosure", anchorRow: rowId, ms: FOLD_HOLD_MIN_MS + FOLD_SETTLE_MS });
    };
    // First on the window, so a fling's momentum held after a jump reaches no other listener.
    const removeMomentumHold = installMomentumHold(node, scrollRunning);
    const detachIntent = attachUserScrollIntent(node);
    /// `up`: the reader's own move up (a wheel, key or touch up, a scrollbar drag) let the latest row go, so
    /// room they come back down to is theirs (`heldRoom.reader`). A click (the queue's fold) moves nothing.
    const followIntent = (next: boolean, up?: true) => {
      if (!next && up) heldRoom.current.reader = { ...heldRoom.current.reader, left: true };
      followRef.current(next);
    };
    const cancelProgrammatic = (event?: Event) => {
      if (intent.isScrollbarDragging()) {
        if (!olderDragPending.current && previousLayout.current) {
          setScrollbarRange({
            session: heldSession.current,
            height: previousLayout.current.totalHeight,
          });
        }
        olderDragPending.current = true;
        followIntent(false, true);
      }
      revealing.current = undefined;
      revealWindow.current = 0;
      // A sideways wheel (a code block's own scroll) keeps a disclosure's hold; the rest lets go.
      const held = bottomStackFold.current;
      if (!(event?.type === "wheel" && !verticalWheel(event as WheelEvent))) {
        stopBottomStackFold();
        foldAnchor.current = undefined;
      }
      if (findFrame.current !== undefined) cancelAnimationFrame(findFrame.current);
      findFrame.current = undefined;
      if (reader(event)) followIntent(false);
      // Up and away from a fold at the very bottom: it lands now, at its own height.
      if (held && !bottomStackFold.current && !followingRef.current) landForReader(held.row);
      // Moving toward the latest row while following keeps following through the hold.
      else if (followingRef.current && movingDown(event)) followRequest.current = intent.request();
      if (jumpTarget.current !== undefined) {
        stopJump();
        scrolledTo.current = { top: node.scrollTop, atLatest: false };
        followIntent(false);
      }
    };
    let pointerY: number | undefined;
    let touchY: number | undefined;
    /// The input behind a downward scroll of the transcript itself, or undefined for any other.
    const readerDownInput = (event: Event | undefined, pointer?: PointerEvent, touch?: Touch) => {
      if (event?.type === "wheel") {
        const wheel = event as WheelEvent;
        return wheel.deltaY > 0 && wheelScrollsDown(wheel, node) ? `wheel ${Math.round(wheel.deltaY)}` : undefined;
      }
      if (event?.type === "keydown") {
        const key = event as KeyboardEvent;
        return !key.shiftKey && !editableTarget(key.target) && movingDown(key)
          ? `keydown ${key.metaKey ? "Meta+" : ""}${key.key}`
          : undefined;
      }
      // A drag: the scrollbar's thumb moving down, or a finger moving up the page.
      if (
        pointer &&
        pointerY !== undefined &&
        (pointer.pointerType === "touch" ? pointer.clientY < pointerY : pointer.clientY > pointerY)
      )
        return `pointermove ${pointer.pointerType}`;
      if (touch && touchY !== undefined && touch.clientY < touchY) return "touchmove";
      return undefined;
    };
    const reader = (event?: Event) => {
      // The wheel over a rail that scrolls itself scrolls the rail, not the transcript: the reader is
      // not moving the transcript, so follow and a jump in flight stay as they are (railWheel.ts).
      if (event && railOwnsWheel(event)) return;
      const pointer = event?.type === "pointermove" ? (event as PointerEvent) : undefined;
      const touch = event?.type === "touchmove" ? (event as TouchEvent).touches[0] : undefined;
      const movingUp =
        event !== undefined &&
        ((event.type === "wheel" && (event as WheelEvent).deltaY < 0) ||
          (event.type === "keydown" && ["ArrowUp", "PageUp", "Home"].includes((event as KeyboardEvent).key)) ||
          (pointer !== undefined &&
            pointerY !== undefined &&
            (pointer.pointerType === "touch" ? pointer.clientY > pointerY : pointer.clientY < pointerY)) ||
          (touch !== undefined && touchY !== undefined && touch.clientY > touchY));
      const downInput = readerDownInput(event, pointer, touch);
      if (movingUp) readerDown.current = undefined;
      else if (downInput) readerDown.current = { at: performance.now(), input: downInput };
      // A wheel or key down at the scroller's end, where the browser scrolls nothing and sends no
      // scroll event: the reader is at the latest row, so it follows again from here. A pressed drag
      // (selecting text near the end) is not a move to the latest row, nor a key a control keeps (the
      // thread rail's arrows walk its prompts): only a key on the transcript itself or the page.
      if (
        downInput &&
        (event?.type === "wheel" ||
          (event?.type === "keydown" && (event.target === node || event.target === node.ownerDocument.body))) &&
        !followingRef.current &&
        jumpTarget.current === undefined &&
        node.clientHeight > 0 &&
        node.scrollTop >= node.scrollHeight - node.clientHeight - FOLLOW_BOTTOM_DEADBAND_PX
      ) {
        scrolledTo.current = { top: node.scrollTop, atLatest: true };
        followRef.current(true, "reader-end");
        followRequest.current = intent.request();
      }
      if (event?.type === "pointerdown") {
        pointerY = (event as PointerEvent).clientY;
      } else if (pointer) pointerY = pointer.clientY;
      if (event?.type === "touchstart") touchY = (event as TouchEvent).touches[0]?.clientY;
      else if (touch) touchY = touch.clientY;
      readerAt.current = performance.now();
      frameBudget.current?.poke();
      // The reader moved: where they are now is their place, not the one a reconnect held.
      heldPlace.current = undefined;
      // Wheeling on at the top of the loaded rows scrolls nothing while older history pages in: the
      // reader's input, not only its scroll events, keeps the right-hand card held
      // (summary/heldWhileScrolling.ts).
      noteReaderScroll();
      followTrace.input();
      if (slimFollow) {
        // The slim arm (the product's): what still glides holds where it is drawn, so nothing jumps
        // under the reader's input (the composer growth's rise freezes into the chase there,
        // followChase.carry), and once the input goes quiet the whole offset goes to the scroll
        // position (`settleHeldFollowMotion`), followed or not, so nothing settles on after it either
        // (Leo, 2026-11-09: "when i scroll down now there's a little readjustment sometimes that shold
        // never happen").
        followGlide.current?.stop();
        tailGlide.current?.hold();
        freezeGrowthRise.current();
        followChase.current?.hold();
        chaseAnchor.current = undefined;
      } else {
        // The other arms: a glide still easing lands where it lays out, and the chase holds where it
        // is drawn, so nothing moves but the reader's own scroll (a snap home moved the rows a frame
        // before the scroll, streaming-parked-still.test.ts). Followed again, it goes on home.
        followGlide.current?.stop();
        // Input that leaves the view followed (a wheel or key at the bottom scrolls nothing, and no
        // layout pass may come after) goes on home on the next frame instead of staying drawn away.
        // The rows under a change gliding to their place hold where they are drawn too (tailGlide.ts),
        // and play on with the chase.
        tailGlide.current?.hold();
        freezeGrowthRise.current();
        followChase.current?.hold(() => {
          const followed = followingRef.current && jumpTarget.current === undefined;
          if (followed) tailGlide.current?.resume();
          return followed;
        });
        chaseAnchor.current = undefined;
      }
      // Release the follow intent synchronously when a reader starts moving up. The browser can
      // deliver the input before its scroll event; a streamed snapshot in that gap must not pin
      // the view back to the bottom. Capture the event so nested rows cannot commit first.
      if (movingUp) followIntent(false, true);
      // A new downward/neutral gesture supersedes a retained scrollbar target. Without clearing
      // it here, the reserve-drain effect would put the reader back at the loaded edge after they
      // deliberately returned toward newer messages.
      if (
        !movingUp &&
        event !== undefined &&
        ["wheel", "keydown", "pointerdown", "pointermove", "touchstart", "touchmove"].includes(event.type)
      )
        olderScrollTarget.current = undefined;
      readerUpPending.current = movingUp;
      if (jumpTarget.current !== undefined) {
        stopJump();
        scrolledTo.current = { top: node.scrollTop, atLatest: false };
        followIntent(false);
      }
      return Boolean(movingUp);
    };
    const unsubscribeIntent = intent.subscribe(cancelProgrammatic);
    // End or Cmd-Down with the page focused, where the browser scrolls nothing: to the latest
    // message, as a row's own End does (rowKeyDown). A field keeps its keys (Find's search moves
    // its caret), and the transcript itself focused scrolls natively, a downward scroll of the
    // reader's own (`readerDown`).
    const endKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || !toLatestKey(event) || event.target !== node.ownerDocument.body) return;
      if (editableTarget(event.target)) return;
      event.preventDefault();
      jumpToLatestRef.current(false, "end-key");
    };
    node.ownerDocument.addEventListener("keydown", endKey);
    // The reader left the latest row while the follow motion was in flight, and their input has gone
    // quiet: what the chase still held is folded into the scroll offset (the thread drawn back by x is
    // the same picture as the offset x less). Held, it
    // played the moment the reader scrolled back down to the latest row: the rows moved under a view
    // the reader had just put where they wanted it (Leo, 2026-11-09: "when i scroll down now there's
    // a little readjustment sometimes that shold never happen"). Nothing on screen moves here. The rows'
    // own glides (tailGlide.ts) are each a different move, so no offset takes them back: one whose row
    // is out of view ends here and as the reader scrolls (`dropUnseen`), unseen; one still in view stays
    // paused where it is drawn (cutting it short snapped the row). O(1); runs once per quiet input.
    const settleHeldFollowMotion = () => {
      // The slim arm hands a held chase to the scroll offset in a followed view too: played on from
      // where it was held, it was the "little readjustment" after the reader's own scroll.
      if ((followingRef.current && !slimFollow) || jumpTarget.current !== undefined) return;
      tailGlide.current?.dropUnseen(() => node.getBoundingClientRect());
      const chase = followChase.current;
      // Whole pixels only: the offset moves by an exact number of its own ticks, so the browser never
      // rounds the write (WebKit drew a fractional fold 0.7 px off). Under a pixel stays drawn.
      const held = Math.round(chase?.outstanding() ?? 0);
      if (!chase || held === 0) return;
      const top = layoutScrollTop(node) - held;
      // An offset the scroller cannot take (a thread drawn above its layout at the very end) stays
      // drawn, as before; it goes home when the view is followed again. Nor one inside the room held
      // for older history: handleScroll clamps the offset back to the room, which would draw the
      // released translate as a jump.
      const room = latestLayout.current.layout.origin ?? 0;
      if (top < room || top > node.scrollHeight - node.clientHeight) return;
      // The physical offset moves by the whole pixels, so the origin under it (a fraction an anchor
      // write left) stays as it is and the browser rounds nothing.
      const physical = node.scrollTop;
      const was = layoutScrollTop(node);
      node.scrollTop = physical - held;
      // Where the browser put it, read right after the scroll write and before the origin's style
      // write: a scroll write leaves the page laid out, so this read lays nothing out again, and
      // nothing below reads the scroller after the style write (each such read laid the page out).
      const landed = node.scrollTop;
      retainScrollOrigin(node, top);
      // A write the scroller did not take (a scroll of its own still easing in), or a chase that is
      // not held after all, keeps the chase drawn where it is and the offset where it was.
      if (Math.abs(landed - scrollOrigin(node) - top) > 1 || !chase.release(held)) {
        node.scrollTop = physical;
        retainScrollOrigin(node, was);
        return;
      }
      scrolledTo.current = { top: landed, atLatest: false };
      scrollPacer.current?.cancel();
      setScrollAt(landed, 0);
    };
    const unsubscribeQuiet = intent.subscribeQuiet(() => {
      if (olderDragPending.current) {
        olderDragPending.current = false;
        setScrollbarRange(undefined);
      }
      settleHeldFollowMotion();
      if (!followDeferred.current) return;
      followDeferred.current = false;
      if (followingRef.current) resumeDeferredFollow();
    });
    // attachUserScrollIntent captures the scroller and scrollbar inputs (a drag outside the
    // scroller too), then invokes this reader through the shared subscription before layout or
    // streaming can commit. A drag's end or a canceled input leaves no upward move pending.
    const readerReleased = () => {
      readerUpPending.current = false;
      if (olderDragPending.current) {
        olderDragPending.current = false;
        setScrollbarRange(undefined);
      }
    };
    const readerCanceled = (event: Event) => {
      if (event.defaultPrevented && node.contains(event.target as Node)) readerUpPending.current = false;
    };
    const ownerDocument = node.ownerDocument;
    ownerDocument.addEventListener("pointerup", readerReleased, {
      capture: true,
    });
    ownerDocument.addEventListener("pointercancel", readerReleased, {
      capture: true,
    });
    ownerDocument.addEventListener("lostpointercapture", readerReleased, {
      capture: true,
    });
    ownerDocument.defaultView?.addEventListener("blur", readerReleased);
    const canceledInputs = ["wheel", "keydown"] as const;
    for (const name of canceledInputs) ownerDocument.addEventListener(name, readerCanceled, { passive: true });
    // A click on a disclosure line holds it where it is (foldAnchor.ts), before the row's own handler
    // opens it.
    // A turn fold still sliding rows lands first, and the offset takes up however far that moved the
    // clicked line, so the hold keeps it on the pixel it was clicked at. So does another line's close
    // that pinned the bottom part way (`startBottomStack` from the placement pass): its thread slide
    // lands with the rows it moves with, never cut short while they land.
    // The follow motion in flight (the chase drawing the thread back while the reply streams, the
    // rows under an arrival gliding home) lands with it the same way: the reader's toggle is one
    // motion owned by the fold from the pixel they clicked, never the fold's hold and the chase both
    // moving the line on alternate frames, nor the chase snapping home under the hold later (Leo,
    // 2026-11-06: "things clash with other things with animations going haywire").
    const settleFold = (line: HTMLElement) => {
      const playing = bottomStackFold.current;
      const stack = playing?.animation && playing.toggle !== line ? playing : undefined;
      const chasing = Math.abs(followChase.current?.outstanding() ?? 0) >= 0.5 || tailGlide.current?.moving() === true;
      if (!turnFold.current && !stack && !chasing) return;
      const before = line.getBoundingClientRect().top;
      if (chasing) stopFollowMotion();
      if (turnFold.current) settleTurnFold(thread.current, turnFold.current, foldGhosts.current);
      turnFold.current = undefined;
      if (stack) {
        for (const held of stack.held ?? []) held.finish();
        for (const cut of stack.cuts?.values() ?? []) cut.finish();
        stack.animation?.finish();
        stopBottomStackFold();
      }
      const moved = line.getBoundingClientRect().top - before;
      if (node && Math.abs(moved) >= 0.5) node.scrollTop += moved;
    };
    // What closes keeps the content as tall as the view's end, so the offset never clamps.
    const keepFoldRoom = () => {
      if (!node) return;
      const end = foldRoomFor(node.scrollTop, node.clientHeight, foldRoomRef.current);
      if (end === foldRoomRef.current) return;
      foldRoomRef.current = end;
      setFoldRoom(end);
    };
    // The control a click landed on, for the hold its row's collapsible asks for in the same click
    // (holdAsked): a long prompt's Show more asks to hold its bubble, which has no open state of its
    // own, so whether the click opens is the Show more's.
    let clicked: HTMLElement | undefined;
    /// Whether the view was at its very end when `clicked` was clicked, before `settleFold` took the
    /// follow motion into the offset (which moves it up by what the chase still drew back).
    let clickedAtEnd = false;
    const atEnd = () => atFoldBottom(node.scrollTop, node.clientHeight, node.scrollHeight, FOLLOW_BOTTOM_DEADBAND_PX);
    const beginBottomStackFold = (toggle: HTMLElement, line: HTMLElement, wasAtEnd = atEnd()): boolean => {
      // At the very bottom a close pins the bottom and pulls the text above it down, so no blank room
      // is left under the rows (Leo, 2026-11-03: "it's weird to collapse and get all that empty space
      // at the bottom"). An open never pins it, as Codex opens a call at the end of a chat (Lucas,
      // 2026-11-06: Codex parity): the line and the rows over it stay where the reader clicked, what
      // opens grows down under the composer, and the view stops following, so Jump to latest shows.
      if (opensBody(toggle) || !wasAtEnd) {
        stopBottomStackFold();
        return false;
      }
      if (!line.closest(".acpmux-row")) return false;
      stopBottomStackFold();
      return startBottomStack(node, line);
    };
    const holdClicked = (event: MouseEvent) => {
      const toggle = node ? foldToggleAt(event.target, node) : undefined;
      if (!toggle) return;
      // A drag or a selection that ended on the line opens nothing (useAnchoredCollapse
      // `deliberateClick`): nothing to hold.
      const at = pressedAt;
      pressedAt = undefined;
      if (!deliberateClick(event, toggle, at)) {
        pressed = undefined;
        return;
      }
      const line = foldHoldTarget(toggle, node ?? undefined);
      const wasAtEnd = atEnd();
      settleFold(line);
      clicked = toggle;
      clickedAtEnd = wasAtEnd;
      setTimeout(() => {
        if (clicked === toggle) clicked = undefined;
      });
      const bottom = beginBottomStackFold(toggle, line, wasAtEnd);
      // A keyboard click (detail 0) had no press: an older, abandoned one is not its place.
      declareFold(line);
      foldAnchor.current = clickFold(line, event.detail > 0 ? pressed : undefined, undefined, toggle);
      holdTop.current = node?.scrollTop;
      pressed = undefined;
      if (!bottom) keepFoldRoom();
    };
    // The press notes where the line was: if streaming moves it before the click lands, the click's
    // hold puts it back where the reader pressed it. It holds nothing itself, so the press never moves
    // or redraws the toggle under the pointer (a click needs its press and release on one node).
    let pressed: FoldAnchor | undefined;
    let pressedAt: { x: number; y: number } | undefined;
    const notePressed = (event: PointerEvent) => {
      const toggle = event.button === 0 && node ? foldToggleAt(event.target, node) : undefined;
      pressedAt = toggle ? { x: event.clientX, y: event.clientY } : undefined;
      pressed = toggle ? holdFold(foldHoldTarget(toggle, node ?? undefined), undefined, toggle) : undefined;
    };
    const dropPressed = () => {
      pressed = undefined;
    };
    // A collapsible's header that asks to be held (useAnchoredCollapse.ts): a toggle from the keyboard
    // or a header that is no disclosure button, as well as the click above.
    const holdAsked = (event: Event) => {
      const header = event.target as HTMLElement | null;
      if (!node || typeof header?.closest !== "function" || !node.contains(header) || !header.closest(".acpmux-row"))
        return;
      event.preventDefault();
      // A line the reader opened that a new call's regroup moved in its row (KeepOpenedLine.tsx): held
      // where it was drawn before the regroup, while the row settles. Following the latest row, the
      // view stays on the latest row as before; a click's own hold already keeps its line.
      const regroup = (event as CustomEvent<unknown>).detail;
      if (isRegroupHold(regroup)) {
        if (followingRef.current || foldHolding(foldAnchor.current)) return;
        const hold = holdFold(header);
        hold.top = regroup.top;
        foldAnchor.current = hold;
        holdTop.current = node.scrollTop;
        return;
      }
      const sameClick = Boolean(clicked && clicked.closest(".acpmux-row") === header.closest(".acpmux-row"));
      const wasAtEnd = sameClick ? clickedAtEnd : atEnd();
      settleFold(header);
      const toggle = sameClick ? clicked! : header;
      const bottom = bottomStackFold.current?.toggle === header ? true : beginBottomStackFold(toggle, header, wasAtEnd);
      // The click that asked for it already holds this line at the place it was pressed at: keep it.
      if (!sameClick) declareFold(header);
      foldAnchor.current = clickFold(header, foldAnchor.current, undefined, toggle);
      holdTop.current = node.scrollTop;
      if (!bottom) keepFoldRoom();
    };
    // The reader scrolling lets go of it.
    const release = (event: Event) => {
      const key = (event as KeyboardEvent).key;
      if (key === "Enter" || key === " ") return;
      if (event.type === "wheel" && !verticalWheel(event as WheelEvent)) return;
      stopBottomStackFold();
      foldAnchor.current = undefined;
    };
    // Any input lands a fold ride first, before whatever it reaches reads the layout: rows go to
    // their places and the scroll range to its new end. Otherwise a wheel, the scrollbar, the map's
    // scrub (ScrollMap's `seek`, from `layout.totalHeight`), find or a jump would stop at, or aim
    // by, the range placed before the fold (review of #39917 at 184fed21 and e357b4a0: 1250px and
    // 800px short). A ride only plays mid-fold, so this is one render, only for input then.
    const landRide = () => foldRide.current?.land();
    const landingInputs = ["pointerdown", "wheel", "touchstart", "keydown"] as const;
    const view = node?.ownerDocument.defaultView;
    const releases = ["wheel", "touchstart", "keydown"] as const;
    node?.addEventListener("click", holdClicked, { capture: true });
    node?.addEventListener("pointerdown", notePressed, { capture: true });
    for (const name of landingInputs) view?.addEventListener(name, landRide, { capture: true, passive: true });
    node?.addEventListener("pointercancel", dropPressed, { capture: true });
    node?.addEventListener(ANCHORED_COLLAPSE_EVENT, holdAsked);
    for (const name of releases) node?.addEventListener(name, release, { passive: true });
    // The wheel over Jump to latest scrolls the transcript (wheelPassThrough.ts).
    // The chat's own transcript only (a replay's sits in its own screen).
    const main = node?.closest(".acpmux-stage")?.parentElement?.closest<HTMLElement>(".acpmux-main");
    const removeWheel = node && main ? installWheelPassThrough(node, main) : undefined;
    // A drag from the empty margins either side of the column selects text (gutterSelect.ts); the
    // view it scrolls past an edge is the reader's scroll.
    // A chat change ends any drag first (`gutterRelease`, below), so a hold is always this chat's.
    const gutter =
      node && thread.current
        ? installGutterSelect(
            node,
            thread.current,
            () => intent.mark(),
            (held) =>
              setHeldRows(
                held
                  ? {
                      session: heldSession.current,
                      rows: held.map((row) => ({
                        ...row,
                        fromEnd: rowsRef.current.length - row.index,
                      })),
                    }
                  : undefined,
              ),
            main,
          )
        : undefined;
    gutterRelease.current = gutter?.release;
    wheelGlide.current = node ? installWheelGlide(node) : undefined;
    return () => {
      wheelGlide.current?.remove();
      wheelGlide.current = undefined;
      stopJump();
      unsubscribeIntent();
      node.ownerDocument.removeEventListener("keydown", endKey);
      unsubscribeQuiet();
      detachIntent();
      removeMomentumHold();
      if (findFrame.current !== undefined) cancelAnimationFrame(findFrame.current);
      findFrame.current = undefined;
      ownerDocument.removeEventListener("pointerup", readerReleased, {
        capture: true,
      });
      ownerDocument.removeEventListener("pointercancel", readerReleased, {
        capture: true,
      });
      ownerDocument.removeEventListener("lostpointercapture", readerReleased, {
        capture: true,
      });
      ownerDocument.defaultView?.removeEventListener("blur", readerReleased);
      for (const name of canceledInputs) ownerDocument.removeEventListener(name, readerCanceled);
      node?.removeEventListener("click", holdClicked, { capture: true });
      node?.removeEventListener(ANCHORED_COLLAPSE_EVENT, holdAsked);
      node?.removeEventListener("pointerdown", notePressed, { capture: true });
      for (const name of landingInputs) view?.removeEventListener(name, landRide, { capture: true });
      node?.removeEventListener("pointercancel", dropPressed, {
        capture: true,
      });
      for (const name of releases) node?.removeEventListener(name, release);
      removeWheel?.();
      gutterRelease.current = undefined;
      gutter?.remove();
      stopLayoutWatch?.();
    };
  }, [dropFoldRoom, landForReader, startBottomStack, stopBottomStackFold, slimFollow, stopFollowMotion, stopJump]);
  // A turn's footer (TurnFooter) shows for the turn the reader points at: anywhere after its prompt
  // to its footer. Marked on the mounted rows, so a hover renders nothing.
  // The chat's one Retry (turns.ts retryTargetIn, retryPlacement): the reply footer of the person's
  // last prompt, or that prompt where the footer draws none. Its ids, not the scan's object, key the
  // context, so a streamed token redraws no prompt or footer.
  const scannedRetry = useMemo(() => retryTargetIn(rows), [rows]);
  const retryTarget = useMemo(
    () => ({
      promptId: scannedRetry.promptId,
      footerId: scannedRetry.footerId,
    }),
    [scannedRetry.promptId, scannedRetry.footerId],
  );
  const finalFooter = useMemo(() => finalFooterId(rows), [rows]);
  /// The row drawn with `data-turn-revealed`, while it is the pointed turn's mounted row: a commit that
  /// leaves it so (a streamed token, with the pointer anywhere or nowhere) costs one check, not a pass
  /// over every row in view (Leo, 2026-11-04: "never ... acceptable ... linear time growth degradation").
  const markedTurn = useRef<HTMLElement | null>(null);
  const markTurns = useCallback(() => {
    const id = pointedTurn.current;
    const marked = markedTurn.current;
    if (marked ? marked.isConnected && marked.dataset.rowId === id : id === undefined) return;
    marked?.removeAttribute("data-turn-revealed");
    markedTurn.current = null;
    const host = thread.current;
    if (id === undefined || !host) return;
    const name = typeof CSS === "undefined" ? id.replace(/["\\]/g, "\\$&") : CSS.escape(id);
    const row = host.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${name}"]`);
    row?.setAttribute("data-turn-revealed", "");
    markedTurn.current = row;
  }, []);
  // Mark only when the mounted rows, their range, or the last turn changes. The old no-deps
  // layout effect scanned every commit, including scroll/follow state commits that cannot change
  // these attributes. `pointAt` still calls the callback directly for pointer-driven updates.
  useLayoutEffect(markTurns, [markTurns, rows, range.first, range.last]);
  // Older history pages in before the reader reaches it: whenever the view is within six viewports
  // of the first loaded row, including a tail too short to fill them. The anchoring above keeps the
  // reader's row in place as each page lands.
  // A read that drew no row above the first (records that draw nothing) moves historyFrom: ask again.
  const olderLoadKey = `${sessionKey}\u0000${rows[0]?.id ?? ""}\u0000${historyFrom ?? ""}`;
  const olderLoadRequested = useRef<string | undefined>(undefined);
  /// An older page asked for has not settled yet; and the check that follows one that brought nothing.
  const olderAsking = useRef(false);
  const olderRecheck = useRef<ReturnType<typeof setTimeout>>(undefined);
  /// The latest ask: only its settling re-arms the check, so a late answer to an earlier one (a
  /// chat switched away from) cannot cancel the recheck of the ask that followed it.
  const olderAsk = useRef(0);
  // The check reads the scroller's live offset, and runs on every scroll event as well as after
  // each commit: a page that lands moves the view down (the anchoring above) and the reader's
  // scroll back to the top could land in the same frame, so the rendered offset never changed
  // and a check that ran only on a change of it never asked for the next page (the scroll to the
  // first message stalled at the top after a few pages, perf100).
  const keptFrom = useRef<string | null | undefined>(undefined);
  /// Tells the client the oldest row in view while the view follows (null once it does not): a chat streaming under
  /// load sheds its oldest records only below it, so what it keeps still fills the view and no older page is read
  /// back at the latest row. Runs where `checkOlder` does (each scroll event and commit); says only a change.
  const keepFromInView = (node: HTMLElement | null) => {
    if (!onKeepFrom) return;
    // With when it begins: a fold, date line or header is a row the client holds under no id of its own.
    const row =
      node && followingRef.current && node.clientHeight > 0
        ? rows[visibleLayoutRange(layout, layoutScrollTop(node), 0, 0).first]
        : undefined;
    const id = row?.id ?? null;
    if (id === keptFrom.current) return;
    keptFrom.current = id;
    onKeepFrom(id, row?.at);
  };
  const checkOlder = () => {
    const node = ref.current;
    keepFromInView(node);
    if (!canLoadOlder || !onLoadOlder || !node || node.clientHeight === 0) {
      clearTimeout(olderRecheck.current);
      olderRecheck.current = undefined;
      olderAsk.current++;
      olderAsking.current = false;
      olderLoadRequested.current = undefined;
      return;
    }
    // Measured from the loaded rows' top, under the room held for the history above them.
    const ahead = olderAhead.ahead(node.clientHeight * OLDER_AHEAD_VIEWPORTS, node.clientHeight, performance.now());
    // A chat that shed older records while the view follows declines the read (direct.ts `loadOlder`); a chat opened
    // at its latest row still reads ahead here until its history fills `OLDER_AHEAD_VIEWPORTS` above the view.
    if (node.scrollTop - (layout.origin ?? 0) >= ahead) {
      // Allow the next visit to the threshold to request the next page, even when the first row
      // did not change while the reader was away from the top.
      olderLoadRequested.current = undefined;
      return;
    }
    if (olderLoadRequested.current === olderLoadKey) return;
    const asked = olderLoadKey;
    olderLoadRequested.current = asked;
    olderAsking.current = true;
    const ask = ++olderAsk.current;
    const askedAt = performance.now();
    window.__cmuxOlderTrace?.("ask", askedAt, ask);
    // A page that lands changes the key in the commit it brings, and the check after it asks for
    // the next. An ask that brought nothing (a read that failed, or one the client dropped) leaves
    // the key as it was: ask once more a moment later, as long as the view is still near the top.
    // At the very top no scroll event comes to ask for it, and a check on every render would ask
    // on every streamed chunk (Leo 2026-10-21: a 720-turn chat stopped paging for good).
    const settled = () => {
      window.__cmuxOlderTrace?.("settled", performance.now(), ask);
      if (ask !== olderAsk.current) return;
      olderAsking.current = false;
      clearTimeout(olderRecheck.current);
      olderRecheck.current = setTimeout(() => {
        if (olderLoadRequested.current !== asked) return;
        olderLoadRequested.current = undefined;
        checkOlderNow.current();
      }, OLDER_RECHECK_MS);
    };
    // Rows that do not reach the view's top leave a blank band above them until the page lands
    // (Leo's NIGHTLY, 2026-11-12: the top ~40% empty above "Received 3 messages").
    onLoadOlder(node.scrollHeight - (layout.origin ?? 0) <= node.clientHeight, olderAhead.rising(askedAt)).then(() => {
      if (ask === olderAsk.current) olderAhead.read(performance.now() - askedAt);
      settled();
    }, settled);
  };
  useLayoutEffect(() => {
    checkOlderNow.current = checkOlder;
  });
  useLayoutEffect(() => {
    olderScrollTarget.current = undefined;
  }, [sessionId]);
  useLayoutEffect(() => {
    const node = ref.current;
    const target = olderScrollTarget.current;
    if (!node || target === undefined) return;
    if (holdOlderScrollTarget(node, target, latestLayout.current.layout.origin ?? 0))
      olderScrollTarget.current = undefined;
  }, [height, layout.origin, olderLoadKey, renderScroll.top]);
  useEffect(() => {
    checkOlderNow.current();
  }, [canLoadOlder, height, onLoadOlder, olderLoadKey, renderScroll.top]);
  useEffect(() => () => clearTimeout(olderRecheck.current), []);
  // Newer history a reader scrolled far up let go of (canLoadNewer) pages back in as the view nears the rows' end,
  // as older history does at their top: within OLDER_AHEAD_VIEWPORTS of it, once per page (`newerLoadKey`), and
  // asked again a moment after an ask that brought nothing.
  const newerLoadKey = `${sessionKey}\u0000${rows.at(-1)?.id ?? ""}\u0000${historyThrough ?? ""}`;
  const newerLoadRequested = useRef<string | undefined>(undefined);
  const newerRecheck = useRef<ReturnType<typeof setTimeout>>(undefined);
  const checkNewer = () => {
    const node = ref.current;
    if (!canLoadNewer || !onLoadNewer || !node || node.clientHeight === 0) {
      newerLoadRequested.current = undefined;
      return;
    }
    // The rows' end, under the room the newer history left (conversation/newerReserve.ts).
    const rowsEnd = measured.layout.totalHeight + THREAD_TOP + topInset;
    if (rowsEnd - (layoutScrollTop(node) + node.clientHeight) >= node.clientHeight * OLDER_AHEAD_VIEWPORTS) {
      newerLoadRequested.current = undefined;
      return;
    }
    if (newerLoadRequested.current === newerLoadKey) return;
    const asked = newerLoadKey;
    newerLoadRequested.current = asked;
    const settled = () => {
      clearTimeout(newerRecheck.current);
      newerRecheck.current = setTimeout(() => {
        if (newerLoadRequested.current !== asked) return;
        newerLoadRequested.current = undefined;
        checkNewerNow.current();
      }, OLDER_RECHECK_MS);
    };
    onLoadNewer().then(settled, settled);
  };
  useLayoutEffect(() => {
    checkNewerNow.current = checkNewer;
  });
  useEffect(() => {
    checkNewerNow.current();
  }, [canLoadNewer, height, onLoadNewer, newerLoadKey, renderScroll.top]);
  useEffect(() => () => clearTimeout(newerRecheck.current), []);
  // The view went to the latest message (the reader scrolled to the end, a send) while the rows end in history: the
  // pane reads the chat's newest page in place of the window (direct.ts `returnToLatest`).
  useEffect(() => {
    if (following && canLoadNewer) void onReturnToLatest?.();
  }, [following, canLoadNewer, onReturnToLatest]);
  // A Jump to latest pressed while the rows end in history waits for the newest page, then goes there.
  useEffect(() => {
    const pending = latestAfterReturn.current;
    if (canLoadNewer || !pending) return;
    latestAfterReturn.current = undefined;
    jumpToLatestRef.current(pending.focused, pending.path);
  }, [canLoadNewer]);
  useEffect(() => {
    olderAhead.reset();
  }, [olderAhead, sessionKey]);
  // A wheel up with the view already at the loaded rows' top moves nothing, so no scroll event says the reader
  // wants more: it asks itself, unless an ask is still out.
  const onWheel = (event: React.WheelEvent<HTMLDivElement>) => {
    // Its default moves the offset before the frame paints (in a frame callback, as a synthetic wheel's
    // is applied): the frame guard reads it this frame.
    armFrameGuard();
    // Held at the loaded rows' top, a wheel up moves nothing: the reader is still scrolling up (`rising`).
    if (event.deltaY < 0) olderAhead.wheeledUp(performance.now(), event.deltaMode === 0 ? -event.deltaY : 0);
    const loadedTop = layout.origin ?? 0;
    if (event.deltaY >= 0 || olderAsking.current) return;
    // A fling's first wheel asks as far ahead as its step reaches while a page is read (OlderAhead), a
    // frame before its scroll event would.
    if (layoutScrollTop(event.currentTarget) > loadedTop + 0.5) {
      checkOlderNow.current();
      return;
    }
    olderLoadRequested.current = undefined;
    checkOlderNow.current();
  };
  const pointAt = (target: EventTarget | null) => {
    const row = target instanceof Element ? target.closest<HTMLElement>(".acpmux-row") : null;
    const rowId = row?.dataset.rowId;
    if (rowId === pointedRow.current && rows === pointedRows.current) return;
    pointedRow.current = rowId;
    pointedRows.current = rows;
    const from = row ? Number(row.getAttribute("aria-posinset")) - 1 : -1;
    // A prompt shows its own row, never its turn's too: one action row at a time.
    const footer = from >= 0 && rows[from]!.kind !== "user" ? turnFooterFrom(rows, from) : undefined;
    if (footer === pointedTurn.current) return;
    pointedTurn.current = footer;
    markTurns();
  };
  // Jump to latest remains shown once the reader is far behind, avoiding flicker near the threshold.
  const below = layout.totalHeight - height - (renderScroll.top - origin);
  // A fold the reader closed at the very bottom keeps the view at its end on each of its frames
  // (`beginBottomStackFold`; an open there grows down and stops following): a render mid-fold that
  // lays out ahead of that pin (a call that joins the group) is not the reader falling behind, and
  // never brings the arrow up (Leo, 2026-11-06: "way too discontinuous", the arrow came up mid-fold
  // under load).
  if (renderFollowing || below <= FOLLOW_BOTTOM_DEADBAND_PX) jumpShown.current = false;
  else if (below > JUMP_LATEST_DISTANCE && !bottomStackFold.current) jumpShown.current = true;
  const behind = jumpShown.current;
  // Jump up (jumpUp.ts): where the reader left off, while it is off screen. The unread "New" line
  // first while it is unread, else the mark their idle stretch pinned once a screen of new content
  // came in below it. Layout and rows only measure it; nothing here but the reader's acts moves it.
  const unreadView = useSyncExternalStore(
    jumpUpOn ? subscribeUnread : NO_SUBSCRIPTION,
    jumpUpOn ? readUnread : NO_UNREAD,
    jumpUpOn ? readUnread : NO_UNREAD,
  );
  const sinceIndex = sinceKey !== undefined ? indexOfRow(rows, SINCE_DIVIDER, sinceHint) : -1;
  const sinceRow = sinceIndex >= 0 ? rows[sinceIndex] : undefined;
  // Whether anything new to read is under the line (sinceNews.ts): a quiet one draws no line, no
  // banner and no Jump up target. Stops at the first news row, so a chat that answered reads one.
  const sinceHasNews = sinceRow !== undefined && sinceNews(rows, sinceIndex);
  useLayoutEffect(() => {
    if (sinceKey !== undefined && sinceRow !== undefined) noteUnreadNews(sinceKey, sinceHasNews);
  }, [sinceKey, sinceRow, sinceHasNews]);
  const jumpUp = jumpButton && jumpUpOn;
  const ownPrompt = jumpUp ? lastOwnPrompt(rows, promptScan, promptAuthor) : undefined;
  // The stretch's place row is read each render: its hint keeps the lookup O(1) while rows append.
  const idleNow = idle.settle({
    topOf: (place) => {
      const index = indexOfRow(rows, place.rowId, idle.hint);
      return index >= 0 ? layout.geometry.topAt(index) + place.offset : undefined;
    },
    rows,
    heightAt: (index) => layout.geometry.heightAt(index),
    indexOf: (place) => indexOfRow(rows, place.rowId, idle.hint),
    totalHeight: layout.totalHeight,
    viewHeight: height,
    lastPrompt: ownPrompt?.id,
  });
  const upTarget = jumpUp
    ? jumpUpTarget(sinceRow && unreadPending(sinceKey, unreadView) ? SINCE_DIVIDER : undefined, idleNow.mark)
    : undefined;
  // The stretch's place and mark are kept for the chat's next load (a reload, an update, a restart),
  // written when they change, after a hand scroll's steps settle (IdleTracker.keepSoon), and at once
  // when the pane goes.
  useEffect(() => idle.keepSoon());
  useEffect(() => () => idle.keepNow(), [idle]);
  const upIndex = upTarget ? indexOfRow(rows, upTarget.rowId, jumpUpHint) : -1;
  const upTop = upIndex >= 0 ? layout.geometry.topAt(upIndex) + (upTarget?.offset ?? 0) : undefined;
  const upOff = placeOffView(upTop, {
    shownTop,
    height,
    threadTop: THREAD_TOP,
    topInset,
    dockSpace,
  });
  // One control at a time: while Jump to latest shows, Jump up waits (Leo, 2026-11-12: the two
  // stacked are "a bit extra"). A held way back is still Esc's, and Jump to latest goes there too.
  const latestShown = jumpButton && (behind || (needsYou?.elsewhere ?? 0) > 0);
  const upShown = jumpUp && !latestShown && jumpUpShown(upOff, jumpBackHeld);
  // What a press reads (`pressUp`), as of the last commit.
  const upTopRef = useRef({ top: upTop, place: upTarget });
  useLayoutEffect(() => {
    upTopRef.current = { top: upTop, place: upTarget };
  });
  // The button's own `shown` (JumpToLatest below), reported once per change so the pane's toast deck
  // moves in the same frame the button starts to fade in or out.
  const jumpVisible = latestShown;
  const jumpShownReport = useRef(onJumpShownChange);
  useLayoutEffect(() => {
    jumpShownReport.current = onJumpShownChange;
  });
  useLayoutEffect(() => {
    jumpShownReport.current?.(jumpVisible);
  }, [jumpVisible]);
  useLayoutEffect(() => () => jumpShownReport.current?.(false), []);
  // CHAT SWITCH PLAY: the last layout effect, so the new chat's rows are placed and scrolled to where
  // they will be drawn when the play picks the visible ones (CHAT SWITCH MOTION above).
  useLayoutEffect(() => {
    if (!switchPending.current || !hasRows) return;
    switchPending.current = false;
    switchPlay.current = playChatSwitch(ref.current, switchArm, switchPlay.current);
  }, [sessionId, hasRows, switchArm]);
  // The prompt rail's own box: the view's height, less the bottom stack at its smallest at this
  // height (the composer at rest). A composer that grows a line, a tray or bar that opens over the
  // view, or the lift a followed view takes leaves the rail where it is; a new view height, another
  // chat or another stack starts over.
  // Another stack's first measure comes in the layout effect after this render (`dockSpace` still
  // holds the old one's here), so it starts from none and takes that measure.
  const restingSpace = useRestingDock(height, sessionId, dock, dockSpace);
  // A stack not measured since it came (the latch's 0) reads as it is now.
  // Below a floating tab row (`topInset`): the rail centers in the view the row leaves (threadMinimap.css).
  // `live` is the stack's top now: the rail's foot and its card stay above it (ThreadMinimap `railBox`).
  const railBox = {
    height: height - topInset,
    foot: height - topInset - (restingSpace || dockSpace),
    live: height - topInset - dockSpace,
  };
  // Each mounted row's frame, its props worked out again only for rows whose rows or inputs changed
  // (`drawRowFrames`): a streamed token redoes the live row's alone.
  /// `aria-setsize` on the mounted rows, written to the nodes instead of passed to each one. It is a
  /// whole-list number (`rows.length`, or -1 while older history can still be paged in), so a row
  /// that arrived changed it for every mounted row at once and React redrew them all: at 1,500 rows
  /// while a reply streamed, `rowprop:setSize` was the first differing prop in 34 of the p95 frame's
  /// 41 row renders (composer-typing.bench.ts, cmux#45237). A row that arrives must cost its own
  /// draw, not the mounted window's. A screen reader reads the attribute. The row writes it on its
  /// own mount, from this ref; a changed length is swept below.
  const setSize = String(canLoadOlder ? -1 : rows.length);
  // The ref is written by the sweep below, never in a render: a render that React throws away must
  // leave nothing behind. A row's own mount effect runs before the sweep, so it reads the length as
  // of the last commit; when this commit changed it, the sweep that follows writes every row anyway.
  const setSizeRef = useRef(setSize);
  const rowFrames = drawRowFrames(rowFrameCache, rowFrameSources, {
    rows,
    mountedRanges,
    geometry: layout.geometry,
    frameKey,
    registry,
    setSizeRef,
    rowWidth: scaledRowWidth,
    expanded,
    observer,
    queueDrawn,
    sentPromptIds: sentPromptIdsForRender,
    // A session switch is a load, not a live arrival. The reset effect runs after this render, so
    // gate it here as well to avoid a reused row id animating once.
    enters: !sessionChanged || tookSession,
    onEntered,
    loadFades: !sessionChanged,
    onLoadFaded,
    onOlderShown,
    activeRowId: effectiveActiveRowId,
    selectedRows,
    tabStopId,
    finalFooter,
    onFocus: rowFocus,
    onRowKeyDown: handleRowKeyDown,
    onToggleActivity: toggleRow,
    onOpenDiff,
    streams,
    sessionId,
    githubRepository,
    rowRepositories,
    scopeAt,
  });
  /// Only a changed length sweeps the mounted rows. A streamed token leaves the length alone, so it
  /// reads no mounted row: a pass over the thread's rows is what `test/transcript-fold-anchor.test.tsx`
  /// counts, and a token during a fold must run none. `[data-row-id]` keeps the write off a fold's
  /// ghost copies, which hang in the thread with the row class and have this attribute stripped on
  /// purpose (conversation/turnFold.ts `ghostOf`): an inert copy must not read as a row of the list.
  useLayoutEffect(() => {
    setSizeRef.current = setSize;
    const threadNode = thread.current;
    if (!threadNode) return;
    for (const node of threadNode.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]"))
      if (node.getAttribute("aria-setsize") !== setSize) node.setAttribute("aria-setsize", setSize);
  }, [setSize]);
  // One identity for the pane's life: a wheel tick re-renders the transcript to draw the rows coming into view,
  // and a new handler each time drew the Jump to latest control again with it (render-counts.bench.ts `scroll`).
  const onJumpLatest = useStableCallback((focused: boolean) => {
    // One press, one move: to the latest message when this chat's ask waits there (or no
    // ask is open), else straight to the next chat's ask.
    // With no ask open it is Jump to latest, whatever the last render read for `behind`.
    const asks = needsYou?.count ?? 0;
    const here = asks - (needsYou?.elsewhere ?? 0);
    const scroll = asks === 0 || (behind && here > 0);
    if (scroll) jumpToLatest(focused);
    if (needsYou && asks > 0) needsYou.next(scroll);
  });
  if (renderStart > 0) acpmuxPerf.span("vt.body", performance.now() - renderStart);
  return drawTranscriptShell({
    readOnly,
    retryTarget,
    livePulse,
    ref,
    slimFollow,
    onAnchor,
    t,
    onScroll,
    onWheel,
    renderScroll,
    origin,
    renderFollowing,
    below,
    jumpButton,
    behind,
    dockSpace,
    pinnedPill,
    dockHoles,
    pinAt,
    topInset,
    showMinimap,
    rows,
    layout,
    height,
    rowsChange,
    earlier,
    canLoadNewer,
    canLoadOlder,
    loading,
    later,
    promptCount,
    loadThrough,
    loadPromptIndex,
    sessionId,
    room,
    railBox,
    paneWidth,
    width,
    minimapPlaced,
    endReserve,
    find,
    countReveal,
    findReveal,
    lane,
    lift,
    standIns,
    frameKey,
    thread,
    pointAt,
    rowFrames,
    afterLatest,
    dockHeight,
    sinceKey,
    onJumpToSince,
    sinceRow,
    clearTop,
    sinceIndex,
    jumpUp,
    upShown,
    jumpBackHeld,
    pressUp,
    working,
    onJumpLatest,
    needsYou,
  });
}

const TranscriptViewMemo = React.memo(TranscriptView);
