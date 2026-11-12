import { MARK_INDICATOR, MARK_PROMPT, rowMark, TRANSCRIPT_COMPOSER_GAP } from "./transcriptGrid";
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
} from "react";
import { flushSync } from "react-dom";
import { rowPresence, type RowPresenceHints } from "./conversation/rowPresence";
import { LayeredMap } from "./conversation/layeredMap";
import { isAgentMotionOff } from "../shared/motion";
import { LOAD_FADE_CLASS, LoadFadeWindow } from "../shared/loadFade";
import { entranceAllowed } from "../shared/pageReveal";
import { holdEntranceForFirstFrame } from "./conversation/entranceClock";
import {
  layoutConversation,
  type ConversationLayout,
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
  isBeforeFooter,
  finalFooterId,
  hasReplyActions,
  keepsReplyRoom,
  statusEdge,
  type StatusEdge,
  isLastFooter,
  isLiveLine,
  isContinuationFooter,
  isLineRow,
  isLiveStep,
  opensBackgroundTurn,
  restRoom,
  rowFrameKey,
  SINCE_DIVIDER,
} from "./model";
import { ThreadMinimap } from "./threadMinimap/ThreadMinimap";
import { railOwnsWheel } from "./threadMinimap/railWheel";
import { animateScroll, MOTION_SCROLL_EVENT, stopScroll } from "./threadMinimap/scrollMotion";
import { JUMP_CURVE, jumpDuration, jumpGlideStart, transcriptFadeReach } from "./threadMinimap/model";
import { cssTimeMs, foldMotion, foldMs } from "./conversation/fold";
import { ChatMinimap } from "./chatMinimap/ChatMinimap";
import { minimapReserve } from "./chatMinimap/paint";
import type { RowsChange } from "./threadMinimap/model";
import { PromptMarksSession } from "./threadMinimap/promptMarks";
import { fadesBelow, preserveScrollAnchorTop, scrollAnchorBase } from "./conversation/scrollAnchor";
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
import { createTailGlide, type TailGlide } from "./conversation/tailGlide";
import { finishCarry, notePinPass, pinLiveLine, refreshPinned } from "./conversation/pinnedLiveLine";
import { ARRIVAL_EASE, arrivalStepMs, createFollowChase, type FollowChase } from "./conversation/followChase";
import { followMotion } from "./conversation/followMotion.experiment";
import { composerDockMotion } from "./composer/dockMotion.experiment";
import { acpmuxPerf, type MountedSpan } from "./perf";
import { useCountedRender } from "./perfRender";
import { drewStreamingRow, useStreamingRow } from "./streamingRow";
import { rowsWithLiveOutput, useLiveToolRow } from "./liveToolOutput";
import { followTrace } from "./followTrace";
import { FIELD_GROWTH_EVENT, growthTranslate, type FieldGrowthEvent } from "./composer/fieldGrowthEvent";
import { ScrollPacing } from "./pacing";
import { AdaptiveRenderRate, reportScrollPacing } from "./renderPacing";
import { noteTranscriptMount } from "./flickerLog";
import { authoritativeScrollIntent, createScrollPacer, type ScrollFrame } from "./scrollPacer";
import { type Translate, useT } from "./i18n";
import { TRAY_GHOST } from "./subagents/trayMotionModel";
import { noteReaderScroll } from "./summary/heldWhileScrolling";
import { FisheyeFilters } from "../../ui/glass/Fisheye";
import { keepTabOnScreen, leaveOnScreenRef } from "../../ui/tabReach";
import {
  transcriptRepositoriesFrom,
  type RepositoryCache,
  type RepositoryReading,
} from "./conversation/transcriptRepositories";
import {
  newReferenceScopeCache,
  ReferenceScopeContext,
  referenceScopes,
  turnOpener,
  type ReferenceScope,
  type ReferenceScopeCache,
} from "./conversation/bareReferences";
import { stopReadingAloud } from "./conversation/readAloud";
import { heightFoldInFlight, heightFoldPlaying, settleFoldsIn } from "./conversation/fold";
import { FoldRide } from "./conversation/foldRide";
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
  notePlacement,
  pushUpCut,
  trimmedFoldRoom,
  verticalWheel,
  type FoldAnchor,
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
import { BACKGROUND_TURN } from "./conversation/backgroundTurns";
import { installGutterSelect, type HeldRow } from "./conversation/gutterSelect";
import { isEditRow } from "./turnChanges/sessionRows";
import { RetryTargetContext } from "./conversation/turnActions";
import { GuestActionsBoundary } from "./conversation/GuestActionsBoundary";
import {
  clearFindHighlights,
  FIND_ACTIVE_HIGHLIGHT,
  FindReveal,
  foldFind,
  findRowIndex,
  findMemberRowId,
  paintFindHighlights,
  type ChatFind,
} from "./conversation/chatFind";
import { ChatFindBar } from "./conversation/ChatFindBar";
import { LIVE_THINKING, THINKING, WORKED, foldCovers, turnFooterFrom, retryTargetIn } from "./conversation/turns";
import { ArrowDown } from "./conversation/icons";
import { Slot } from "../../slots/Slot";
import { jumpToBottomSlot } from "../../slots/jumpToBottom";
import { installWheelGlide } from "./wheelGlide";
import { installDockWheelHold, installWheelPassThrough } from "./wheelPassThrough";
import { NeedsYouPill, type TranscriptNeedsYou } from "./needsYou/JumpPill";
import { copyTextResult } from "./conversation/clipboard";
import { transcriptRangeText } from "./conversation/transcriptCopy";
import { rovingTabStopProps } from "../../ui/listRowKeyboard";
import { chatColumnOf, useChatSizing } from "./chatWidth";
import { useChatDisplay } from "./chatDisplay";
import { useComposerSettings } from "./composerSettings";
import { type Folds } from "./conversation/viewFolds";
import { SUBAGENT_DONE, SUBAGENT_OF } from "./subagents/subagentRows";
import { SubagentOfRow } from "./subagents/SubagentGroup";
import { SUBAGENT_OF_HEIGHT } from "./rows/SubagentOfPillRow";
import { noteSendFromLatest, playSendMorph } from "./conversation/sendMorph";
import { UnreadBanner, sinceDone } from "./conversation/SinceDivider";
import { readUnread, subscribeUnread, unreadPending } from "./conversation/unreadState";
import {
  jumpUpShown,
  jumpUpTarget,
  lastOwnPrompt,
  placeOffView,
  pressJumpUp,
  type JumpBack,
  type ManualMark,
  type PromptScan,
} from "./jumpUp";
import { topZoneOffset } from "./overlayLayout";
import "./jumpPair.css";
import { experimentArm } from "../../experiments/experiment";
import { jumpPairLook } from "./jumpPair.experiment";
import { MOTION_MS, MOTION_SEND_CURVE, MOTION_SEND_MS } from "../../motion/scale.generated";
import { SHOWN_SCROLLER_ATTRIBUTE, followShownScrollerFade } from "../../scrollers";
import { editableTarget, wheelScrollsDown } from "./conversation/wheelChain";
import { type OlderReserve, olderReserve } from "./conversation/olderReserve";
import { hasPromptTops, keepPromptTops, knownPromptTop } from "./conversation/transcriptHeights";
import { holdWebSwap, WEB_SWAP_KEPT_SCROLL } from "../../pages/shared/webSwap";
import { playChatSwitch, type ChatSwitchPlay } from "./chatSwitch";
import { chatSwitchMotion } from "./chatSwitch.experiment";
import { callNative } from "./callNative";
import { StreamReveal } from "./streamReveal";
import { type NativeRegistry, type OpenDiff, type RowProps } from "./rows/rowProps";
import { NoticeRow } from "./rows/NoticeRow";
import { defaultRegistry, readOnlyRegistry } from "./rows/registry";
import {
  NO_ROWS,
  sameReferenceScope,
  sameRowFrame,
  rowKind,
  FOLLOW_BOTTOM_DEADBAND_PX,
  SCROLL_ANCHOR_SETTLE_MS,
} from "./virtualTranscriptModel";

/// The last measured transcript box on this page: a transcript mounting again starts from it.
const lastTranscriptBox = { height: 600, width: 760 };

/// A row's height as the page drew it at a width. It places the row until its next version is drawn.
/// `actions`: whether a reply kept its action row's room then (model.ts `keepsReplyRoom`); a drawn
/// height taken without it, or with it, is stale once the row after the reply changes that.
type DrawnHeight = {
  sessionId?: string;
  version: number;
  width: number;
  height: number;
  actions?: boolean;
  /// model.ts `statusEdge` when it was drawn: the room under the row depends on it.
  status?: string;
};

/// `height` is undefined for a row the page has not laid out (drawnHeightOf).
type ReportDrawn = (
  id: string,
  version: number,
  height: number | undefined,
  actions?: boolean,
  status?: string,
) => void;

/// Enqueues a row's pre-paint measurement after all sibling content layout effects have written.
type QueueDrawn = (node: HTMLElement, id: string, version: number, actions?: boolean, status?: string) => () => void;

/// A mounted row's drawn height, or undefined when the page has not laid it out (an undisplayed
/// transcript, or a DOM without layout): such a box has no client rects. A laid-out row that draws
/// nothing (a step of only quiet thoughts, a render update that joined an earlier card, a payload
/// that never came) is 0 high, and is placed at 0. Dropping that 0 as "not laid out" kept the row's
/// estimate, 26px for each of its items, as blank space in the transcript (Leo, 2026-10-21: a
/// screen-tall gap under "Worked for" and under an opened fold's last command).
function drawnHeightOf(node: HTMLElement): number | undefined {
  const height = node.getBoundingClientRect().height;
  return height > 0 || node.getClientRects().length > 0 ? height : undefined;
}

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
    old.status === entry.status
  );
}

/// Each drawn row's height by id (conversation/layeredMap.ts).
type DrawnHeights = LayeredMap<DrawnHeight>;

/// Whether `updates` change any drawn height in `current`.
function changesDrawn(current: DrawnHeights, updates: Map<string, DrawnHeight>): boolean {
  for (const [id, entry] of updates) if (!sameDrawn(current.get(id), entry)) return true;
  return false;
}

/// What a row's content draws from (the registry component's props, and the component).
/// `liveTools`: the pane's live transcript, whose rows draw a running command's newer output ahead
/// of the pane's snapshot (liveToolOutput.ts).
type RowContentProps = { Component: React.ComponentType<RowProps>; liveTools?: boolean } & RowProps;

/// A row's content, drawn again only when what it draws from changes: never for its frame's place
/// (`top`, `index`, `gapBelow`), focus (`tabStop`, `active`, `selected`) or entrance flags. A scroll
/// moves every mounted frame each time a row above is measured or an older page lands, and the
/// roving tab stop follows the first row in view; with the content drawn inside the frame, each such
/// change drew every mounted row's whole content again (Leo, 2026-11-06: "Still seeing the flicker
/// re-render. Sometimes when I scroll up").
///
/// The row is compared by object, not by `sameRowDraw`: a renderer may draw from fields its row's
/// version does not cover (ActivityLineRow's `doingSendTo`), and only its own comparator knows
/// which. A new row object reaches the renderer, whose memo decides; a history row keeps its object
/// across snapshots, so a scroll still draws none of them again.
export const RowContent = React.memo(
  function RowContent({ Component, liveTools = false, ...props }: RowContentProps) {
    // Counted when committed: a render React set aside (an interrupted concurrent pass) drew nothing.
    useLayoutEffect(() => {
      if (acpmuxPerf.enabled) acpmuxPerf.render(`content:${props.row.id}`);
    });
    // A running command's output that moved on without the pane: this row alone draws it.
    const row = useLiveToolRow(props.row, liveTools);
    return <Component {...props} row={row} />;
  },
  (previous, next) => {
    const keys = Object.keys(next) as (keyof RowContentProps)[];
    if (keys.length !== Object.keys(previous).length) return false;
    return keys.every((key) => Object.is(previous[key], next[key]));
  },
);

/// One transcript row. It reports its drawn height before the frame paints whenever it mounts or
/// its content, width or expansion changes; the transcript's ResizeObserver reports later changes
/// (a font that loads, a custom renderer that grows).
const RowFrame = React.memo(function RowFrame({
  row,
  kind,
  joinsPrevious,
  joinsNext,
  opensTurn,
  beforeFooter,
  beforeIndicator,
  replyActions,
  status,
  lastFooter,
  finalFooter,
  continuationFooter,
  lastTurn,
  index,
  setSize,
  top,
  rowWidth,
  expanded,
  observer,
  queueDrawn,
  enter,
  onEntered,
  loadFade,
  onLoadFaded,
  older,
  onOlderShown,
  active,
  selected,
  tabStop,
  onFocus,
  onRowKeyDown,
  referenceScope,
  gapBelow,
  children,
}: {
  row: AcpmuxRow;
  kind: string;
  /// The placed gap under the row (grid.md 5.5: the stack owns it, the row has no padding): the row's
  /// gap target spans it, so a drag from between two rows starts a selection.
  gapBelow: number;
  /// A step row (tool calls, thoughts, a background task's end) after another: no gap above it.
  joinsPrevious: boolean;
  /// A step row before another: no gap below it, so steps keep one 26px rhythm across rows.
  joinsNext: boolean;
  /// The first row of a turn the agent ran on its own, drawn as its own turn (model.ts
  /// `opensBackgroundTurn`): the turn gap over it is the stack's (MARK_OPENS_TURN); the row says so
  /// as `data-opens-turn`, the turn's boundary, so nothing reads it as the row above's tail.
  opensTurn: boolean;
  /// A reply right over its turn's footer: the footer hugs it (`--cv-meta-gap`), as a meta row.
  beforeFooter: boolean;
  /// A prompt right over the live line (transcriptGrid.ts waiting rule): the gap under it is the block
  /// gap, not the turn gap, so its action row is laid centred in that (conversation.css).
  beforeIndicator: boolean;
  /// Whether the row (a reply) keeps its action row's room (model.ts `keepsReplyRoom`): its height
  /// depends on it, so the frame redraws and measures again when it changes.
  replyActions: boolean;
  /// Next to a status row (model.ts `statusEdge`): the room between the row and the next one is the
  /// status gap, so a status line between two replies sits in the middle of it.
  status: StatusEdge | undefined;
  /// The chat's last footer: it ends at the message gap, so no band sits over the composer.
  lastFooter: boolean;
  /// The footer that ends the chat (nothing drawn after it): its turn has ended, so its Copy row
  /// shows without a hover (Leo, 2026-11-02: "i should be able to see the copy buttons on your
  /// responses when your things end").
  finalFooter: boolean;
  /// The next drawn turn belongs to this same assistant: half the normal turn gap.
  continuationFooter: boolean;
  /// The final row of a latest turn without a footer: preserve the normal turn gap at the composer.
  lastTurn: boolean;
  index: number;
  setSize: number;
  top: number;
  rowWidth: number;
  expanded: boolean;
  observer: ResizeObserver | undefined;
  queueDrawn: QueueDrawn;
  /// The row arrived live: it enters with the shared motion on this, its first mount.
  enter: boolean;
  onEntered: (id: string) => void;
  /// The row arrived while the chat loaded and mounts now, its first time: it fades in once.
  loadFade: boolean;
  onLoadFaded: (id: string) => void;
  /// The row came in on a late page of older history and has never mounted: its first copy fades once.
  older: OlderRowFade | undefined;
  onOlderShown: (id: string) => void;
  active: boolean;
  selected: boolean;
  tabStop: boolean;
  onFocus: (id: string) => void;
  onRowKeyDown: (index: number, event: React.KeyboardEvent<HTMLElement>) => void;
  /// What the child row draws from, compared instead of `children` (a new element every render).
  contentType: unknown;
  controls?: string;
  onToggleActivity: (id: string) => void;
  onOpenDiff?: OpenDiff;
  githubRepository?: string;
  /// Which repository the row's bare `#N` names (conversation/bareReferences.ts).
  referenceScope?: ReferenceScope;
  children: React.ReactNode;
}) {
  acpmuxPerf.span("row.renders", 1);
  if (acpmuxPerf.enabled) acpmuxPerf.render(`row:${row.id}`);
  const t = useT();
  const ref = useRef<HTMLElement>(null);
  const [entering] = useState(enter);
  // Prompts and replies get the message-specific entrance. Tool/status rows keep the existing
  // generic rise, while the row's reserved height and absolute placement stay unchanged.
  // Hidden user rows render no content and keep the empty-row geometry. Notice rows are user-kind
  // status lines whose `.cv-tools` strip row CSS targets as the article's direct child, so they keep
  // the generic entrance too. Only real prompts and replies get the presentation wrapper.
  const messageEntering =
    entering &&
    (row.kind === "assistant" ||
      (row.kind === "user" && row.incoming?.kind !== "hidden" && row.incoming?.kind !== "notice"));
  const [olderFade] = useState(older);
  const [loadFading] = useState(loadFade);
  // A prompt sent from the latest row: what the composer drew of it moves into this row's bubble and
  // previews, as its entrance (conversation/sendMorph.ts). Its first mount only, before it paints.
  useLayoutEffect(() => {
    if (messageEntering && row.kind === "user" && ref.current) playSendMorph(ref.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the frame's first mount only
  }, []);
  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLElement>) => onRowKeyDown(index, event),
    [index, onRowKeyDown],
  );
  const rowTabStop = rovingTabStopProps(tabStop, handleKeyDown);
  // A frame drawn again for its place hands down the scope object it had while that names the same
  // repositories (sameRowFrame compares it so): a new object would redraw its content's chips.
  const [scope, setScope] = useState(referenceScope);
  if (scope !== referenceScope && !sameReferenceScope(scope, referenceScope)) setScope(referenceScope);
  const content = <ReferenceScopeContext.Provider value={scope ?? null}>{children}</ReferenceScopeContext.Provider>;
  useLayoutEffect(() => {
    if (acpmuxPerf.enabled) acpmuxPerf.render(`frame:${row.id}`);
  });
  useLayoutEffect(() => {
    // Mounts and same-commit remounts, counted only while measuring (loadDebug.ts `loadTick`).
    const id = row.id;
    acpmuxPerf.rowMounted(id);
    return () => acpmuxPerf.rowUnmounted(id);
    // The id the frame mounted with: a message run's line can take over its first row's frame
    // (model.ts `rowFrameKey`), so the count is closed under the id it opened with.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useLayoutEffect(() => {
    if (loadFading) onLoadFaded(row.id);
    // Only the first mount fades.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useLayoutEffect(() => {
    if (entering) onEntered(rowFrameKey(row));
    // Only the first mount enters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  // A generic row's entrance starts on the frame that first draws it, not at this commit: WebKit
  // starts its clock here, and a busy main thread drew the row only after its fade had ended, whole
  // at once (conversation/entranceClock.ts). Messages keep their own send clock.
  useLayoutEffect(() => {
    if (!entering || messageEntering || !ref.current) return undefined;
    return holdEntranceForFirstFrame(ref.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the frame's first mount only
  }, []);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !olderFade) return;
    // A warm-window copy has rendered too: consume eligibility and start its fade before paint,
    // even offscreen. Neither a later intersection nor a remount may defer or replay it.
    onOlderShown(row.id);
    node.dataset.olderShown = "true";
    return olderFade.watch(node, () => onOlderShown(row.id));
    // Only the first mount fades.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !observer) return;
    observer.observe(node);
    return () => observer.unobserve(node);
  }, [observer]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (node) return queueDrawn(node, row.id, row.version, replyActions, status);
  }, [
    row.id,
    row.version,
    replyActions,
    status,
    rowWidth,
    expanded,
    joinsPrevious,
    joinsNext,
    beforeFooter,
    lastFooter,
    continuationFooter,
    lastTurn,
    queueDrawn,
  ]);
  const placedTop = top + THREAD_TOP;
  const integralTop = Math.floor(placedTop);
  return (
    <article
      ref={ref}
      id={rowDomId(row.id)}
      data-row-id={row.id}
      data-row-card={row.ended ? "true" : undefined}
      data-opens-turn={opensTurn ? "true" : undefined}
      className={`acpmux-row acpmux-${kind}${isLineRow(row) ? " acpmux-row--line" : ""}${row.below ? " acpmux-row--below" : ""}${joinsPrevious ? " acpmux-row--after-step" : ""}${joinsNext ? " acpmux-row--before-step" : ""}${beforeFooter ? " acpmux-row--before-footer" : ""}${beforeIndicator ? " acpmux-row--before-indicator" : ""}${replyActions ? " acpmux-row--reply-room" : ""}${status ? ` acpmux-row--${status}` : ""}${lastFooter ? " acpmux-row--last-footer" : ""}${finalFooter ? " acpmux-row--final-footer" : ""}${continuationFooter ? " acpmux-row--continuation-footer" : ""}${lastTurn ? " acpmux-row--last-turn" : ""}${messageEntering ? " acpmux-row--message-enter" : entering ? " acpmux-row--enter" : ""}${olderFade ? " acpmux-row--older" : ""}${loadFading ? ` ${LOAD_FADE_CLASS}` : ""}`}
      data-transcript-active={active ? "true" : undefined}
      data-transcript-selected={selected ? "true" : undefined}
      aria-current={active ? "true" : undefined}
      {...rowTabStop}
      aria-label={speaker(kind, t)}
      aria-posinset={index + 1}
      aria-setsize={setSize}
      // `top`, not a transform: in the app (the page at its UI-scale zoom) a drag over a row placed
      // by `translateY` selected the line above the pointer (user 2026-10-21). A set `top` counts
      // from the thread's padding edge, not where an unset one sat, so it adds the padding.
      // Large CSS numeric offsets lose fractional bits in WebKit. Keep the integer offset and
      // its subpixel remainder separate so animated row heights remain adjacent in long chats.
      style={{ top: integralTop, marginTop: placedTop - integralTop }}
      onFocus={() => onFocus(row.id)}
    >
      {/* The row's own trailing gap is the only row-local empty surface owned by transcript selection.
          Keeping it as a separate hit target means content controls (including native media) never
          need to be enumerated by the gap handler. On the grid the stack places the gap under the row
          (design/grid.md 5.5), so the target spans the row's own bottom padding (inherited) and that
          placed gap under it, down to the next row. It comes first: the action rows
          laid in the same gap are positioned later in the row and stay over it, with their clicks. */}
      <span
        className="acpmux-row__gap"
        data-transcript-gap="row"
        aria-hidden="true"
        style={gapBelow > 0 ? { bottom: -gapBelow, height: gapBelow, boxSizing: "content-box" } : undefined}
      />
      {messageEntering ? (
        // The article is the virtualizer's measured box. Animate only this presentation wrapper:
        // compositor scale/opacity cannot change drawnHeightOf(article) while the entrance runs.
        <div className="acpmux-row__message-presentation">{content}</div>
      ) : (
        content
      )}
    </article>
  );
}, sameRowFrame);

/// Whether the rows at the tail changed by more than the reply's own text: a row came or went, or a
/// row other than a reply and the live line changed (a call finished, a thought grew, a steer
/// landed). O(1): the last ARRIVAL_TAIL rows, by id and version.
const ARRIVAL_TAIL = 6;
/// How long after a row arrived its room still counts as the arrival: the passes that measure it.
const ARRIVAL_PASS_MS = 100;
function arrivedAtTail(before: readonly AcpmuxRow[], after: readonly AcpmuxRow[]): boolean {
  if (before.length !== after.length) return true;
  for (let index = after.length - 1; index >= Math.max(0, after.length - ARRIVAL_TAIL); index -= 1) {
    const row = after[index]!;
    const was = before[index]!;
    if (row.id !== was.id) return true;
    if (row === was || row.version === was.version) continue;
    if (row.id !== LIVE_THINKING && row.kind !== "assistant") return true;
  }
  return false;
}

/// Who spoke, for assistive technology: each article is one message in the transcript feed.
const speaker = (kind: string, t: Translate) =>
  kind === "user" ? t("transcript.you") : kind === "assistant" ? t("transcript.agent") : undefined;

/// A row drawn as tool rows: tool calls and thoughts, a background task's or a subagent's end, a
/// compaction, a failover, a policy the harness cannot keep, and the one-line
/// rows drawn on the tool rows' line (model.ts `isLineRow`: another agent's message, a notice, an
/// inbox notice, a report batch's or the waiting group's head), so they all sit one line apart.
const isStepRow = (row: AcpmuxRow | undefined) =>
  row !== undefined &&
  (isLineRow(row) ||
    row.kind === "backgroundTask" ||
    row.kind === SUBAGENT_DONE ||
    row.kind === "compaction" ||
    row.kind === "failover" ||
    row.kind === "policyUnenforced" ||
    row.kind === "agentPair" ||
    row.kind === BACKGROUND_TURN ||
    (row.kind === "activity" && !isEditRow(row)));

/// A step row by its layout mark: a step row above, or the running turn's line right under one
/// (model.ts `isLiveStep`, which `layoutConversation` marks MARK_STEP), so the live line and its
/// neighbours carry the after-step and before-step classes the layout implies (#31769).
const isStepAt = (rows: readonly AcpmuxRow[], index: number) => {
  const row = rows[index];
  return isStepRow(row) || (row?.below === true && isLiveStep(row, prevDrawnRow(rows, index)));
};

const rowDomId = (id: string) => `acpmux-row-${encodeURIComponent(id)}`;

const disclosureControls = (rows: readonly AcpmuxRow[], after: number): string | undefined => {
  const ids: string[] = [];
  for (let index = after; index < rows.length; index += 1) {
    const row = rows[index]!;
    // turnView marks every row copied under an open Worked-for disclosure as settled. This
    // includes assistant commentary before the tool calls; stopping on kind alone left that
    // first commentary row outside aria-controls and made the disclosure target incomplete.
    if (!row.settled) break;
    ids.push(rowDomId(row.id));
  }
  return ids.length > 0 ? ids.join(" ") : undefined;
};

/// The thread's top padding (styles.css `.acpmux-thread`): rows draw this far below their places
/// (each row's `top` adds it), so the transcript ends this far past their total height.
const THREAD_TOP = 16;

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
function settleFollowBottom(node: HTMLElement, latest: number): boolean {
  const end = Math.ceil(latest - 0.01);
  // Where the write lands: a scroller already clamped there is at its end.
  const lands = Math.min(end, Math.max(0, node.scrollHeight - node.clientHeight));
  const moved = Math.abs(lands - node.scrollTop) > 0.5;
  if (moved) node.scrollTop = end;
  // Measurements above the view can move the logical end by half a pixel while the physical
  // end stays rounded. Keep that fraction even when the browser already clamped to the end,
  // so releasing follow before the next wheel does not inherit a half-pixel row jump.
  retainScrollOrigin(node, latest);
  return moved;
}

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
const SCROLL_LEAD_STEPS = 2;

/// Once a fling stops, keep its lead only briefly. A stale direction keeps rows mounted far ahead
/// of the reader and makes every later render pay for a scroll that already ended.
const SCROLL_LEAD_IDLE_MS = 120;

/// More new rows than this in one update are a load (a session switch, older history), not live rows.
const LIVE_ROWS_PER_UPDATE = 3;
/// How recent an empty chat's first prompt is when its transcript mounts for it to enter (above).
const FIRST_SEND_FRESH_MS = 2000;

/// Viewports from the top of the loaded rows within which a page of older history came late: the
/// reader reached rows that were not loaded yet, so the page fades in. Pages ask well ahead
/// (OLDER_AHEAD_VIEWPORTS), so a page normally lands farther away and draws in place.
const OLDER_LATE_VIEWPORTS = 1;

/// Whether the reader's view is at the top of the loaded rows, read before a page lands above them.
/// A hidden or unplaced scroller draws in place (WebKit would play a hidden page's fade on return).
/// `room` is the space held above the loaded rows (ConversationLayout.origin).
function readerAtLoadedTop(node: HTMLElement | null, room: number): boolean {
  if (!node || node.clientHeight === 0) return false;
  return node.scrollTop - scrollOrigin(node) - room < node.clientHeight * OLDER_LATE_VIEWPORTS;
}

/// Rows from a page of older history that came late (readerAtLoadedTop) fade on their first mounted copy, including warm copies
/// outside the view. Eligibility is consumed before paint; an intersection only releases the
/// observation and never starts a second fade. Opacity only, so nothing measured moves.
class OlderRowFade {
  private readonly pending = new Set<string>();
  private readonly waiting = new Map<Element, () => void>();
  private intersections: IntersectionObserver | undefined;
  constructor(private readonly root: () => HTMLElement | null) {}
  add(id: string) {
    this.pending.add(id);
  }
  has(id: string) {
    return this.pending.has(id);
  }
  shown(id: string) {
    this.pending.delete(id);
  }
  clear() {
    this.pending.clear();
  }
  /// Releases the first copy's observation when it intersects; returns the unwatch.
  watch(node: HTMLElement, shown: () => void): () => void {
    if (typeof IntersectionObserver === "undefined") {
      shown();
      return () => {};
    }
    this.intersections ??= new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const target = entry.target as HTMLElement;
          target.dataset.olderShown = "true";
          this.intersections?.unobserve(target);
          this.waiting.get(target)?.();
          this.waiting.delete(target);
        }
      },
      { root: this.root() },
    );
    this.waiting.set(node, shown);
    this.intersections.observe(node);
    return () => {
      this.waiting.delete(node);
      this.intersections?.unobserve(node);
    };
  }
  disconnect() {
    this.intersections?.disconnect();
    this.intersections = undefined;
    this.waiting.clear();
  }
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
/// was a fraction of a second of a flick).
const OLDER_AHEAD_VIEWPORTS = 6;

/// Scrolls `scroller` so `range` sits a third of the way down it, when it is not already in view
/// above the `inset` px at its foot that the bottom stack covers.
function scrollRangeIn(scroller: HTMLElement, range: Range, inset = 0) {
  const box = range.getBoundingClientRect();
  const view = scroller.getBoundingClientRect();
  if (box.top < view.top || box.bottom > view.bottom - inset)
    scroller.scrollTop += box.top - view.top - scroller.clientHeight / 3;
}

/// Scrolls `range` into view in the scrollers between it and `transcript` (a command's capped
/// output scrolls on its own), innermost first; the transcript itself is left to the caller.
function scrollRangeInBoxes(transcript: HTMLElement, range: Range) {
  for (let box = range.startContainer.parentElement; box && box !== transcript; box = box.parentElement)
    if (box.scrollHeight > box.clientHeight && /auto|scroll/.test(getComputedStyle(box).overflowY))
      scrollRangeIn(box, range);
}

/// How long Find keeps a new match in view while its groups open and the rows above it measure:
/// at least 600 ms and 36 frames, so a page the machine starves (fewer frames) still holds the
/// match through the measures that come late. A page hidden meanwhile draws no frames and finishes
/// the frames it has left once shown.
const FIND_REVEAL_MS = 600;

const FIND_REVEAL_FRAMES = 36;

/// ...and until the match has not moved for this many frames: on a starved page the fold it opened
/// measures for seconds, each measure pushing the match down.
const FIND_REVEAL_STILL_FRAMES = 12;

/// A layout that never settles (a reply streaming above the match) ends the hold after this many.
const FIND_REVEAL_MAX_FRAMES = 600;

/// The current Find match's range, if it is drawn.
function findActiveRange(): Range | undefined {
  const highlights = (globalThis.CSS as unknown as { highlights?: Map<string, Set<Range>> } | undefined)?.highlights;
  return [...(highlights?.get(FIND_ACTIVE_HIGHLIGHT) ?? [])][0];
}

/// Where the current Find match sits in `scroller`'s content, if it is drawn.
function findMatchOffset(scroller: HTMLElement): number | undefined {
  const range = findActiveRange();
  if (!range) return undefined;
  return range.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
}

/// Where a chat's transcript rests: the row at the top of the view and how far into it; null is the
/// latest message, which a reopened chat follows anyway.
export type ScrollAnchor = { rowId: string; offset: number };

/// Where a transcript scrolled to `top` rests: null at its latest message.
function restingAnchor(
  top: number,
  atLatest: boolean,
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
): ScrollAnchor | null {
  const index = visibleLayoutRange(placed, top, 0, 0).first;
  const row = shown[index];
  return atLatest || !row ? null : { rowId: row.id, offset: top - layoutGeometry(placed).topAt(index) };
}

/// Where the warm rows are built from, as a row and how far into it: one string, so the deferred
/// render that builds them runs only when it moves. A row holds its content as rows page in above
/// it or a followed end moves under it; an offset into the whole stack did not, and a deferred one
/// from the frame before picked rows turns away (`warmTop`). The row's index is a hint for the read.
function warmAnchor(
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
  at: number,
  step: number,
) {
  const index = visibleLayoutRange(placed, at, 0, 0).first;
  const row = shown[index];
  // In steps too: a row above that settles to its drawn height moves the row, not the anchor.
  return row ? `${Math.round((at - layoutGeometry(placed).topAt(index)) / step) * step}\n${index}\n${row.id}` : "";
}

/// The offset of `anchor` (warmAnchor) in `placed`: its row at the index it was found at, else looked
/// for (older history paged in above it, once, until the deferred anchor catches up). Undefined once
/// it is gone.
function warmAnchorTop(
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
  anchor: string,
) {
  const [offset, hint, id] = anchor.split("\n");
  if (id === undefined) return undefined;
  const at = Number(hint);
  const index = shown[at]?.id === id ? at : shown.findIndex((row) => row.id === id);
  return index < 0 ? undefined : layoutGeometry(placed).topAt(index) + Number(offset);
}

/// Jump to latest's diameter, CSS px (conversation.css .acpmux-jump-latest): its fisheye filter is
/// drawn for it (ui/glass/Fisheye.tsx).
const JUMP_LATEST_SIZE = 32;

/// Jump to latest: a glass control centered above the composer, shown while the reader is scrolled up
/// from the latest message (ChatGPT and Codex style). Its look is the `jump-pair-look` experiment
/// (jumpPair.experiment.ts, jumpPair.css): a frosted disc by default (Leo 2026-11-12, of the fisheye
/// disc: "a little bit strange-looking"); the `lens` arm keeps the fisheye that magnifies the
/// transcript under it (Leo 2026-10-21: "I want more fisheye!"). Its mark is the `chat.jumpToBottom` theme slot:
/// the default variant stays a static arrow while the agent works (the shared transcript spinner shows the work),
/// and a theme's variant may move while `working`. It stays mounted while
/// hidden (inert) so it fades out as it fades in (conversation.css).
export function JumpToLatest({
  shown,
  working,
  onJump,
  lift,
  needsYou,
}: {
  shown: boolean;
  working: boolean;
  /// Open asks (needsYou/JumpPill.ts): the button becomes the Needs your input pill.
  needsYou?: TranscriptNeedsYou;
  /// The bottom stack's height over the transcript's foot: the button sits above it.
  lift: number;
  /// `focused`: the button had keyboard focus, which it loses when it hides at the latest message.
  onJump: (focused: boolean) => void;
}) {
  const t = useT();
  const [look] = useState(() => experimentArm(jumpPairLook));
  if (needsYou && needsYou.count > 0) return <NeedsYouPill {...needsYou} shown={shown} lift={lift} onJump={onJump} />;
  const label = t(working ? "transcript.jumpLatestWorking" : "transcript.jumpLatest");
  const lens = look === "lens";
  return (
    <>
      {lens && <FisheyeFilters size={JUMP_LATEST_SIZE} />}
      <button
        type="button"
        ref={leaveOnScreenRef}
        className={lens ? "ui-glass ui-glass-fisheye acpmux-jump-latest" : "ui-glass acpmux-jump-latest"}
        data-look={look}
        data-shown={shown ? "" : undefined}
        // Its keyboard focus is its own wash over the glass (conversation.css), not the shared one,
        // whose `box-shadow: none` took the glass's rim and shadow away while it was focused.
        data-focus-ring="none"
        style={lift > 0 ? ({ "--acpmux-dock-space": `${lift}px` } as React.CSSProperties) : undefined}
        aria-label={label}
        // The arrow says nothing by itself; working state is carried by the shared spinner in the transcript.
        title={label}
        // Hidden, it is inert: out of the tab order and the accessibility tree while it fades out.
        inert={!shown}
        // A click does not focus a button in WebKit, so focus on it means Return or Space.
        onClick={(event) => onJump(event.currentTarget === document.activeElement)}
      >
        {/* The mark is a theme slot (schemas/theme/slots.json `chat.jumpToBottom`): its default variant
            draws exactly the static arrow this button drew before. */}
        <Slot slot={jumpToBottomSlot} props={{ shown, working }} />
        {look === "labeled" && <span className="acpmux-jump-latest__label">{t("transcript.jumpLatest")}</span>}
      </button>
    </>
  );
}

/// Jump up (jumpUp.ts): Jump to latest's companion, stacked on it in the bottom-center zone
/// (overlayLayout.ts, jumpPair.css): the same glass, look, size and fade, its arrow up. It goes to
/// where the reader left off (the unread "New" line, else their last prompt or where they last
/// stopped scrolling) while that place is off screen; pressed, it points down and a second press or
/// Esc goes back to where the view was.
export function JumpUp({
  shown,
  back,
  onJump,
  lift,
}: {
  shown: boolean;
  back: boolean;
  onJump: () => void;
  lift: number;
}) {
  const t = useT();
  const label = t(back ? "transcript.jumpBack" : "transcript.jumpUp");
  const [look] = useState(() => experimentArm(jumpPairLook));
  return (
    <button
      type="button"
      className="ui-glass acpmux-jump-latest acpmux-jump-up"
      data-look={look}
      data-shown={shown ? "" : undefined}
      data-back={back ? "" : undefined}
      data-focus-ring="none"
      style={lift > 0 ? ({ "--acpmux-dock-space": `${lift}px` } as React.CSSProperties) : undefined}
      aria-label={label}
      title={label}
      inert={!shown}
      onClick={onJump}
    >
      <span className="acpmux-jump-latest__arrow" aria-hidden="true">
        <ArrowDown size={14} />
      </span>
      {look === "labeled" && <span className="acpmux-jump-latest__label">{label}</span>}
    </button>
  );
}

/// The index of row `id` in `rows`, starting from where it was last found (`hint`): the transcript
/// mostly appends, so the hint holds and the lookup is O(1); a miss scans once.
function indexOfRow(rows: readonly AcpmuxRow[], id: string | undefined, hint: { current: number }): number {
  if (id === undefined) return -1;
  if (rows[hint.current]?.id === id) return hint.current;
  const at = rows.findIndex((row) => row.id === id);
  hint.current = at;
  return at;
}

/// A read-only transcript draws inside the guest boundary (conversation/GuestActionsBoundary.tsx).
function ReadOnlyBoundary({ readOnly, children }: { readOnly: boolean; children: React.ReactNode }) {
  return readOnly ? <GuestActionsBoundary>{children}</GuestActionsBoundary> : <>{children}</>;
}

/// What the transcript's rows read from it: Find's reveal target and, for a prompt's own bookmark
/// button, the session its marks key into (threadMinimap/promptMarks.ts).
function TranscriptContext({
  find,
  sessionId,
  children,
}: {
  find: React.ContextType<typeof FindReveal>;
  sessionId?: string;
  children: React.ReactNode;
}) {
  return (
    <FindReveal.Provider value={find}>
      <PromptMarksSession.Provider value={sessionId ?? ""}>{children}</PromptMarksSession.Provider>
    </FindReveal.Provider>
  );
}

export type VirtualTranscriptProps = Omit<React.ComponentProps<typeof TranscriptView>, "references">;

/// Where the transcript reads each row's bare `#N` scope (conversation/bareReferences.ts): the
/// reading of the client's rows and the cache it keeps. A new value only when a scope changed.
type TranscriptReferences = {
  readonly cache: ReferenceScopeCache;
  readonly scopeOf: (opener: string) => ReferenceScope;
};

/// The list props a pane render rebuilds with the same rows in them (the pane's row shaping and
/// queue lists run again on every snapshot).
const LIST_PROPS: ReadonlySet<string> = new Set([
  "rows",
  "sourceRows",
  "earlier",
  "queuedTail",
  "queueIds",
  "queueWithdrawn",
]);

/// The same item: the same object, or a row the shaping made again with every field the same
/// (turns.ts builds the live line anew on each pass).
function sameItem(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object" || Array.isArray(a) || Array.isArray(b)) return false;
  const before = a as Record<string, unknown>;
  const after = b as Record<string, unknown>;
  const keys = Object.keys(after);
  return keys.length === Object.keys(before).length && keys.every((key) => Object.is(before[key], after[key]));
}

/// One identity compare per row; the field compare only where the objects differ (a few rows).
function sameList(a: readonly unknown[], b: readonly unknown[]): boolean {
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index += 1)
    if (a[index] !== b[index] && !sameItem(a[index], b[index])) return false;
  return true;
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

/// The bare `#N` scopes of `source` (referenceScopes), kept as the last value while every scope
/// it gives is the one it gave: the same reading of every row before the last (the cache kept its
/// prefix and evidence) and the same scope for the last row's turn.
function useTranscriptReferences(source: readonly AcpmuxRow[]): TranscriptReferences {
  const cache = useRef<ReferenceScopeCache>(undefined as unknown as ReferenceScopeCache);
  cache.current ??= newReferenceScopeCache();
  const held = useRef<
    | { source: readonly AcpmuxRow[]; value: TranscriptReferences; lastTurn?: string; lastScope?: ReferenceScope }
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
  onLoadOlder,
  sends = 0,
  onFollowingChange,
  onJumpShownChange,
  coldOpen,
  onColdOpenShown,
  loading = false,
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
  earlier?: readonly AcpmuxRow[];
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
  onLoadOlder?: () => Promise<void>;
  /// How many prompts this pane has sent: each new one puts the view at the latest message.
  sends?: number;
  /// Keeps the parent send path in sync with the reader's current follow state.
  onFollowingChange?: (following: boolean) => void;
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
          next[below] = { ...line, quietKey: `${row.id}:${version}`, version: line.version + live.ahead };
      }
      return next;
    }
    return paneRows;
  }, [paneRows, live, streams]);
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
  const setScrollAt = (top: number, delta = top - scrollRef.current.top) => {
    const next = { top, delta };
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
  /// Jump up (jumpUp.ts): where the reader last stopped scrolling by hand, the way back a press
  /// holds (a second press or Esc returns there), and the row lookups' hints.
  const stoppedMark = useRef<ManualMark | undefined>(undefined);
  const jumpBack = useRef<JumpBack | undefined>(undefined);
  const [jumpBackHeld, setJumpBackHeld] = useState(false);
  const promptScan = useRef<PromptScan>({ length: 0 });
  const jumpUpHint = useRef(-1);
  /// The offset Jump up just set, so its scroll event is not taken for the reader's stop.
  const placedTop = useRef<number | undefined>(undefined);
  /// Jump up's glide is in flight (`placeView`): its steps are its own, not the reader's stops.
  const placing = useRef(false);
  const sinceHint = useRef(-1);
  // Without the folder's GitHub remote, a bare `#N` in a row means the repository the transcript
  // mentioned last (conversation/transcriptRepositories.ts); each row's text is read once per change.
  const repositoryCache = useRef<RepositoryCache>(new Map());
  const repositoryReading = useRef<RepositoryReading | undefined>(undefined);
  const rowRepositories = useMemo(() => {
    if (githubRepository) return undefined;
    const reading = transcriptRepositoriesFrom(
      rows,
      fallbackRepository,
      repositoryCache.current,
      repositoryReading.current,
    );
    repositoryReading.current = reading;
    return reading.at;
  }, [githubRepository, fallbackRepository, rows]);
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
  const chasing = followArm !== "eased";
  const followChase = useRef<FollowChase>(undefined);
  followChase.current ??= createFollowChase(followArm);
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
  sinceMark.current = sinceKey;
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
    followingRef.current = next;
    onFollowingChange?.(next);
    setFollowing(next);
  };
  const followRef = useRef(follow);
  followRef.current = follow;
  const transcriptMounted = useRef(true);
  const scrollPacer = useRef<ReturnType<typeof createScrollPacer> | undefined>(undefined);
  scrollPacer.current ??= createScrollPacer((frame: ScrollFrame) => {
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
      scrollRef.current = { top, delta: top - scrollRef.current.top || scrollRef.current.delta };
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
  });
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
    scrollRef.current = { top, delta: top - scrollRef.current.top || scrollRef.current.delta };
    scheduleScrollLeadReset();
    if (immediate) scrollPacer.current!.flush({ top, atLatest });
    else scrollPacer.current!.enqueue({ top, atLatest });
  };
  useEffect(() => {
    transcriptMounted.current = true;
    // The flicker detector's remount count (flickerLog.ts): a second mount on one page is a remount.
    noteTranscriptMount();
    return () => {
      transcriptMounted.current = false;
      scrollPacer.current?.cancel();
      clearTimeout(scrollLeadTimer.current);
    };
  }, []);
  /// Where Jump to latest's glide is headed while it is in flight: its steps are the view following,
  /// not the reader's scroll, and nothing snaps it to the end before it arrives.
  const jumpTarget = useRef<number | undefined>(undefined);
  const wheelGlide = useRef<ReturnType<typeof installWheelGlide>>(undefined);
  /// Eases the followed view's steps with a streaming reply on the compositor (followGlide.ts).
  const followGlide = useRef<ReturnType<typeof createFollowGlide>>(undefined);
  followGlide.current ??= createFollowGlide();
  /// The rows under what changed glide to their new place while the chase follows (tailGlide.ts),
  /// instead of jumping by what landed above them (the live line, a steer under its new footer).
  const tailGlide = useRef<TailGlide>(undefined);
  tailGlide.current ??= createTailGlide();
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
  ) => {
    const chase = followChase.current!;
    const rowTop = (id: string) => {
      const name = typeof CSS === "undefined" ? id.replace(/["\\]/g, "\\$&") : CSS.escape(id);
      const row = thread.current?.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${name}"]`);
      return row ? row.getBoundingClientRect().top - chase.outstanding() : undefined;
    };
    const before = chaseAnchor.current;
    const now = before ? rowTop(before.id) : undefined;
    // Followed again after the reader's input held it: it goes on home from where it is drawn.
    resumeFollowMotion();
    chase.fit(below);
    // A turn's end folding moves the rows itself (turnEndFold.ts): their motion is no move to chase.
    const turnEnding = thread.current?.hasAttribute(TURN_END_ATTR) === true;
    if (before && now !== undefined && !moveAtOnce && !turnEnding)
      chase.shift(thread.current, now - before.top, below, held, arrived);
    const first = visibleLayoutRange(placed, layoutScrollTop(node), node.clientHeight, 0).first;
    const id = shown[Math.min(first, shown.length - 1)]?.id;
    const top = id === undefined ? undefined : rowTop(id);
    chaseAnchor.current = id !== undefined && top !== undefined ? { id, top } : undefined;
  };
  /// When the view last changed size: the passes that settle the rows after it never glide.
  const resizedAt = useRef(Number.NEGATIVE_INFINITY);
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
  /// The bottom stack's reach at rest, for the prompt rail's box (`railBox`): its smallest at `height`.
  const restingDock = useRef<{ height: number; sessionId?: string; dock?: HTMLElement | null; space: number }>({
    height: -1,
    space: 0,
  });
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
  useLayoutEffect(() => {
    if (!dock) {
      setDockSpace(0);
      setDockHeight(0);
      setDockCard(0);
      setDockTray(0);
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
    // The composer card's height, while the stack reaches over the view.
    const card = (space: number) =>
      space > 0 ? (dock.querySelector(".acpmux-composer-box")?.getBoundingClientRect().height ?? 0) : 0;
    // The tray, at its drawn height while what it opens plays (useFold animates it); not the copy
    // of one that left (trayMotion.tsx), which fades over the stack and takes no room.
    const tray = (space: number) =>
      space > 0
        ? (dock.querySelector(`:scope > .acpmux-running-tray:not(.${TRAY_GHOST})`)?.getBoundingClientRect().height ?? 0)
        : 0;
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
    freezeGrowthRise.current = () => {
      const rows = thread.current;
      const move = rowsMove;
      if (!rows || !move || move.playState === "finished" || move.playState === "idle") return;
      const drawnY = () => {
        const value = getComputedStyle(rows).translate;
        return value && value !== "none" ? Number.parseFloat(value.split(" ")[1] ?? "") || 0 : 0;
      };
      const before = drawnY();
      move.cancel();
      rowsMove = undefined;
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
      // A tray that went holds nothing: the room is the stack's again.
      if (nextTray <= 0) trayToggled.current = false;
      if (
        Math.abs(next - dockSpaceRef.current) >= 0.5 ||
        Math.abs(nextHeight - dockHeightRef.current) >= 0.5 ||
        Math.abs(nextCard - dockCardRef.current) >= 0.5
      )
        flushSync(() => {
          setDockSpace(next);
          setDockHeight(nextHeight);
          setDockCard(nextCard);
          setDockTray(nextTray);
        });
    };
    const observer = new ResizeObserver(take);
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
    setDockHeight(fullHeight);
    setDockCard(card(space));
    setDockTray(tray(space));
    return () => {
      observer.disconnect();
      dock.removeEventListener("click", toggled, { capture: true });
      dock.removeEventListener(FIELD_GROWTH_EVENT, grew);
      rowsMove?.cancel();
      freezeGrowthRise.current = () => {};
    };
  }, [dock, noteQueue]);
  // And each time the queue changes, in the commit that draws it. A change that leaves the stack's
  // size as it was (a prompt the fold hides, or one an opened list's cap cuts off, run by another
  // client) runs neither observer: still noted as queued, the next resize took it for a card that
  // left then, and kept room above the stack for FLOOR_HOLD_MS that then glided away (#24182).
  useLayoutEffect(() => noteQueue(), [sessionId, queueIds, noteQueue]);
  const [width, setWidth] = useState(() => lastTranscriptBox.width);
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
  const lastEstimate = useRef<
    { rows: readonly AcpmuxRow[]; layout: ConversationLayout; width: number; sessionId?: string } | undefined
  >(undefined);
  /// Estimated heights by row object, for the registry they were measured with.
  const rowHeights = useRef<{ registry: NativeRegistry; heights: RowHeights }>({
    registry,
    heights: new WeakMap(),
  });
  const measurementSession = useRef(sessionId);
  if (measurementSession.current !== sessionId) {
    // Row ids and versions are local to an acpmux session. A new session can reuse both, so
    // prepared markdown and DOM heights from the old transcript must never place the new one.
    measurementSession.current = sessionId;
    measurementCache.current.clear();
    rowHeights.current = { registry, heights: new WeakMap() };
    pendingDrawn.current.clear();
  }
  const drawnRef = useRef(drawn);
  drawnRef.current = drawn;
  const endReserve = Math.max(cardReserve, minimapBeside ? minimapReserve(width) : 0);
  const scaledRowWidth = transcriptRowWidth(width, chatColumnOf(chatLook, chatScale), endReserve);
  const rowWidthRef = useRef(scaledRowWidth);
  rowWidthRef.current = scaledRowWidth;
  const rowsRef = useRef(rows);
  /// The rows the render before this one drew, and its chat, for a turn's end (turnEndFold.ts).
  const rowsBefore = rowsRef.current;
  rowsRef.current = rows;
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
  activeRowRef.current = activeRowId;
  const transcriptRangeRef = useRef(transcriptRange);
  transcriptRangeRef.current = transcriptRange;
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
  heldSession.current = sessionKey;
  // Keep the key in state so a StrictMode render cannot consume the session transition before the
  // reset effect commits. The keyed values below make the first new-session paint fresh as well.
  const [selectionSessionKey, setSelectionSessionKey] = useState(sessionKey);
  const sessionChanged = selectionSessionKey !== sessionKey;
  /// A row can be newly arrived but outside the mounted virtual range. Pending entrances are
  /// page-scoped: hiding or switching chats must drop them before that row can mount later.
  const enteringRows = useRef(new Set<string>());
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
      enteringRows.current.clear();
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
  }, [rows, sessionChanged, sessionKey]);
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
  const minimapPlaced = useRef<(() => void) | undefined>(undefined);
  const olderRows = useRef<OlderRowFade | undefined>(undefined);
  olderRows.current ??= new OlderRowFade(() => ref.current);
  // Row ids are local to a session: one still waiting to fade belongs to the chat that was shown.
  if (sessionChanged) olderRows.current.clear();
  /// The room above the rows for history not loaded yet, and the row it is held against.
  const olderRoom = useRef<OlderReserve | undefined>(undefined);
  /// How far the reader has scrolled up among the rows while room was owed (olderReserve.ts `rose`),
  /// in total, and the offset the last scroll event read: each rise pays some of what is owed.
  /// offset the last scroll event read.
  const [roomRose, setRoomRose] = useState(0);
  const roomPaidFrom = useRef<number | undefined>(undefined);
  /// Rows that arrived while the chat loaded (blank or partly blank, then text): their first mount
  /// fades in once (Leo, 2026-11-07, ask-69299b9711: "blank to fast fade in to text").
  const loadFade = useRef<LoadFadeWindow | undefined>(undefined);
  loadFade.current ??= new LoadFadeWindow();
  if (sessionChanged) loadFade.current.clear();
  loadFade.current.phase(loading);
  // A switched chat starts over: its row ids are its own, and may repeat the last chat's.
  // Keyed by frame (model.ts `rowFrameKey`): a row drawn in a frame already on screen is not new.
  if (knownRows.current === null || sessionChanged) {
    const mounting = knownRows.current === null;
    knownRows.current = new Set(rows.map(rowFrameKey));
    // An empty chat draws no transcript: it mounts with the first prompt the reader just sent (and
    // its thinking line), and those rows enter on the send's clock as every later prompt's do
    // (conversation.css SEND-ENTRANCE). A transcript mounted again over an older chat does not.
    if (
      mounting &&
      sends > 0 &&
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
    // page came late: the reader already reached the top of the loaded rows, and only then do they
    // fade in as they are first seen (Leo 2026-10-31: no fade unless it's the worst case).
    const oldFirst = rows.findIndex((row) => knownRows.current!.has(rowFrameKey(row)));
    const arrived: AcpmuxRow[] = [];
    let olderLate: boolean | undefined;
    // The chat still loads (or its read just landed): what arrives fills a blank or partly blank
    // view, so it fades in rather than popping. A cold open's first rows fade with the whole
    // transcript instead (fadeInOpenedChat), so they take no row fade on top of it.
    const loadArrival = loadFade.current.open && coldOpen === undefined;
    // The running turn's live line keeps one id from turn to turn (turns.ts LIVE_THINKING): a line
    // the last rows did not end with came now, with the prompt that opened it, so it enters on the
    // send's clock with the prompt (conversation.css SEND-ENTRANCE). O(1): the last rows' tail only.
    const liveBefore = previous.at(-1)?.below ? rowFrameKey(previous.at(-1)!) : undefined;
    for (let index = from; index < rows.length; index += 1) {
      const row = rows[index]!;
      const key = rowFrameKey(row);
      if (knownRows.current.has(key) && !(row.below && index === rows.length - 1 && key !== liveBefore)) continue;
      if (index < oldFirst) {
        olderLate ??= readerAtLoadedTop(ref.current, olderRoom.current?.room ?? 0);
        if (olderLate) olderRows.current.add(row.id);
        else if (loadArrival) loadFade.current.arrive(row.id);
      } else if (loadArrival) loadFade.current.arrive(row.id);
      else arrived.push(row);
      knownRows.current.add(key);
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
  const onEntered = useCallback((id: string) => void enteringRows.current.delete(id), []);
  const onLoadFaded = useCallback((id: string) => loadFade.current?.shown(id), []);
  const onOlderShown = useCallback((id: string) => olderRows.current?.shown(id), []);
  useEffect(() => () => olderRows.current?.disconnect(), []);
  const reportDrawn = useCallback<ReportDrawn>(
    (id, version, drawnHeight, actions, status) => {
      // A row not laid out (hidden, or no layout at all) has no height yet; 0 is one (drawnHeightOf).
      if (drawnHeight !== undefined)
        pendingDrawn.current.set(id, {
          sessionId,
          version,
          width: rowWidthRef.current,
          height: drawnHeight,
          ...(actions ? { actions } : {}),
          ...(status ? { status } : {}),
        });
    },
    [sessionId],
  );
  const queueDrawn = useCallback<QueueDrawn>(
    (node, id, version, actions, status) => {
      const measure = () => {
        if (!node.isConnected || node.dataset.rowId !== id) return;
        reportDrawn(
          id,
          version,
          acpmuxPerf.timed("row.measure", () => drawnHeightOf(node)),
          actions,
          status,
        );
      };
      pendingMeasures.current.set(node, measure);
      // A changed row or an unmount cannot leave an old version queued for a later commit.
      return () => {
        if (pendingMeasures.current.get(node) === measure) pendingMeasures.current.delete(node);
      };
    },
    [reportDrawn],
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
        (changes ??= new Map()).set(id, entry);
      }
      return changes ? current.with(changes) : current;
    });
  }, []);
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
  foldRide.current ??= new FoldRide({
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
  });
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
            else if (
              rode ||
              followingRef.current ||
              targets.some(heightFoldInFlight) ||
              foldHolding(foldAnchor.current) ||
              inSight(ref.current, targets)
            ) {
              for (let pass = 0; pass < 3; pass += 1) {
                if (!changesDrawn(drawnRef.current, pendingDrawn.current)) {
                  pendingDrawn.current = new Map();
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
        (changes ??= new Map()).set(id, undefined);
        changedDrawn.current.add(id);
      }
      return changes ? current.with(changes) : current;
    });
  }, [chatLook.minimal]);
  const didOpenAtLatest = useRef(false);
  /// The sends this chat's view has taken in (`sends`): a new one puts the view at the latest message.
  const seenSends = useRef(sends);
  /// A prompt was sent before the chat opened (while its tail still fits): it opens at the latest
  /// message, not at the reader's old place.
  const sentBeforeOpen = useRef(false);
  /// Until when rows that come move the followed view on a send's glide (`followGlide.sent`): the
  /// sent prompt's row and its reply's first rows can land a commit or two after the send itself.
  const sendRiseUntil = useRef(Number.NEGATIVE_INFINITY);
  // Under the scrollbar fade (the host theme sets it, applyPaneTheme), the scrollbar fades in and
  // out with the scrolling marks (scrollers.ts).
  useEffect(() => (ref.current ? followShownScrollerFade(ref.current) : undefined), []);
  // Read aloud speaks one of this chat's answers: moving to another session (or closing the
  // transcript) stops it, so it neither talks over the next chat nor says Stop reading on return.
  useEffect(() => () => stopReadingAloud(), [sessionId]);
  // A cold open's rows fade in on the first frame that draws them, before that frame paints.
  const fadedOpen = useRef<number | undefined>(undefined);
  /// The chat switch motion's arm, read once per transcript (a changed arm applies on reload).
  const [switchArm] = useState(() => experimentArm(chatSwitchMotion));
  /// The fade running on this transcript. The transcript stays mounted across a switch, so a fade
  /// ends with the chat it was for: a cached chat opened mid-fade shows whole on its first frame,
  /// not under the last chat's fade, and a transcript that unmounts leaves none running.
  const openFade = useRef<Animation | undefined>(undefined);
  useLayoutEffect(
    () => () => {
      openFade.current?.cancel();
      openFade.current = undefined;
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
  useLayoutEffect(() => {
    if (coldOpen === undefined || rows.length === 0 || fadedOpen.current === coldOpen) return;
    fadedOpen.current = coldOpen;
    openFade.current?.cancel();
    // A switch under a chat switch motion (chatSwitch.ts) is drawn by its own play instead.
    openFade.current = switchPending.current ? undefined : fadeInOpenedChat(ref.current);
    onColdOpenShown?.(coldOpen);
  }, [coldOpen, rows.length, onColdOpenShown]);
  const previousSession = useRef(sessionId);
  // A layout effect: the first measure lands before the first paint, so a mounted transcript (a page
  // load, a new chat's first send, back from Harnesses) never draws a frame at a guessed size.
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    /// This transcript's box as last measured (`shown` below compares the box on show with it).
    const box = { height: -1, width: -1 };
    const measure = (resized: boolean) => {
      box.height = node.clientHeight;
      box.width = node.offsetWidth;
      // A box not laid out yet (hidden, 0 high) keeps the last height rather than showing no rows.
      if (resized || node.clientHeight > 0) setHeight(node.clientHeight);
      // The column's width is the scroller's with its scrollbar's lane (`lane`). Measured as the
      // box past the content width, never below 0, so a box with no layout box (jsdom) keeps its
      // content width.
      const nextLane = Math.max(0, node.offsetWidth - node.clientWidth);
      setWidth(node.clientWidth + nextLane);
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
      flushSync(() => measure(true));
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
      flushSync(() => measure(true));
    };
    doc.addEventListener("visibilitychange", shown);
    return () => {
      observer.disconnect();
      doc.removeEventListener("visibilitychange", shown);
    };
  }, [noteQueue]);
  const previousLayout = useRef<PlacedLayout | null>(null);
  const previousRows = useRef<readonly AcpmuxRow[]>(rows);
  const previousViewport = useRef({ height, width, dockSpace, dockCard });
  /// The room kept under the last row (`room` below) as of the last placement pass.
  const heldRoom = useRef(dockRoom);
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
      Math.abs(foldBase.current - dockTrayRef.current) > 0.5 || Math.abs(cardBase.current - dockCardRef.current) > 0.5;
    foldBase.current = dockTrayRef.current;
    cardBase.current = dockCardRef.current;
    trayToggled.current = false;
    if (!held && Math.abs(heldRoom.current - dockRoomRef.current) <= 0.5) return;
    heldRoom.current = dockRoomRef.current;
    flushSync(roomTaken);
  }, []);
  const thread = useRef<HTMLDivElement>(null);
  /// A turn's end folds its work in one motion (turnEndFold.ts): the rows drawn when it ended are
  /// read here, in the render that ends it, before its rows replace them; the fold plays once they
  /// are placed (the layout effect after the placement pass). It reads in render because the
  /// commit replaces those rows: by any effect they are gone. Only within one chat: another chat
  /// shown in their place is a switch, which draws whole on its first frame, never a fold.
  const turnEndCapture = useRef<TurnEndCapture | undefined>(undefined);
  const turnEnd = useRef<TurnEndFold | undefined>(undefined);
  if (sameChat && endsTurn(rowsBefore, rows))
    turnEndCapture.current = captureTurnEnd(thread.current, ref.current, rows, sessionId);
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
    /// its own (Show all lines, Details): the thread slides instead.
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
  /// Shrinks the kept room to the view's end at `node`'s offset, and lets it go once nothing holds
  /// it (no fold in flight, the rows reach the view's end). O(1): a read of the offset and a compare.
  /// Lets the kept room go: a send or Jump to latest heads for the rows' own end. `now` commits it
  /// before the caller reads the layout (Jump to latest's target).
  const dropFoldRoom = useCallback((now = false) => {
    if (!foldRoomRef.current) return;
    foldRoomRef.current = 0;
    if (now) flushSync(() => setFoldRoom(0));
    else setFoldRoom(0);
  }, []);
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
  /// lands at the end. A view still following the latest row moves its own offset to the end until
  /// the hold's first pass lets go of it, so nothing counts until then.
  const releaseFoldHold = (node: HTMLElement): boolean => {
    const left = holdTop.current;
    if (
      !foldAnchor.current ||
      followingRef.current ||
      bottomStackFold.current ||
      left === undefined ||
      Math.abs(node.scrollTop - left) <= FOLLOW_BOTTOM_DEADBAND_PX ||
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
    const cache = measurementSession.current === sessionId ? measurementCache.current : new Map();
    const lookChanged = measuredLook.current !== chatLook || measuredView.current !== attachmentView;
    measuredLook.current = chatLook;
    measuredView.current = attachmentView;
    const fresh = rowHeights.current.registry !== registry || measurementSession.current !== sessionId || lookChanged;
    if (rowHeights.current.registry !== registry || lookChanged)
      rowHeights.current = { registry, heights: new WeakMap() };
    const rowWidth = scaledRowWidth;
    const last = lastEstimate.current;
    const layout = layoutConversation(
      rows,
      rowWidth,
      cache,
      (row, measureWidth) => registry[rowKind(row)]?.measure?.(row, measureWidth),
      measurementSession.current === sessionId ? rowHeights.current.heights : undefined,
      !fresh && last && last.width === rowWidth && last.sessionId === sessionId ? last : undefined,
      sessionId,
    );
    lastEstimate.current = { rows, layout, width: rowWidth, sessionId };
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [rows, registry, sessionId, chatLook, attachmentView, scaledRowWidth]);
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
            last && kept > 0 ? { layout: last.layout, kept, from: rowsKept, changed: changedAt } : undefined,
            placedOrigin,
          );
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
      first: last?.first ?? 0,
      last: last?.last ?? 0,
      held: last?.held ?? [],
    };
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
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
  ]);
  // A chat held whole keeps each prompt's measured place (transcriptHeights.ts), so the next open on
  // its tail holds exactly the older history's room. In idle time, once the rows stop changing: one
  // pass over the rows per placement that settles, never per frame.
  useEffect(() => {
    if (canLoadOlder || !sessionId || rows.length === 0) return;
    const placed = measured.layout;
    const width = scaledRowWidth;
    const keep = () => {
      const origin = placed.origin ?? 0;
      const prompts: { id: string; top: number }[] = [];
      for (let index = 0; index < rows.length; index += 1)
        if (rows[index]!.kind === "user")
          prompts.push({ id: rows[index]!.id, top: placed.geometry.topAt(index) - origin });
      keepPromptTops(sessionId, width, prompts);
    };
    if (typeof requestIdleCallback === "function") {
      const handle = requestIdleCallback(keep, { timeout: 2000 });
      return () => cancelIdleCallback(handle);
    }
    const timer = setTimeout(keep, 500);
    return () => clearTimeout(timer);
  }, [canLoadOlder, sessionId, rows, measured, scaledRowWidth]);
  // The transcript's height is the rows' as drawn, under the thread's top padding: the rows' total
  // alone placed the latest row's bottom that far under the view.
  // The bottom stack's room follows the rows, so the latest row ends above it.
  // A followed view does not move down when a queued prompt's card leaves the stack: its offset stays,
  // and the room the card leaves stays under the last row for the prompt, which arrives as the latest
  // row a moment later. Dropping it moved the view down a card's height, and the prompt moved it back
  // up. That holds for a stack over the view's foot (its room shrinks) and under it (the view grows).
  // The room goes once rows grow into it, the reader leaves the latest row, the rows rewrap, or after
  // FLOOR_HOLD_MS (a prompt deleted from the queue never arrives), when the view moves down with it.
  const floor = useRef({ height: 0, width, sessionId });
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
  const floorHeight = !kept
    ? 0
    : queueLeft.current && footDropped && previousLayout.current
      ? Math.max(floor.current.height, previousLayout.current.totalHeight + liftedBefore.current - box.height + height)
      : floor.current.height;
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
  const cardAtRest = cardRest.current;
  const cardHeldAt = cardBase.current;
  const lifting = following && !sessionSwitched && openedAtLatest && dockSpace > 0 && dockCard > 0 && cardAtRest > 0;
  const grown = lifting ? Math.min(dockSpace, dockCard - cardAtRest) : 0;
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
  const rowsGrew = measured.layout.totalHeight - (measured.layout.origin ?? 0) - rowsSeen.current;
  const heldBase =
    sessionSwitched || !following || dockSpace <= 0 || !trayToggled.current
      ? dockTray
      : rowsGrew > 0.5
        ? dockTray - Math.min(0, dockTray - foldBase.current + rowsGrew)
        : foldBase.current;
  // Never over the running turn's live line, though: while it is the last row, what the reader opens
  // lies over at most half the line's rest gap, and the rows make room for the rest at once, so the
  // line stays in sight over the stack from the send to the reply (Leo, 2026-11-04: "why does it
  // not display Thinking or anything here???", then "it appears and disappears????", the line under
  // a tray he had opened). What folds still moves no row.
  const lineLast = rows.length > 0 && isLiveLine(rows[rows.length - 1]!);
  const trayBase = lineLast ? Math.max(heldBase, dockTray - restExtra / 2) : heldBase;
  const trayHold = Math.min(dockSpace, dockTray - trayBase);
  const cardHolds = lifting
    ? false
    : overlayDock && following && !sessionSwitched && openedAtLatest && dockSpace > 0 && cardHeldAt > 0;
  const cardHold =
    cardHolds && rowsGrew <= 0.5 ? Math.max(0, Math.min(dockSpace - Math.max(0, trayHold), dockCard - cardHeldAt)) : 0;
  // Over a floating stack the newest line rests the rest gap over it (`dockRoom`, model.ts `restRoom`);
  // a turn footer's action row lies in the band under its reply, so that band comes first
  // (transcriptGrid.ts `restBand`). Docked in flow, the composer gap is the rows' own (`tailGap`).
  const tailGap =
    dockSpace > 0
      ? (measured.layout.restBand ?? 0)
      : (measured.layout.tailGap ?? TRANSCRIPT_COMPOSER_GAP * (measured.layout.scale ?? 1));
  const rowsAtDock = measured.layout.totalHeight + THREAD_TOP + topInset + tailGap + dockRoom - trayHold - cardHold;
  const atDock = Math.max(floorHeight, rowsAtDock);
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
  const floorHolds = floorHeight > rowsAtDock;
  const lifted =
    grown > 0
      ? Math.max(
          0,
          Math.min(
            grown,
            Math.round(atDock - height - FOLLOW_BOTTOM_DEADBAND_PX - 1),
            floorHolds ? liftedBefore.current : grown,
          ),
        )
      : grown;
  const room = sessionSwitched || following ? dockRoom - lifted - trayHold - cardHold : heldRoom.current;
  const rowsHeight = measured.layout.totalHeight + THREAD_TOP + topInset + tailGap + room;
  // The content's end without the room a collapse left (`foldRoom`), which it is released against.
  const rowsEnd = Math.max(floorHeight - lifted, rowsHeight);
  rowsEndRef.current = rowsEnd;
  // The held room less the lift, as the rows' end is: what the reader sees stays where it was drawn.
  // A collapse near the end keeps the content as tall as the view's end (`foldRoom`), so the offset
  // never clamps and the line the reader clicked stays on its pixel.
  const keptEnd = sessionSwitched ? 0 : foldRoom;
  const layout = useMemo(
    () => ({ ...measured.layout, totalHeight: Math.max(rowsEnd, keptEnd) }),
    [measured, rowsEnd, keptEnd],
  );
  // Where the rows draw against where they lay out: the followed offset of this layout against the
  // one the unlifted layout would hold. Negative draws them up, positive down.
  const lift = lifted ? Math.round(Math.max(0, layout.totalHeight - height) - Math.max(0, atDock - height)) : 0;
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
  const placedRows = previousRows.current;
  const scroller = ref.current;
  const followHeld =
    jumpTarget.current !== undefined ||
    (scroller !== null && userScrollIntent(scroller).isHeld() && !followRequest.current?.());
  const projectedTop =
    sessionSwitched || placedBefore === layout
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
  const warm = visibleLayoutRange(
    layout,
    warmTop - height * WARM_VIEWPORTS - warmStep / 2,
    height * (1 + 2 * WARM_VIEWPORTS) + warmStep,
  );
  const scrolledRanges = mergeRowRanges(warm.last < range.first || warm.first > range.last ? ahead : [...ahead, warm]);
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
        mounted.focus();
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
      target.focus({ preventScroll: true });
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
          if (mounted) mounted.focus({ preventScroll: true });
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
          event.shiftKey ? { anchorId: current?.anchorId ?? rows[index]!.id, focusId: nextId } : undefined,
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
  const rowFocus = useCallback((id: string) => setActiveRowId(id), []);
  // Keep the keyboard callback stable across transcript snapshots.
  const rowKeyDownRef = useRef(rowKeyDown);
  rowKeyDownRef.current = rowKeyDown;
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
  useLayoutEffect(() => {
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
      sentBeforeOpen.current = false;
      sendRiseUntil.current = Number.NEGATIVE_INFINITY;
      previousLayout.current = null;
      previousRows.current = rows;
      scrolledTo.current = { top: 0, atLatest: false };
      seenAnchor.current = undefined;
      scrollPacer.current?.cancel();
      stopJump();
      stopBottomStackFold();
      setScrollAt(0, 0);
      follow(true, "session");
    }
    const old = switched ? null : previousLayout.current;
    const oldRows = previousRows.current;
    const node = ref.current;
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
    const heldFrom = node?.scrollTop ?? 0;
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
      const latest = Math.max(0, layout.totalHeight - height);
      settleFollowBottom(node, latest);
      const delta = layoutScrollTop(node) - stack.beforeTop;
      const host = thread.current;
      // A control with no height fold of its own (a shell block's Show all lines, a failure's
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
      stack.pinned = node.scrollTop;
      scrollPacer.current?.cancel();
      setScrollAt(node.scrollTop);
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
      const readerLeft =
        !clamped &&
        (unseenReaderMove || (performance.now() - inputAt <= READER_SCROLL_MS && scrolledTo.current.top - live > 0));
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
        const latest = Math.max(0, layout.totalHeight - viewHeight);
        // Jump to latest's glide in flight heads for the new end instead of snapping there.
        const jumping = jumpTarget.current !== undefined;
        // The shared animation reads the moving end every frame on its original clock.
        // Retargeting a native smooth-scroll here restarted its easing at every measurement.
        if (jumping) jumpTarget.current = latest;
        followDeferred.current = !jumping && userScrollIntent(node).isHeld() && !followRequest.current?.();
        const settled = jumping ? clamped : (!followDeferred.current && settleFollowBottom(node, latest)) || clamped;
        if (settled) followTrace.set(latest);
        // The rise this pass took, eased on screen (followGlide.ts): the same rows, the reply's
        // new line landing in the room the live line keeps under it. Anything else (a row that came
        // or went, a resize, a fall) moves at once, as before.
        // In layout coordinates: the sub-pixel origin a settle keeps (scrollCoordinates.ts) moves the
        // rows on screen too, so a rise that only re-rounds the physical offset is no rise.
        const box = previousViewport.current;
        const rose = layoutScrollTop(node) - (scrolledTo.current.top - previousOrigin);
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
        const cardCleared = dockCard < box.dockCard && box.dockSpace - dockSpace <= box.dockCard - dockCard + 0.5;
        const dockMoved = box.dockSpace !== dockSpace && !((sendWindow || cardCleared) && dockSpace < box.dockSpace);
        const now = performance.now();
        if (unmeasured || box.height !== height || box.width !== width || (!chasing && box.dockSpace !== dockSpace)) {
          resizedAt.current = now;
          stopFollowMotion();
        }
        const resizing = now - resizedAt.current < MOTION_MS.standard;
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
          if (folding && draining && !jumping && !bottomStacking && !heightFoldPlaying() && !resizing) {
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
          } else if (foldRiding && !resizing) {
            // The fold playing on: nothing noted, and a chase still landing lands on its own.
            chaseAnchor.current = undefined;
          } else if (riding || resizing) {
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
          } else if (lineLeft) {
            // What the pass also brought (the reply's next revealed line) joins the trail first, and
            // the landing takes it home with the rest at no more than a line a frame.
            chaseDrainUntil.current = now + StreamReveal.finishMs;
            chaseFollow(node, layout, rows, Number.POSITIVE_INFINITY, false);
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
            const below = held ? room : sentRows ? Number.POSITIVE_INFINITY : room + CHASE_UNDER_STACK_PX;
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
            const atOnce = dockMoved || !live || stepped;
            // A row that came above the live line (not the reply's own growth) holds back up to the
            // trail bound, while the live line glides under it (followChase CHASE_ARRIVAL_HOLD_LINES).
            // The arrived row's room often lands a pass later (its measured height), so the passes
            // within ARRIVAL_PASS_MS of it count too.
            if (arrivedAtTail(oldRows, rows)) arrivedAt.current = now;
            const arrived = now - arrivedAt.current < ARRIVAL_PASS_MS;
            tailAnchor = chaseAnchor.current?.id;
            chaseFollow(node, layout, rows, below, atOnce, held, arrived);
            tailGlides = !atOnce && followChase.current?.arm !== "instant";
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
        const nextTop = preserveScrollAnchorTop({
          oldLayout: old,
          newLayout: layout,
          oldRows,
          newRows: rows,
          liveTop: logicalTop,
          anchorTop: logicalTop,
          folds: foldRide.current?.handedFolds(oldRows, drawnRef.current),
        });
        if (nextTop !== undefined && (clamped || nextTop !== logicalTop)) {
          writeAnchorScrollTop(node, nextTop);
          // Keep React's rendered offset in the same frame as the anchor correction. Otherwise a
          // rounded DOM offset arrives through scroll later and can briefly show Jump to latest.
          scrollPacer.current?.cancel();
          setScrollAt(node.scrollTop, 0);
        }
      }
    }
    // Runs on height too: rows that fit and then overflow on a height-only shrink keep the same memoized layout.
    if (!didOpenAtLatest.current && node) {
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
        if (at < 0) node.scrollTop = top;
        else writeAnchorScrollTop(node, top);
        // A send made a tail that fit overflow (Leo, 2026-11-04: "from partially empty"): the
        // thread is drawn back by the rise and slides up on the send's glide, the prompt rising out
        // from behind the composer, instead of the whole chat moving up a row in one frame.
        // The send's own effect runs after this pass, so a send in this commit counts here too.
        const sentHere = sentBeforeOpen.current || sends !== seenSends.current;
        if (sentHere && at < 0 && node.scrollTop - before > 0.5) {
          if (chasing) followChase.current?.shift(thread.current, before - node.scrollTop);
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
    tailGlide.current?.place(
      thread.current,
      tailGlides && chasing,
      tailAnchor,
      chasing && followingRef.current,
      pinLive ? LIVE_THINKING : undefined,
      carry,
    );
    refreshPinned(thread.current);
    finishCarry(thread.current, carry, (px) => {
      const style = thread.current ? getComputedStyle(thread.current) : undefined;
      const floor = cssTimeMs(style?.getPropertyValue("--agent-motion-arrive") ?? "") ?? MOTION_MS.quick;
      return { ms: floor > 0 ? arrivalStepMs(px, 1, floor) : 0, easing: ARRIVAL_EASE };
    });
    previousLayout.current = layout;
    previousRows.current = rows;
    // The rows a fold ride moved are placed where they showed: its hand-over is spent.
    foldRide.current?.takeHanded(drawnRef.current);
    previousViewport.current = { height, width, dockSpace, dockCard };
    // With the composer's growth, which is room again once the view stops following.
    heldRoom.current = room + lifted + cardHold;
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
    floor.current = { height: holding ? floorHeight : 0, width, sessionId };
    if (!holding && !queueLeft.current) heldFor.current.clear();
    if (node && node.clientHeight > 0 && height > 0 && didOpenAtLatest.current) {
      scrolledTo.current = { top: node.scrollTop, atLatest: followingRef.current };
      seenAnchor.current = restingAnchor(layoutScrollTop(node), scrolledTo.current.atLatest, layout, rows);
    }
    followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);
    // The minimap's band reads the offset this pass settled on.
    minimapPlaced.current?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- openAt is read once, at the first open
  }, [layout, rows, range.first, height, width, dockSpace, room, lift, sessionId, followResume]);
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
  // Another chat shown, or the transcript unmounting: a fold still playing ends at once.
  useLayoutEffect(
    () => () => {
      settleTurnEnd(thread.current, turnEnd.current);
      turnEnd.current = undefined;
    },
    [sessionId],
  );
  // What this pass gave the room of the tray's open list (`trayHold`), and the rows it measured.
  useLayoutEffect(() => {
    foldBase.current = trayBase;
    cardBase.current = dockCard - cardHold;
    rowsSeen.current = measured.layout.totalHeight - (measured.layout.origin ?? 0);
    if (Math.abs(trayHold) <= 0.5 && (rowsGrew > 0.5 || !following || sessionSwitched)) trayToggled.current = false;
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
      heldRoom.current = dockRoomRef.current;
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
  const findIndex = findTargetRowId !== undefined ? findRowIndex(rows, findTargetRowId) : -1;
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
  useLayoutEffect(() => {
    findRequest.current = ref.current ? userScrollIntent(ref.current).request() : undefined;
  }, [findTargetRowId, findTargetOccurrence, findQuery]);
  useLayoutEffect(() => {
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
    findMoved(node);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a new target scrolls, not a layout change
  }, [targetKey]);
  // A row the running line's count names scrolls in once the transcript draws it (its fold may
  // open first), as a Find match does.
  const revealIndex = reveal ? findRowIndex(rows, reveal.rowId) : -1;
  const countReveal = useMemo(
    () =>
      reveal && revealIndex >= 0
        ? {
            rowId: rows[revealIndex]!.id,
            card: false,
            needle: "",
            toolId: reveal.toolId,
            repaint: () => {},
          }
        : undefined,
    // eslint-disable-next-line react-hooks/exhaustive-deps -- one reveal per key, once its row is drawn
    [reveal?.key, revealIndex >= 0],
  );
  const rowRequest = useRef<(() => boolean) | undefined>(undefined);
  useLayoutEffect(() => {
    rowRequest.current = ref.current ? userScrollIntent(ref.current).request() : undefined;
  }, [reveal?.key]);
  useLayoutEffect(() => {
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
    scrolledTo.current = { top: node.scrollTop, atLatest: false };
    follow(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a new reveal scrolls, not a layout change
  }, [reveal?.key, revealIndex >= 0]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    if (!findQuery) return clearFindHighlights();
    const current = paintFindHighlights(
      node,
      findQuery,
      findTargetRowId !== undefined && findTargetOccurrence !== undefined && drawnId !== undefined
        ? { rowId: paintedId!, card: inGroup ? false : drawnCard, occurrence: findTargetOccurrence }
        : undefined,
    );
    if (!current || revealing.current !== targetKey || !findRequest.current?.()) return;
    // A match in a closed group is drawn before the group opens (with no size), and it moves as the
    // opened parts and the rows above it measure, so it is kept in view for a moment once drawn.
    if (!revealWindow.current) {
      const opened = (revealWindow.current = ++revealWindows.current);
      const start = performance.now();
      let frames = 0;
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
        if (settled || ++frames >= FIND_REVEAL_MAX_FRAMES) revealing.current = undefined;
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
  /// Lets the room above the loaded rows go when the view is within a viewport of their top with no
  /// page there yet (`roomGone` above). Runs after each placement and on every scroll event.
  const giveRoomNearTop = () => {
    const node = ref.current;
    const room = layout.origin ?? 0;
    const first = rows[0];
    if (!node || !first || !canLoadOlder || room <= 0.5 || !didOpenAtLatest.current || node.clientHeight === 0) return;
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
    anchorNow.current = () => seenAnchor.current;
    return () => {
      anchorNow.current = undefined;
    };
  }, [anchorNow]);
  useEffect(() => {
    if (!inViewNow) return;
    inViewNow.current = () => {
      const node = ref.current;
      if (!node || followingRef.current || node.clientHeight === 0) return null;
      const { layout: placed, rows: shown } = latestLayout.current;
      const view = visibleLayoutRange(placed, layoutScrollTop(node), node.clientHeight, 0);
      return shown.slice(view.first, view.last).map((row) => row.id);
    };
    return () => {
      inViewNow.current = undefined;
    };
  }, [inViewNow]);
  // The reader sent a prompt: the view goes to the latest message before the frame paints, even
  // scrolled up, and follows the prompt's row and its reply in (Leo 2026-10-21). Only a scroll up
  // by the reader lets go of it again.
  useLayoutEffect(() => {
    if (sends === seenSends.current) return;
    seenSends.current = sends;
    // The send's ride and the rows it brings are the motion the full rate is for: never a reason to cap it.
    renderRate.sent(performance.now());
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
    } else stopJump();
    // The room the stack grew while scrolled up is room under the last row again (`room`).
    heldRoom.current = dockRoomRef.current;
    // The placement pass already has the latest estimated total and measured viewport. Reusing
    // those values avoids forcing a style/layout flush from the send effect before the new row
    // paints; the following placement pass reconciles any drawn-height correction. A fractional
    // end is rounded up, as settleFollowBottom does, so WebKit's floor never rests a pixel short.
    clearScrollOrigin(node);
    const latest = Math.max(0, Math.ceil(layout.totalHeight - height - 0.01));
    const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    // The prompt's rows that land in the next commits glide in too (placement pass, `sendRows`).
    sendRiseUntil.current = performance.now() + SEND_RISE_MS;
    // Sent while scrolled up: the view glides down to the latest message on Jump to latest's ride
    // (one viewport at most, its curve and duration) instead of cutting there in one frame, and the
    // prompt's row and reply land on the moving end. Reduce Motion and motion off still cut.
    if (!fromLatest && !reduce) {
      rideToLatest(node, latest, false, false, true);
      followRequest.current = userScrollIntent(node).request();
      follow(true, "send");
    } else {
      const before = node.scrollTop;
      node.scrollTop = latest;
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
      if (chasing) {
        if (fromLatest) chaseFollow(node, layout, rows);
      } else if (fromLatest && top - before > 0.5) followGlide.current?.sent(thread.current, top - before);
    }
    // The kept place is the latest message again: a relaunch opens there.
    if (onAnchor) {
      clearTimeout(anchorTimer.current);
      anchorTimer.current = setTimeout(reportAnchor, SCROLL_ANCHOR_SETTLE_MS);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a new send moves the view
  }, [sends]);
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
  /// The older-history check (below), which every scroll event runs too.
  const checkOlderNow = useRef<() => void>(() => {});
  const handleScroll = (node: HTMLDivElement, immediate = false) => {
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
    const gone = roomGone !== undefined && roomGone.sessionId === sessionId && rows[0]?.id === roomGone.firstId;
    const room = gone ? 0 : (latestLayout.current.layout.origin ?? 0);
    if (room > 0 && layoutScrollTop(node) < room) {
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
      const rise = paidFrom - paidAt;
      setRoomRose((total) => total + rise);
    }
    giveRoomNearTop();
    checkOlderNow.current();
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
      const latest = Math.max(0, layout.totalHeight - node.clientHeight);
      settleFollowBottom(node, latest);
      const resting = node.scrollTop;
      scrolledTo.current = { top: resting, atLatest: true };
      followTrace.set(resting);
      queueScroll(resting, true, immediate);
      return;
    }
    const was = scrolledTo.current;
    if (readerUpPending.current) readerUpPending.current = false;
    const measured = scrollPosition(node, layout.totalHeight);
    // A recent upward input is authoritative even when it moved only a pixel or two. The
    // deadband absorbs layout rounding, but must not turn a real trackpad step into bottom follow.
    const movedUp = next < was.top - 0.5;
    const recentUp = !programmatic && movedUp;
    // Only the reader's own downward scroll input brings following back at the end; the input hold
    // alone (`programmatic`) is any input of the last second, a press or a hover after a lost
    // release too, and a layout change landing at the end inside it is not the reader's.
    const down = readerDown.current;
    const readerMovedDown = down !== undefined && performance.now() - down.at <= READER_SCROLL_MS;
    const readerReachedBottom = !programmatic && readerMovedDown && next > was.top + 0.5 && measured.atLatest;
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
    // The reader's own scroll: where it rests is where they left off (Jump up, jumpUp.ts), and a way
    // back Jump up held is theirs no longer.
    // Jump up's own move (`placeView`) lands inside the press's input hold, so it reads as the
    // reader's: the offsets its glide steps through and the one it lands on are not stops, and it
    // keeps the way back it holds.
    const placed = placedTop.current;
    placedTop.current = undefined;
    if (!programmatic && !placing.current && (placed === undefined || Math.abs(next - placed) > 1)) {
      if (seenAnchor.current) stoppedMark.current = { place: seenAnchor.current, at: Date.now(), why: "stopped" };
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
    const node = ref.current;
    if (!node) return;
    // The shared motion clock emits only from RAF callbacks, after writing scrollTop. Mount
    // the visible rows before that frame paints; native scroll arrives a frame too late.
    const moved = () => motionScroll.current(node, true);
    node.addEventListener(MOTION_SCROLL_EVENT, moved);
    return () => node.removeEventListener(MOTION_SCROLL_EVENT, moved);
  }, []);
  const onScroll = (event: React.UIEvent<HTMLDivElement>) => handleScroll(event.currentTarget);
  // Jump to latest (the button, ChatGPT and Codex style): a smooth scroll to the latest message, then a
  // landing on it, so a reply that grew meanwhile is followed again.
  const jumpToLatest = (focused: boolean, path = "jump") => {
    const node = ref.current;
    if (!node) return;
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
    follow(true, path);
    if (focused) focusComposer?.();
    // cmux's animations off (ui.animations) or the system's Reduce Motion: it lands in one frame, and
    // with no glide in flight nothing aims one again at a moved end.
    const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    // The layout the room just taken committed (flushSync above), not the one this render closed over.
    const target = Math.max(0, latestLayout.current.layout.totalHeight - node.clientHeight);
    stopJump();
    rideToLatest(node, target, reduce, true);
  };
  jumpToLatestRef.current = jumpToLatest;
  /// Jump up (jumpUp.ts): to where the reader left off, holding where the view is; pressed again
  /// (or Esc), back there. The reader asked for this place, so the view stops following the reply.
  /// It glides on Jump to latest's ride (curve, distance duration, move token): a long way skips at
  /// once to one viewport from the place, with those rows mounted before the frame paints, and eases
  /// the rest, so the view never cuts to a far place in one frame nor draws the rows it crosses.
  /// `top` is read each frame: rows that measure on the way move the landing with them. Reduce
  /// Motion and motion off still cut.
  const placeView = (top: () => number) => {
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
  };
  const pressUp = () => {
    const node = ref.current;
    if (!node) return;
    const press = pressJumpUp(jumpBack.current, { top: layoutScrollTop(node), atLatest: followingRef.current });
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
  };
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
  // Another chat: its own places, nothing held from this one.
  useLayoutEffect(() => {
    stoppedMark.current = undefined;
    jumpBack.current = undefined;
    setJumpBackHeld(false);
  }, [sessionId]);
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const intent = userScrollIntent(node);
    const detachIntent = attachUserScrollIntent(node);
    const followIntent = (next: boolean) => followRef.current(next);
    const cancelProgrammatic = (event?: Event) => {
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
      if (event?.type === "pointerdown") {
        pointerY = (event as PointerEvent).clientY;
      } else if (pointer) pointerY = pointer.clientY;
      if (event?.type === "touchstart") touchY = (event as TouchEvent).touches[0]?.clientY;
      else if (touch) touchY = touch.clientY;
      readerAt.current = performance.now();
      // Wheeling on at the top of the loaded rows scrolls nothing while older history pages in: the
      // reader's input, not only its scroll events, keeps the right-hand card held
      // (summary/heldWhileScrolling.ts).
      noteReaderScroll();
      followTrace.input();
      // The reader takes the view: a glide still easing lands where it lays out, and the chase holds
      // where it is drawn, so nothing moves but the reader's own scroll (a snap home moved the rows
      // a frame before the scroll, streaming-parked-still.test.ts). Followed again, it goes on home.
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
      // Release the follow intent synchronously when a reader starts moving up. The browser can
      // deliver the input before its scroll event; a streamed snapshot in that gap must not pin
      // the view back to the bottom. Capture the event so nested rows cannot commit first.
      if (movingUp) followIntent(false);
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
      if (followingRef.current || jumpTarget.current !== undefined) return;
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
      retainScrollOrigin(node, top);
      // A write the scroller did not take (a scroll of its own still easing in), or a chase that is
      // not held after all, keeps the chase drawn where it is and the offset where it was.
      if (Math.abs(layoutScrollTop(node) - top) > 1 || !chase.release(held)) {
        node.scrollTop = physical;
        retainScrollOrigin(node, was);
        return;
      }
      scrolledTo.current = { top: node.scrollTop, atLatest: false };
      scrollPacer.current?.cancel();
      setScrollAt(node.scrollTop, 0);
    };
    const unsubscribeQuiet = intent.subscribeQuiet(() => {
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
    };
    const readerCanceled = (event: Event) => {
      if (event.defaultPrevented && node.contains(event.target as Node)) readerUpPending.current = false;
    };
    const ownerDocument = node.ownerDocument;
    ownerDocument.addEventListener("pointerup", readerReleased, { capture: true });
    ownerDocument.addEventListener("pointercancel", readerReleased, { capture: true });
    ownerDocument.addEventListener("lostpointercapture", readerReleased, { capture: true });
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
      if (findFrame.current !== undefined) cancelAnimationFrame(findFrame.current);
      findFrame.current = undefined;
      ownerDocument.removeEventListener("pointerup", readerReleased, { capture: true });
      ownerDocument.removeEventListener("pointercancel", readerReleased, { capture: true });
      ownerDocument.removeEventListener("lostpointercapture", readerReleased, { capture: true });
      ownerDocument.defaultView?.removeEventListener("blur", readerReleased);
      for (const name of canceledInputs) ownerDocument.removeEventListener(name, readerCanceled);
      node?.removeEventListener("click", holdClicked, { capture: true });
      node?.removeEventListener(ANCHORED_COLLAPSE_EVENT, holdAsked);
      node?.removeEventListener("pointerdown", notePressed, { capture: true });
      for (const name of landingInputs) view?.removeEventListener(name, landRide, { capture: true });
      node?.removeEventListener("pointercancel", dropPressed, { capture: true });
      for (const name of releases) node?.removeEventListener(name, release);
      removeWheel?.();
      gutterRelease.current = undefined;
      gutter?.remove();
    };
  }, [dropFoldRoom, landForReader, startBottomStack, stopBottomStackFold, stopFollowMotion, stopJump]);
  // A turn's footer (TurnFooter) shows for the turn the reader points at: anywhere after its prompt
  // to its footer. Marked on the mounted rows, so a hover renders nothing.
  // The chat's one Retry (turns.ts retryTargetIn, retryPlacement): the reply footer of the person's
  // last prompt, or that prompt where the footer draws none. Its ids, not the scan's object, key the
  // context, so a streamed token redraws no prompt or footer.
  const scannedRetry = useMemo(() => retryTargetIn(rows), [rows]);
  const retryTarget = useMemo(
    () => ({ promptId: scannedRetry.promptId, footerId: scannedRetry.footerId }),
    [scannedRetry.promptId, scannedRetry.footerId],
  );
  const finalFooter = useMemo(() => finalFooterId(rows), [rows]);
  const markTurns = useCallback(() => {
    for (const node of thread.current?.querySelectorAll<HTMLElement>(".acpmux-row") ?? [])
      node.toggleAttribute("data-turn-revealed", node.dataset.rowId === pointedTurn.current);
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
  const checkOlder = () => {
    const node = ref.current;
    if (!canLoadOlder || !onLoadOlder || !node || node.clientHeight === 0) {
      clearTimeout(olderRecheck.current);
      olderRecheck.current = undefined;
      olderAsk.current++;
      olderAsking.current = false;
      olderLoadRequested.current = undefined;
      return;
    }
    // Measured from the loaded rows' top, under the room held for the history above them.
    if (node.scrollTop - (layout.origin ?? 0) >= node.clientHeight * OLDER_AHEAD_VIEWPORTS) {
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
    // A page that lands changes the key in the commit it brings, and the check after it asks for
    // the next. An ask that brought nothing (a read that failed, or one the client dropped) leaves
    // the key as it was: ask once more a moment later, as long as the view is still near the top.
    // At the very top no scroll event comes to ask for it, and a check on every render would ask
    // on every streamed chunk (Leo 2026-10-21: a 720-turn chat stopped paging for good).
    const settled = () => {
      if (ask !== olderAsk.current) return;
      olderAsking.current = false;
      clearTimeout(olderRecheck.current);
      olderRecheck.current = setTimeout(() => {
        if (olderLoadRequested.current !== asked) return;
        olderLoadRequested.current = undefined;
        checkOlderNow.current();
      }, OLDER_RECHECK_MS);
    };
    onLoadOlder().then(settled, settled);
  };
  useLayoutEffect(() => {
    checkOlderNow.current = checkOlder;
  });
  useEffect(() => {
    checkOlderNow.current();
  }, [canLoadOlder, height, onLoadOlder, olderLoadKey, renderScroll.top]);
  useEffect(() => () => clearTimeout(olderRecheck.current), []);
  // A wheel up with the view already at the loaded rows' top moves nothing, so no scroll event says the reader
  // wants more: it asks itself, unless an ask is still out.
  const onWheel = (event: React.WheelEvent<HTMLDivElement>) => {
    const loadedTop = layout.origin ?? 0;
    if (event.deltaY >= 0 || layoutScrollTop(event.currentTarget) > loadedTop + 0.5 || olderAsking.current) return;
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
  // first while it is unread, else the newer of their last prompt and where they last stopped.
  const unreadView = useSyncExternalStore(subscribeUnread, readUnread, readUnread);
  const sinceIndex = sinceKey !== undefined ? indexOfRow(rows, SINCE_DIVIDER, sinceHint) : -1;
  const sinceRow = sinceIndex >= 0 ? rows[sinceIndex] : undefined;
  const ownPrompt = jumpButton ? lastOwnPrompt(rows, promptScan, promptAuthor) : undefined;
  const upTarget = jumpButton
    ? jumpUpTarget(
        sinceRow && unreadPending(sinceKey, unreadView) ? SINCE_DIVIDER : undefined,
        ownPrompt && { place: { rowId: ownPrompt.id, offset: 0 }, at: ownPrompt.at, why: "sent" },
        stoppedMark.current,
      )
    : undefined;
  const upIndex = upTarget ? indexOfRow(rows, upTarget.rowId, jumpUpHint) : -1;
  const upTop = upIndex >= 0 ? layout.geometry.topAt(upIndex) + (upTarget?.offset ?? 0) : undefined;
  const upOff = placeOffView(upTop, { shownTop, height, threadTop: THREAD_TOP, topInset, dockSpace });
  const upShown = jumpButton && jumpUpShown(upOff, jumpBackHeld ? jumpBack.current : undefined);
  const upTopRef = useRef({ top: upTop, place: upTarget });
  upTopRef.current = { top: upTop, place: upTarget };
  // The button's own `shown` (JumpToLatest below), reported once per change so the pane's toast deck
  // moves in the same frame the button starts to fade in or out.
  const jumpVisible = jumpButton && (behind || (needsYou?.elsewhere ?? 0) > 0);
  const jumpShownReport = useRef(onJumpShownChange);
  jumpShownReport.current = onJumpShownChange;
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
  const rest = restingDock.current;
  if (rest.dock !== dock) restingDock.current = { height, sessionId, dock, space: 0 };
  else if (rest.height !== height || rest.sessionId !== sessionId)
    restingDock.current = { height, sessionId, dock, space: dockSpace };
  else if (dockSpace > 0 && (restingDock.current.space <= 0 || dockSpace < restingDock.current.space))
    restingDock.current.space = dockSpace;
  // A stack not measured since it came (the latch's 0) reads as it is now.
  // Below a floating tab row (`topInset`): the rail centers in the view the row leaves (threadMinimap.css).
  // `live` is the stack's top now: the rail's foot and its card stay above it (ThreadMinimap `railBox`).
  const railBox = {
    height: height - topInset,
    foot: height - topInset - (restingDock.current.space || dockSpace),
    live: height - topInset - dockSpace,
  };
  if (renderStart > 0) acpmuxPerf.span("vt.body", performance.now() - renderStart);
  return (
    <ReadOnlyBoundary readOnly={readOnly}>
      <RetryTargetContext.Provider value={retryTarget}>
        <div
          ref={ref}
          className="acpmux-scroll"
          role="feed"
          // A read-only transcript's right-clicks are reported to no host (conversation/messageMenu.ts).
          data-read-only-transcript={readOnly ? "" : undefined}
          // Its place comes back after a web update's reload (reportAnchor, pages/shared/webSwap.ts).
          {...(onAnchor ? { [WEB_SWAP_KEPT_SCROLL]: "kept" } : {})}
          aria-label={t("transcript.label")}
          onScroll={onScroll}
          onWheel={onWheel}
          // Its thin scrollbar stays shown while the chat overflows, as in every agent app, and never
          // flashes as rows arrive or the view follows them (scrollers.ts, Leo 2026-10-21).
          {...{ [SHOWN_SCROLLER_ATTRIBUTE]: "" }}
          // Soft edges (conversation.css): the top once scrolled from the start, the bottom while more
          // lies below. A followed reply has nothing below it, even while its growth outruns the offset.
          // The bottom one takes follow's deadband: a reader resting at the end saw the band above the
          // composer flicker on and off as a row's measure or the stack moved the end by a pixel (Leo,
          // 2026-10-23: "that little bit above composer can flicker").
          data-fade-top={renderScroll.top - origin > 0.5 || undefined}
          data-fade-bottom={fadesBelow(renderFollowing, below) || undefined}
          // Jump to latest stands in that band: the fade reaches past it, so rows (a date line) pass
          // out of sight behind it instead of reading through its glass.
          data-jump-shown={(jumpButton && behind) || undefined}
          // Under the bottom stack: rows there stay out of sight (conversation.css), and focus or Find
          // scroll a row into view above it.
          data-docked={dockSpace > 0 || undefined}
          // A subagent's view keeps its "Subagent of" pill pinned over the top (pinnedPill below): rows
          // pass out of sight under it.
          data-pinned-top={pinnedPill ? "" : undefined}
          // How deep each soft edge draws (threadMinimap/model.ts transcriptFadeReach): none at that end
          // of the chat, deeper the farther the view is from it. Non-inherited (conversation.css), so a
          // scroll restyles the scroller alone.
          style={
            {
              "--acpmux-fade-top-reach": transcriptFadeReach(renderScroll.top - origin),
              "--acpmux-fade-bottom-reach": renderFollowing
                ? 0
                : transcriptFadeReach(below - FOLLOW_BOTTOM_DEADBAND_PX),
              ...(dockSpace > 0 ? { "--acpmux-dock-space": `${dockSpace}px` } : {}),
              ...(pinnedPill ? { "--acpmux-view-top": `${pinAt.pad + topInset + SUBAGENT_OF_HEIGHT}px` } : {}),
            } as React.CSSProperties
          }
        >
          {showMinimap && (
            <ThreadMinimap
              rows={rows}
              earlier={earlier}
              promptCount={promptCount}
              loadThrough={loadThrough}
              loadPromptIndex={loadPromptIndex}
              sessionId={sessionId}
              layout={layout}
              scroller={ref}
              scrollTop={renderScroll.top - origin}
              // Above the room under the last row, so a composer that grows while the reader is scrolled
              // up leaves the map as it was, as it does the scrollbar.
              viewportHeight={height - room}
              // Where the transcript's mask ends the view (conversation.css --acpmux-view-foot): the
              // rail's rows stay above its bottom band.
              foot={height - dockSpace}
              railBox={railBox}
              scrolls={layout.totalHeight - height > 0.5}
              width={paneWidth}
              columnWidth={width}
              placed={minimapPlaced}
              change={rowsChange.current}
              topInset={topInset}
            />
          )}
          {/* The VS Code-style minimap at the right edge (Settings > Agent Chat > VS Code Minimap, off by default). */}
          <ChatMinimap
            // Another chat is another minimap: no canvas, placeholder or scale carried over.
            key={sessionId}
            rows={rows}
            layout={layout}
            scroller={ref}
            viewportHeight={height - room}
            foot={height - dockSpace}
            width={width}
            endReserve={endReserve}
            scrolls={layout.totalHeight - height > 0.5}
            change={rowsChange.current}
          />
          {find?.open && <ChatFindBar find={find} />}
          <TranscriptContext find={countReveal ?? findReveal} sessionId={sessionId}>
            <div
              className="acpmux-spacer"
              // The room held above the loaded rows for older history (conversation/olderReserve.ts).
              data-older-room={layout.origin || undefined}
              // Older history is left to load. The room is not the sign of it: it goes once the reader
              // nears the loaded top with no page there yet (`giveRoomNearTop`), while pages still come.
              data-loads-older={canLoadOlder || undefined}
              style={{
                height: layout.totalHeight,
                width: lane > 0 ? `calc(100% + ${lane}px)` : undefined,
              }}
            >
              <div
                ref={thread}
                className="acpmux-thread"
                style={{ top: `calc(${lift + topInset}px + var(--acpmux-scroll-origin, 0px))` }}
                onPointerOver={(event) => pointAt(event.target)}
                onPointerLeave={() => pointAt(null)}
              >
                {mountedRanges.flatMap(({ first, last }) =>
                  rows.slice(first, last).map((row, index) => {
                    const absoluteIndex = first + index;
                    const next = nextDrawnRow(rows, absoluteIndex);
                    const actions = hasReplyActions(row, next);
                    const kind = rowKind(row);
                    const Component = registry[kind] ?? NoticeRow;
                    const isExpanded = row.foldOpen ?? expanded.has(row.id);
                    const controls =
                      row.kind === WORKED && isExpanded ? disclosureControls(rows, absoluteIndex + 1) : undefined;
                    return (
                      <RowFrame
                        key={`${sessionId ?? ""}:${rowFrameKey(row)}`}
                        row={row}
                        kind={kind}
                        joinsPrevious={
                          (isStepAt(rows, absoluteIndex) && isStepAt(rows, absoluteIndex - 1)) ||
                          isLiveStep(row, prevDrawnRow(rows, absoluteIndex))
                        }
                        joinsNext={isStepAt(rows, absoluteIndex) && isStepAt(rows, absoluteIndex + 1)}
                        opensTurn={opensBackgroundTurn(row, prevDrawnRow(rows, absoluteIndex))}
                        beforeFooter={isBeforeFooter(row, next)}
                        beforeIndicator={
                          next !== undefined && rowMark(row) === MARK_PROMPT && rowMark(next) === MARK_INDICATOR
                        }
                        replyActions={keepsReplyRoom(row, next)}
                        status={statusEdge(row, next, prevDrawnRow(rows, absoluteIndex))}
                        lastFooter={isLastFooter(row, next)}
                        finalFooter={row.id === finalFooter}
                        continuationFooter={isContinuationFooter(row, next)}
                        lastTurn={row.lastTurn === true}
                        index={absoluteIndex}
                        setSize={canLoadOlder ? -1 : rows.length}
                        top={layout.geometry.topAt(absoluteIndex)}
                        gapBelow={absoluteIndex + 1 < rows.length ? layout.geometry.gapAt(absoluteIndex + 1) : 0}
                        rowWidth={scaledRowWidth}
                        expanded={isExpanded}
                        observer={observer}
                        queueDrawn={queueDrawn}
                        // A session switch is a load, not a live arrival. The reset effect runs after
                        // this render, so gate it here as well to avoid a reused row id animating once.
                        enter={!sessionChanged && enteringRows.current.has(rowFrameKey(row))}
                        onEntered={onEntered}
                        loadFade={!sessionChanged && loadFade.current!.fades(row.id)}
                        onLoadFaded={onLoadFaded}
                        older={olderRows.current!.has(row.id) ? olderRows.current : undefined}
                        onOlderShown={onOlderShown}
                        active={effectiveActiveRowId === row.id}
                        selected={selectedRows.has(absoluteIndex)}
                        tabStop={tabStopId === row.id}
                        onFocus={rowFocus}
                        onRowKeyDown={handleRowKeyDown}
                        contentType={Component}
                        controls={controls}
                        onToggleActivity={toggleRow}
                        onOpenDiff={onOpenDiff}
                        githubRepository={githubRepository ?? rowRepositories?.(absoluteIndex)}
                        referenceScope={scopeAt(absoluteIndex)}
                      >
                        <RowContent
                          Component={Component}
                          liveTools={streams}
                          row={row}
                          replyActions={actions}
                          sessionId={sessionId}
                          onToggleActivity={toggleRow}
                          onOpenDiff={onOpenDiff}
                          expanded={isExpanded}
                          controls={controls}
                          githubRepository={githubRepository ?? rowRepositories?.(absoluteIndex)}
                        />
                      </RowFrame>
                    );
                  }),
                )}
              </div>
            </div>
          </TranscriptContext>
        </div>
        {afterLatest && (
          <div
            className="acpmux-transcript-after-latest"
            // The dock is absolute over the stage. Keep an after-latest tray in flow above its
            // measured room so the composer never covers the expansion or its live tail.
            style={dockHeight > 0 ? { marginBottom: dockHeight } : undefined}
          >
            {afterLatest}
          </div>
        )}
        {pinnedPill && (
          // Lucas, 2026-11-06: "the "subagent of ..." text on the subagent page is sticky and always at the
          // top". Outside the scroller, so its soft edge never fades the pill; the row's own slot stays.
          <div className="acpmux-pinned-top" style={{ top: pinAt.top + topInset }}>
            <SubagentOfRow row={pinnedPill} />
          </div>
        )}
        {sinceKey !== undefined && onJumpToSince && sinceRow?.since && (
          // The top-start zone (overlayLayout.ts): what is new arrives where the eye settles, under
          // the clear line and under a pinned "Subagent of" pill.
          <div
            className="acpmux-over-top"
            data-zone="top-start"
            style={{
              top: topZoneOffset({
                clearTop,
                pinnedBottom: pinnedPill ? Math.max(pinAt.top + topInset, clearTop) + SUBAGENT_OF_HEIGHT : undefined,
              }),
            }}
          >
            <UnreadBanner
              mark={sinceKey}
              turns={sinceRow.since.turns}
              // A row's `at` is ms since 1970; a fixture's small `at` is no time to show.
              firstNewAt={(rows[sinceIndex + 1]?.at ?? 0) > 1e12 ? rows[sinceIndex + 1]!.at : undefined}
              onJump={onJumpToSince}
            />
          </div>
        )}
        {jumpButton && <JumpUp shown={upShown} back={jumpBackHeld} onJump={() => pressUp()} lift={dockSpace} />}
        {jumpButton && (
          <JumpToLatest
            // The pill also shows at the latest message while the chats this chat started wait: it cycles to them.
            shown={behind || (needsYou?.elsewhere ?? 0) > 0}
            working={working}
            onJump={(focused) => {
              // One press, one move: to the latest message when this chat's ask waits there (or no
              // ask is open), else straight to the next chat's ask.
              // With no ask open it is Jump to latest, whatever the last render read for `behind`.
              const asks = needsYou?.count ?? 0;
              const here = asks - (needsYou?.elsewhere ?? 0);
              const scroll = asks === 0 || (behind && here > 0);
              if (scroll) jumpToLatest(focused);
              if (needsYou && asks > 0) needsYou.next(scroll);
            }}
            lift={dockSpace}
            needsYou={needsYou}
          />
        )}
      </RetryTargetContext.Provider>
    </ReadOnlyBoundary>
  );
}

const TranscriptViewMemo = React.memo(TranscriptView);
