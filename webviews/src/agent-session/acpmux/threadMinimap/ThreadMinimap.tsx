// The thread minimap, as the Codex desktop app's prompt rail: one 10 px row per user prompt, pinned
// to the pane's left edge with a spacing-token inset. Hovering magnifies the rows near the pointer
// like the Dock and, on the same frame (CARD_DELAY), opens a preview card (the prompt, its bookmark and
// the start of the reply) beside the hovered row. A click scrolls the transcript so the prompt
// lands near the top and flashes its bubble; dragging scrubs; Tab walks the rows. Bookmarks show
// as a dot past the tick, and the row's right spot toggles one. Geometry comes from the
// transcript's layout (`tops`), so nothing here measures a transcript row; the rail reads only its
// own list (during a scrub) and the card's height. Motion is transform only (threadMinimap.css);
// the numbers are in model.ts.
import React, { memo, useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { type AcpmuxRow, type ConversationLayout } from "../model";
import { useT } from "../i18n";
import { layoutScrollTop, physicalScrollTop } from "../conversation/scrollCoordinates";
import { MinimapTick } from "../../../ui/MinimapTick";
import { useRailPlacement } from "./useRailPlacement";
import { usePromptMarks } from "./promptMarks";
import { HOVER_INTENT, useHoverIntent } from "../../../ui/hoverIntent";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import {
  animateScroll,
  highlightBubble,
  MOTION_SCROLL_EVENT,
  reducedMotion,
  settleScroll,
  stopScroll,
} from "./scrollMotion";
import { RAIL_SCROLLS_ATTRIBUTE } from "./railWheel";
import { PreviewCard } from "./PreviewCard";
import { railEdge, useRailSide } from "./railSide";
import { ContextMenu } from "../../../ui/ContextMenu";
import { ScrollMap } from "./ScrollMap";
import { threadMinimapLayout } from "./layout.experiment";
import { threadMinimapHeight, railHeightConfig } from "./height.experiment";
import { LIT_OPACITY, threadMinimapLit } from "./lit.experiment";
import { MARK_OPACITY, threadMinimapMark } from "./mark.experiment";
import { experimentArm } from "../../../experiments/experiment";
import { tickRanges } from "./tickWindow";
import { useThreadMinimapArm } from "../chatDisplay";
import {
  CARD_DELAY,
  JUMP_CURVE,
  jumpDuration,
  LANDING_OFFSET,
  MIN_PROMPTS,
  minimapTurns,
  railFade,
  railFades,
  railHeight,
  ROW_WIDTH,
  railScrollTop,
  railTop as railTopAt,
  ROW_PITCH,
  SETTLE_FRAMES,
  SHIFT_MS,
  STEP_CURVE,
  STEP_MS,
  TICK_BOX,
  tickLength,
  tickProgress,
  turnScrollTop,
  visibleTurns,
  type MinimapTick as MinimapTickRow,
  type MinimapTurn,
  type MinimapTurns,
  type RowsChange,
} from "./model";

/// How long a step's scroll counts as under way for the next step, so repeats keep stepping.
const STEP_PENDING_MS = STEP_MS + 150;
/// A pointer that moves this far after pressing a row scrubs instead of clicking.
const SCRUB_SLOP = 3;
/// Whether `node` holds focus the keyboard gave it (`:focus-visible`), not a click's.
function keyboardFocused(node: HTMLElement): boolean {
  try {
    return node.matches(":focus-visible");
  } catch {
    return false;
  }
}

type Jump = "click" | "step" | "scrub" | "bookmark";
const EMPTY_EARLIER: readonly AcpmuxRow[] = [];

/// A row the rail's state names: the index the state holds for it, and its prompt's key.
type KeyedRow = { index: number; key: string };

/// The band's first turn at the last commit: its tick (key and row id) and row, where its prompt was
/// in the layout, and where its row drew in the rail; and the first tick's, which older turns change.
type Anchor = { tick: TickRef; first: TickRef; index: number; layoutTop: number; y: number };

/// A tick as the rail's state remembers it: its key and its prompt's row id.
type TickRef = Pick<MinimapTickRow, "key" | "id">;

/// The index of the tick `ref` names in `ticks`, or -1: by its row first, then by its key. The row
/// id holds where older turns arrive (a repeated key can move to an older echo, model.ts ticksOf);
/// the key holds where acpmux's echo replaces this pane's row for a send (a new row, one promptId).
export function tickIndex(ticks: readonly TickRef[], ref: TickRef, from = 0): number {
  for (let index = from; index < ticks.length; index += 1) if (ticks[index]!.id === ref.id) return index;
  for (let index = from; index < ticks.length; index += 1) if (ticks[index]!.key === ref.key) return index;
  return -1;
}

/// How many turns arrived above `anchor`'s since it was taken (undefined: none, or it is gone).
export function prependedBy(anchor: Anchor | undefined, ticks: readonly MinimapTickRow[]): number | undefined {
  if (!anchor || !ticks.length || tickIndex(ticks, anchor.first) === 0) return undefined;
  const at = tickIndex(ticks, anchor.tick, anchor.index);
  return at < 0 ? undefined : at - anchor.index;
}

/// The prompt row's element, when the virtualized transcript has it mounted.
function mountedRow(scroller: HTMLElement, id: string): HTMLElement | undefined {
  for (const node of scroller.querySelectorAll<HTMLElement>(".acpmux-row")) if (node.dataset.rowId === id) return node;
  return undefined;
}

/// Whether the pointer went to `to` inside `element` (a leave's `relatedTarget` may be no node: the window, or null).
const within = (element: Element | null, to: EventTarget | null) =>
  !!element && !!to && "nodeType" in to && element.contains(to as Node);

const bubbleOf = (row: HTMLElement | undefined) => row?.querySelector<HTMLElement>(".cv-user__bubble");

export function ThreadMinimap({
  rows,
  earlier = EMPTY_EARLIER,
  loadThrough,
  sessionId,
  layout,
  scroller,
  scrollTop,
  viewportHeight,
  foot,
  scrolls,
  width,
  columnWidth = width,
  placed,
  change,
}: {
  rows: readonly AcpmuxRow[];
  /// The chat's prompts older than `rows` (VirtualTranscript `earlier`): ticks from the first frame.
  earlier?: readonly AcpmuxRow[];
  loadThrough?: (seq: number) => Promise<boolean>;
  sessionId?: string;
  layout: ConversationLayout;
  scroller: React.RefObject<HTMLElement | null>;
  scrollTop: number;
  viewportHeight: number;
  /// Where the transcript's mask ends its view (the bottom stack's top), when it is above
  /// `viewportHeight`: the rail keeps its rows above the mask's bottom band (model.ts railRoom).
  foot?: number;
  /// Whether the transcript scrolls at all (its layout, dock space included, is taller than it).
  scrolls: boolean;
  width: number;
  columnWidth?: number;
  /// The transcript calls what the rail puts here once each commit's placement pass has set its
  /// offset (VirtualTranscript), so the band reads where the transcript put the reader.
  placed?: React.MutableRefObject<(() => void) | undefined>;
  /// Where `rows` first differs from the last snapshot, as the transcript found it, so the rail
  /// reads only the rows from there (model.ts minimapTurns).
  change?: RowsChange;
}) {
  const t = useT();
  const earlierRows = earlier;
  /// The full-height map (ScrollMap.tsx), the compact Codex rail below, or none (`off`: the turn
  /// steps below still run), read once per pane. The Chat Minimap setting
  /// (`agentPane.display.minimap`) wins when set, live.
  const [experiment] = useState(() => experimentArm(threadMinimapLayout));
  const [heightArm] = useState(() => experimentArm(threadMinimapHeight));
  const arm = useThreadMinimapArm() ?? experiment;
  /// How bright the prompts on screen draw (lit.experiment.ts), read once per pane.
  const [lit] = useState(() => LIT_OPACITY[experimentArm(threadMinimapLit)]);
  /// How bright a bookmarked prompt draws at rest (mark.experiment.ts), read once per pane.
  const [mark] = useState(() => MARK_OPACITY[experimentArm(threadMinimapMark)]);
  const full = arm === "full";
  const marks = usePromptMarks(sessionId);
  /// The turns of the last commit: the next render reads from them and leaves them as they are, so
  /// a render React drops before it commits changes nothing (#24058 review round 6).
  const lastTurns = useRef<MinimapTurns | undefined>(undefined);
  // Every streamed token is a new `rows`: `turns` then changes with the live reply (the card reads
  // it), while `ticks` stays as long as the prompts do, so the tick list below renders nothing.
  const read = useMemo(
    () => minimapTurns(rows, sessionId, lastTurns.current, change, earlierRows),
    [rows, sessionId, change, earlierRows],
  );
  useLayoutEffect(() => {
    lastTurns.current = read;
  }, [read]);
  const { turns, ticks } = read;
  const loadedTurns = read.loadedTurns ?? turns.filter((turn) => turn.index >= 0);
  const loadedStart = read.loadedStart ?? 0;
  /// The row under the pointer, or the one a scrub is on.
  const [hovered, setHovered] = useState<number | undefined>(undefined);
  /// When the pane is too narrow for the rail beside the text, the edge strip can reveal it over the
  /// text. The grace lets a pointer cross from the rail to its preview card without closing it.
  const [railRevealed, setRailRevealed] = useState(false);
  const railHideTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  /// The pointer is on the pane-edge strip: a blur elsewhere must not hide the rail under it, since
  /// a still pointer sends no new enter to reveal it again.
  const overStrip = useRef(false);
  const revealRail = () => {
    if (railHideTimer.current !== undefined) {
      clearTimeout(railHideTimer.current);
      railHideTimer.current = undefined;
    }
    setRailRevealed(true);
  };
  // The leave grace is a hover-intent delay off the motion scale (HOVER_INTENT.cardGrace). It fires
  // once, re-entry or focus cancels it, and it is skipped (the rail hides at once) under Reduce
  // Motion or while the page is hidden; the effect below clears it on unmount or a page hide.
  const hideRailAfterGrace = () => {
    if (railHideTimer.current !== undefined) clearTimeout(railHideTimer.current);
    const grace = reducedMotion() || document.hidden ? 0 : HOVER_INTENT.cardGrace;
    railHideTimer.current = setTimeout(() => {
      railHideTimer.current = undefined;
      if (overStrip.current && !document.hidden) return;
      setRailRevealed(false);
      const active = rail.current?.ownerDocument.activeElement;
      const held = rail.current?.contains(active ?? null) || card.current?.contains(active ?? null);
      // Keyboard focus keeps the rail and its card over the text. Focus a click left on a tick does
      // not: the pointer has gone, so the occluded rail hides and its card closes with it.
      if (held && active && !keyboardFocused(active as HTMLElement)) (active as HTMLElement).blur();
      else if (held) return;
      intend(null);
    }, grace);
  };
  /// The row keyboard focus is on.
  const [focused, setFocused] = useState<number | undefined>(undefined);
  /// The row the card shows (it stays while the pointer is in the card).
  const [cardRow, setCardRow] = useState<number | undefined>(undefined);
  // The card's hover intent (ui/hoverIntent.ts) with no dwell (CARD_DELAY): the card shows on the
  // frame the pointer reaches a row and follows it from row to row. Keyboard focus shows it at once.
  const preview = useHoverIntent<"rail">({ delay: CARD_DELAY });
  const cardOpen = preview.shown !== null;
  const intend = preview.hover;
  useEffect(() => {
    // A page that hides mid-grace clears the pending timer and settles the rail hidden at once,
    // its card with it, so a later strip hover cannot bring back a stale card.
    const onVisibility = () => {
      if (!document.hidden || railHideTimer.current === undefined) return;
      clearTimeout(railHideTimer.current);
      railHideTimer.current = undefined;
      setRailRevealed(false);
      intend(null);
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  }, [intend]);
  useEffect(
    () => () => {
      if (railHideTimer.current !== undefined) clearTimeout(railHideTimer.current);
    },
    [],
  );
  const dismiss = preview.dismiss;
  const [scrubbing, setScrubbing] = useState(false);
  const [, setBandMoves] = useState(0);
  // Read at mount too, so the ticks' entrance (threadMinimap.css) does not run under the app's gate.
  const [reduce, setReduce] = useState(reducedMotion);
  const [listTop, setListTop] = useState(0);
  /// The list's offset as the rail last set it or its scroll event reported it, so a commit reads no
  /// layout to place the list (reading `scrollTop` right after a commit lays out the whole transcript).
  const listOffset = useRef(0);
  /// A wheel over the rail means the person is browsing its history. Keep their offset until a tick
  /// click takes them back to the transcript; transcript scrolling must not snap the rail beneath them.
  /// Held for the session it was taken in: the transcript is reused across chats, and another chat's
  /// rail follows its own reader from the start.
  const railBrowsing = useRef<{ sessionId?: string } | undefined>(undefined);
  /// A row a key moves focus to that is not drawn yet (tickWindow.ts): drawn on the next commit,
  /// which focuses it.
  const [reveal, setReveal] = useState<number | undefined>(undefined);
  /// The focused, hovered and card rows as of the last commit, each with its prompt's key.
  const keyed = useRef<{ focused?: KeyedRow; hovered?: KeyedRow; card?: KeyedRow }>({});
  /// The prompt key of the tick the page's focus is on, if one is.
  const [domFocus, setDomFocus] = useState<{ sessionId?: string; key: string } | undefined>(undefined);
  const rail = useRef<HTMLElement>(null);
  const list = useRef<HTMLOListElement>(null);
  const card = useRef<HTMLDivElement>(null);
  const cardId = useId();
  /// A press is under way: the focus it brings is not keyboard focus.
  const pressing = useRef(false);
  const scrub = useRef<{ pointer: number; y: number; moved: boolean; at?: number } | undefined>(undefined);
  /// Where the pointer last was over the list (its clientY), while it is on the rail: when the list
  /// scrolls under a still pointer, the hovered row is the one now under it.
  const pointerY = useRef<number | undefined>(undefined);
  const swallowClick = useRef(false);
  const windowHeight = globalThis.innerHeight || viewportHeight;
  /// The scroller's offset as of its last scroll event. The transcript hands `scrollTop` down a
  /// frame or two late (React schedules a scroll's render), so the band of lit rows read it here
  /// instead and follows the reader on the scroll's own frame.
  /// Another session's transcript starts from its own offset.
  const domTop = useRef<{ sessionId?: string; top: number } | undefined>(undefined);
  /// The band's first turn as of the last commit (the older-turns effect below keeps it).
  const anchor = useRef<Anchor | undefined>(undefined);
  /// When a commit adds turns above the anchored one, the rows' offsets move by how far its prompt
  /// did, and the transcript restores the reader's place only after that commit, with a scroll. Until
  /// that scroll arrives, the band reads the offset as it will be.
  const restoring = useRef<{ from: number; by: number } | undefined>(undefined);
  const added = prependedBy(anchor.current, ticks);
  const anchored = added === undefined ? undefined : turns[anchor.current!.index + added];
  const seen = domTop.current && domTop.current.sessionId === sessionId ? domTop.current.top : undefined;
  if (anchored && seen !== undefined)
    restoring.current = { from: seen, by: (layout.tops[anchored.index] ?? 0) - anchor.current!.layoutTop };
  const shift = restoring.current && restoring.current.from === seen ? restoring.current.by : 0;
  const top = (seen ?? scrollTop) + shift;
  const onScreen = visibleTurns(turns, layout.tops, layout.totalHeight, top, viewportHeight, loadedStart);
  /// Never shorter than the prompts on screen, so the band always draws whole (model.ts railHeight).
  const height = railHeight(
    turns.length,
    windowHeight,
    viewportHeight,
    foot,
    onScreen.last - onScreen.first + 1,
    railHeightConfig(heightArm),
  );
  // The compact rail is pinned to the pane's left edge. It never follows the centered transcript or
  // Session Info's chat shift; only its own pane-width inset changes.
  // Its edge (railSide.ts): on the right it is the same rail mirrored, `placement.left` in from the
  // pane's right edge (past the VS Code minimap's `reserve` when that is on), with its hover strip and
  // card on that side.
  const { side, menu } = useRailSide();
  const placement = useRailPlacement(scroller, width, columnWidth, side);
  const edge = placement.reserve + placement.left;
  const [cardFocus, setCardFocus] = useState(false);
  const railVisible = !placement.overlapsText || railRevealed || domFocus !== undefined || cardFocus || scrubbing;
  const railWidth = placement.overlapsText && railVisible ? ROW_WIDTH : placement.width;
  // The occluded rail's hover strip reaches the text edge and no further, so clicks, links and
  // selection drags on the text stay the text's; it keeps at least the pane-edge inset at any width.
  const stripWidth = Math.max(placement.left, Math.min(placement.left + placement.width, placement.gutter));
  // A view with no room for a single row (the transcript is at least 96 px tall) draws no rail. At
  // narrow widths the pane-edge strip stays live even while the visual rail is occluded by text.
  const shown = arm === "compact" && turns.length >= MIN_PROMPTS && height >= ROW_PITCH;
  const overflow = turns.length * ROW_PITCH > height;

  /// What the handlers below read: the turns and layout as of the last commit.
  const live = useRef({
    turns,
    ticks,
    tops: layout.tops,
    total: layout.totalHeight,
    marks,
    viewportHeight,
    onScreen,
    sessionId,
    shown,
    hovered,
    loadedStart,
  });
  useLayoutEffect(() => {
    live.current = {
      turns,
      ticks,
      tops: layout.tops,
      total: layout.totalHeight,
      marks,
      viewportHeight,
      onScreen,
      sessionId,
      shown,
      hovered,
      loadedStart,
    };
  });

  // The band follows the scroll on its own frame: a scroll that moves it renders the rail at once
  // (only the rows whose state changed draw again); one that does not renders nothing.
  useEffect(() => {
    const node = scroller.current;
    if (!node) return;
    const scrolled = () => {
      const { turns: all, tops, total, viewportHeight: height, onScreen: drawn, sessionId: session } = live.current;
      domTop.current = { sessionId: session, top: layoutScrollTop(node) };
      restoring.current = undefined;
      // The full-height map moves its own bar; no band to draw here.
      if (!live.current.shown) return;
      const next = visibleTurns(all, tops, total, layoutScrollTop(node), height, live.current.loadedStart);
      // Synchronously: a scroll event or a motion's frame callback is outside React's batch, which
      // would draw the band after this frame paints. Only a scroll that moves the band renders.
      if (next.first !== drawn.first || next.last !== drawn.last) flushSync(() => setBandMoves((count) => count + 1));
    };
    // Captured, so it runs before the transcript's own scroll handler and that one's render finds the
    // band already drawn. A wheel glide or jump (scrollMotion.ts) writes the offset in a frame
    // callback, whose scroll event comes a frame late: it announces its write in that frame too.
    node.addEventListener("scroll", scrolled, { capture: true, passive: true });
    node.addEventListener(MOTION_SCROLL_EVENT, scrolled);
    return () => {
      node.removeEventListener("scroll", scrolled, { capture: true });
      node.removeEventListener(MOTION_SCROLL_EVENT, scrolled);
    };
  }, [scroller]);

  // The wheel over a list that scrolls itself is the rail's (railWheel.ts). This capture listener on
  // the list stops it before the transcript's bubbling wheel listeners (its glide, fold release, older
  // pages, the step reader below); the transcript's capture listeners on its ancestor scroller run
  // first and skip it themselves (railOwnsWheel). The browser still scrolls the list natively.
  useEffect(() => {
    const node = list.current;
    if (!node || !overflow) return;
    const wheel = (event: WheelEvent) => {
      railBrowsing.current = { sessionId: live.current.sessionId };
      event.stopPropagation();
    };
    node.addEventListener("wheel", wheel, { capture: true, passive: true });
    return () => node.removeEventListener("wheel", wheel, { capture: true });
  }, [overflow, shown]);

  // The transcript's placement pass (its layout effect, after this rail's) has set the offset for
  // this commit: restored the reader's place over older turns, or left it. The band reads that
  // offset before the frame paints, whether or not a scroll event follows.
  useLayoutEffect(() => {
    if (!placed) return;
    placed.current = () => {
      const node = scroller.current;
      if (!node) return;
      const { turns: all, tops, total, viewportHeight: height, onScreen: drawn, sessionId: session } = live.current;
      domTop.current = { sessionId: session, top: layoutScrollTop(node) };
      restoring.current = undefined;
      if (!live.current.shown) return;
      const next = visibleTurns(all, tops, total, layoutScrollTop(node), height, live.current.loadedStart);
      if (next.first !== drawn.first || next.last !== drawn.last) setBandMoves((count) => count + 1);
    };
    return () => {
      placed.current = undefined;
    };
  }, [placed, scroller]);

  // A jump still under way belongs to the chat it started in: another chat in the reused scroller,
  // or the rail going away, ends it. In the commit itself, before the jump's next frame can run.
  useLayoutEffect(() => {
    const node = scroller.current;
    return () => {
      if (node) stopScroll(node);
    };
  }, [scroller, sessionId]);

  /// Scrolls the transcript to turn `index`. A click or a scrub lands at once, in the frame of the
  /// input (Leo, 2026-10-29: "faster scrttoll"; a jump the reader asked for by pointing needs no
  /// travel to read, and the 200-400 ms glide was the slowest step of a rail click). A Previous or
  /// Next Turn step and a bookmark jump glide on the measured curve when the row is mounted. Any jump
  /// lands at once when its row is not drawn, or under Reduce Motion. It lands the top of the
  /// prompt's row (its sent images, else its bubble) LANDING_OFFSET down. A click or a bookmark jump
  /// flashes the prompt's bubble where it lands. Returns where the scroll goes.
  /// A click on a prompt not loaded yet: the jump that runs once its row is held, in that chat.
  const waiting = useRef<{ id: string; how: Jump; sessionId?: string } | undefined>(undefined);
  const loadThroughNow = useRef(loadThrough);
  loadThroughNow.current = loadThrough;
  const [jump] = useState(() => (index: number, how: Jump): number | undefined => {
    const node = scroller.current;
    const turn = live.current.turns[index];
    if (!node || !turn) return undefined;
    if (turn.index < 0) {
      const seq = Number(turn.id.slice(turn.id.indexOf("-") + 1));
      const load = loadThroughNow.current;
      if (!Number.isFinite(seq) || !load) return undefined;
      const pending = { id: turn.id, how, sessionId: live.current.sessionId };
      waiting.current = pending;
      // A read that stopped short of the prompt (no history left, a failed page) drops the jump, so
      // it never fires later on a page the reader asked for nothing.
      const drop = () => {
        if (waiting.current === pending) waiting.current = undefined;
      };
      void load(seq).then((held) => {
        if (!held) drop();
      }, drop);
      return undefined;
    }
    const target = () =>
      physicalScrollTop(
        node,
        Math.min(turnScrollTop(turn, live.current.tops), Math.max(0, live.current.total - node.clientHeight)),
      );
    let row = mountedRow(node, turn.id);
    // Keep the mounted target through the settle. Virtualization may replace it, so a stale
    // element is looked up again; ordinary frames never scan all mounted transcript rows.
    const targetRow = () => {
      if (!row || !node.contains(row) || row.dataset.rowId !== turn.id) row = mountedRow(node, turn.id);
      return row;
    };
    const to = target();
    // The layout's tops are estimates for rows never drawn, so a long jump can land off its mark
    // once the rows it reaches mount and measure (297 px off for 50 turns up). Where it lands is then
    // corrected from the prompt's row itself, frame by frame, until it holds. The row's top, not the
    // bubble's: a prompt's sent images draw above its bubble, and a settle on the bubble slid the
    // landing down past them (Leo, 2026-10-25: "it jumps all the way up to the attachment area ...
    // Then it just sends me back down to the, like, only the text area"). The row's top does not
    // move when its images load and it grows; that growth goes below it.
    const settle = () =>
      settleScroll(
        node,
        () => {
          const box = targetRow()?.getBoundingClientRect();
          // Not drawn yet, or no layout to measure (a hidden pane).
          if (!box || box.height === 0) return undefined;
          return box.top - node.getBoundingClientRect().top - LANDING_OFFSET;
        },
        SETTLE_FRAMES,
        { explicit: true },
      );
    if (how === "scrub" || how === "click" || !row || reducedMotion()) {
      stopScroll(node);
      node.scrollTop = to;
      if (how !== "scrub") settle();
    } else if (how === "step") animateScroll(node, target, STEP_MS, STEP_CURVE, settle, undefined, { explicit: true });
    else
      animateScroll(node, target, jumpDuration(to - node.scrollTop), JUMP_CURVE, settle, undefined, { explicit: true });
    if (how === "click" || how === "bookmark") {
      if (row) highlightBubble(bubbleOf(row));
      // An unmounted row mounts once the transcript draws its new place.
      else requestAnimationFrame(() => requestAnimationFrame(() => highlightBubble(bubbleOf(targetRow()))));
    }
    return to;
  });
  useLayoutEffect(() => {
    const pending = waiting.current;
    if (!pending) return;
    if (pending.sessionId !== sessionId) {
      waiting.current = undefined;
      return;
    }
    const index = turns.findIndex((turn) => turn.id === pending.id && turn.index >= 0);
    if (index < 0) return;
    waiting.current = undefined;
    jump(index, pending.how);
  }, [turns, jump, sessionId]);

  // Previous Turn and Next Turn (the app's Ctrl-Opt-Up and Ctrl-Opt-Down) and Previous and Next
  // Bookmarked Prompt (palette actions) are bridge commands that raise these events. They work
  // while the rail is hidden too (a narrow pane, few prompts).
  useEffect(() => {
    /// An earlier step's turn, by its key (older turns arriving renumber the rows), while its scroll
    /// and landing are under way.
    const pending = { tick: undefined as TickRef | undefined, until: 0 };
    /// From the turn being read (an earlier step's while it is under way, else the last whose
    /// landing is at or above the view's top): forward goes to the next match after it; back to its
    /// own prompt when that is above the view and matches, else to the match before it.
    const target = (by: -1 | 1, matches: (index: number) => boolean) => {
      const node = scroller.current;
      const { turns: all, ticks: keys, tops, total } = live.current;
      if (!node || !all.length) return undefined;
      const stepping =
        pending.tick !== undefined && performance.now() < pending.until ? tickIndex(keys, pending.tick) : -1;
      const top = Math.min(layoutScrollTop(node), Math.max(0, total - node.clientHeight));
      let reading = 0;
      if (stepping >= 0) reading = stepping;
      else
        for (let index = 0; index < all.length; index += 1)
          if (turnScrollTop(all[index]!, tops) <= top + 1) reading = index;
      const start = by > 0 || stepping >= 0 || turnScrollTop(all[reading]!, tops) >= top - 1 ? reading + by : reading;
      for (let index = start; index >= 0 && index < all.length; index += by) if (matches(index)) return index;
      return undefined;
    };
    const go = (index: number | undefined, how: Jump) => {
      if (index === undefined) return;
      const to = jump(index, how);
      if (to === undefined) return;
      const tick = live.current.ticks[index];
      pending.tick = tick && { key: tick.key, id: tick.id };
      pending.until = performance.now() + STEP_PENDING_MS;
    };
    const any = () => true;
    const marked = (index: number) => live.current.marks.has(live.current.turns[index]!);
    const handlers: Array<[string, () => void]> = [
      ["cmux-acpmux-previousTurn", () => go(target(-1, any), "step")],
      ["cmux-acpmux-nextTurn", () => go(target(1, any), "step")],
      ["cmux-acpmux-previousBookmarkedPrompt", () => go(target(-1, marked), "bookmark")],
      ["cmux-acpmux-nextBookmarkedPrompt", () => go(target(1, marked), "bookmark")],
    ];
    // The reader's own scroll ends a pending step.
    const reader = () => {
      pending.tick = undefined;
    };
    const node = scroller.current;
    const inputs = ["wheel", "pointerdown", "touchstart", "keydown"] as const;
    for (const name of inputs) node?.addEventListener(name, reader, { passive: true });
    for (const [name, handler] of handlers) window.addEventListener(name, handler);
    return () => {
      for (const [name, handler] of handlers) window.removeEventListener(name, handler);
      for (const name of inputs) node?.removeEventListener(name, reader);
    };
  }, [scroller, jump]);

  // The card's own height, for centering it on its row and keeping it inside the viewport.
  const cardTurn: MinimapTurn | undefined = cardRow === undefined ? undefined : turns[cardRow];
  const showCard = railVisible && cardOpen && cardTurn !== undefined;
  /// Focus is inside the card (its bookmark button): Escape there closes it, as on a row.
  // A card closed with focus in it (Escape, a click elsewhere) takes no blur: it starts unfocused.
  if (!showCard && cardFocus) setCardFocus(false);
  useEscapeCloses(showCard && cardFocus, dismiss);

  // Older turns that load above the reader (the transcript pages them in as it nears the top) add
  // rows above the band and would move it on screen in one frame: 150 px for a 30-turn page. The
  // band holds where it was instead. A rail that scrolls takes the new rows into its own scroll; one
  // that grows glides back to center from where the band was, over SHIFT_MS (a second page during
  // the glide starts from where the first one has got to). The hovered, focused and scrubbed rows
  // and the card's stay on their prompts. Where the band's first row sits comes from the rail's
  // geometry, so no commit reads layout for it.
  const glide = useRef<Animation | undefined>(undefined);
  const holding = useRef(false);
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- runs after every commit on purpose (the band tracks every frame); its setState calls are guarded by `added`.
  useLayoutEffect(() => {
    const was = anchor.current;
    anchor.current = undefined;
    holding.current = false;
    if (!shown || !turns.length) return;
    const railTop = railTopAt(height, viewportHeight, foot);
    let scrolled = listTop;
    if (added !== undefined && was) {
      holding.current = true;
      const index = was.index + added;
      const node = list.current;
      const shell = rail.current;
      // The hovered, focused and card rows follow their prompts by key (the rows' keys below); a
      // scrub's row follows here.
      if (added > 0 && scrub.current?.at !== undefined) scrub.current.at += added;
      if (node && shell) {
        let moved = railTop + index * ROW_PITCH - scrolled - was.y;
        const room = Math.max(0, turns.length * ROW_PITCH - height);
        const next = Math.max(0, Math.min(room, scrolled + moved));
        if (next !== scrolled) {
          node.scrollTop = next;
          listOffset.current = next;
          moved -= next - scrolled;
          scrolled = next;
          setListTop(next);
        }
        // Where a glide still under way has the rail now.
        let from = 0;
        const running = glide.current;
        if (running && running.playState === "running") {
          from = new DOMMatrixReadOnly(getComputedStyle(shell).transform).f;
          running.cancel();
        }
        glide.current = undefined;
        const start = from - moved;
        if (Math.abs(start) >= 0.5 && typeof shell.animate === "function" && !reducedMotion())
          glide.current = shell.animate([{ transform: `translateY(${start}px)` }, { transform: "translateY(0)" }], {
            duration: SHIFT_MS,
            easing: `cubic-bezier(${STEP_CURVE.join(", ")})`,
          });
      }
    }
    const first = turns[onScreen.first];
    if (first)
      anchor.current = {
        tick: { key: ticks[onScreen.first]!.key, id: ticks[onScreen.first]!.id },
        first: { key: ticks[0]!.key, id: ticks[0]!.id },
        index: onScreen.first,
        layoutTop: layout.tops[first.index] ?? 0,
        y: railTop + onScreen.first * ROW_PITCH - scrolled,
      };
  });

  // A rail longer than its room keeps the whole band (the prompts on screen) in view and clear of
  // its fades while the reader scrolls, and reaches its end with the chat's: at the bottom of the
  // chat the last ticks show lit (railScrollTop). It used to keep only the band's first row in view,
  // so the rows below it, the bottom of the chat among them, could stay under the bottom fade or
  // past the rail's end. It follows with a tick hovered or focused too (#24058 review round 4: it
  // used to stop, so scrolling the chat under a hovered rail took the band out of it): railScrollTop
  // keeps the list where it is while the whole band shows clear of the fades, so the tick under the
  // pointer moves only once the band would leave the rail. Only a scrub, whose pointer is on the
  // row it shows, holds the list.
  /// After the list moved under a pointer that did not (the reader wheels the chat with the pointer
  /// on the rail, or a key focuses a tick past the list's end and the browser scrolls the list to it),
  /// no pointerenter comes, so the magnified row would stay the old one while another sits under the
  /// pointer (#24058 review rounds 5 and 6). The hovered row becomes the one under it now. A scrub
  /// sets its own row from its pointer.
  const followPointer = useCallback((node: HTMLElement) => {
    const over = live.current.hovered;
    const y = pointerY.current;
    if (over === undefined || y === undefined || scrub.current?.moved) return;
    const under = Math.floor((y - node.getBoundingClientRect().top + node.scrollTop) / ROW_PITCH);
    const index = Math.max(0, Math.min(live.current.turns.length - 1, under));
    if (index === over) return;
    setHovered(index);
    setCardRow(index);
  }, []);
  useLayoutEffect(() => {
    const node = list.current;
    // A hidden rail (too little room, too few prompts) unmounts its list, and the next one mounts at
    // its top: the cached offset goes with it, so the new list is placed from 0 like any other.
    if (!node) {
      railBrowsing.current = undefined;
      if (listOffset.current === 0) return;
      listOffset.current = 0;
      setListTop(0);
      return;
    }
    // A list that no longer overflows (another chat, fewer prompts) starts at its top again.
    if (!overflow) {
      railBrowsing.current = undefined;
      if (listOffset.current === 0) return;
      node.scrollTop = 0;
      listOffset.current = 0;
      setListTop(0);
      return;
    }
    // The commit that added older turns placed the list itself, around the band.
    if (scrubbing || holding.current || (railBrowsing.current && railBrowsing.current.sessionId === sessionId)) return;
    railBrowsing.current = undefined;
    const current = listOffset.current;
    const next = railScrollTop({ first: onScreen.first, last: onScreen.last }, turns.length, height, current);
    if (Math.abs(next - current) < 0.5) return;
    node.scrollTop = next;
    // railScrollTop keeps it inside the list's room, so the list takes it as it is.
    listOffset.current = next;
    setListTop(next);
    followPointer(node);
  }, [shown, onScreen.first, onScreen.last, turns.length, overflow, height, scrubbing, followPointer, sessionId]);

  // A key moved focus to a row that was not drawn: it is now, so it takes focus (and the browser
  // scrolls the list to it, whose scroll moves the drawn rows along).
  useLayoutEffect(() => {
    if (reveal === undefined) return;
    setReveal(undefined);
    list.current?.querySelector<HTMLButtonElement>(`[data-tick="${reveal}"]`)?.focus();
  }, [reveal]);

  // The previewed prompt stays lit while the pointer is on its card, as ChatGPT's rail does.
  const active = hovered ?? focused ?? (showCard ? cardRow : undefined);
  /// The band glides only when the scroll moves it (threadMinimap.css): a commit that changes the
  /// active row, the hover or the scrub (the pointer leaving the rail, a key focusing a tick) marks
  /// the rail `data-snap`, so the rows it changes switch at once. The rail's next render that changes
  /// none of these (the scroll's next band move) drops the mark, and its rows glide.
  const pose = `${active ?? ""}|${hovered !== undefined}|${scrubbing}`;
  const committedPose = useRef(pose);
  const snap = pose !== committedPose.current;
  useLayoutEffect(() => {
    committedPose.current = pose;
  });

  /// The rows' actions: stable for the memoized rows, reading the latest state through `live`.
  const actions = useMemo<TickActions>(
    () => ({
      enter(index) {
        if (scrub.current?.moved) return;
        setReduce(reducedMotion());
        setHovered(index);
        setCardRow(index);
        intend("rail");
      },
      focus(index) {
        if (pressing.current) return;
        setReduce(reducedMotion());
        setFocused(index);
        setCardRow(index);
        intend("rail", 0);
      },
      blur(index) {
        setFocused((current) => (current === index ? undefined : current));
      },
      escape() {
        dismiss();
      },
      reveal(index) {
        setReveal(index);
      },
      click(index, target) {
        if (swallowClick.current) {
          swallowClick.current = false;
          return;
        }
        const turn = live.current.turns[index];
        if (!turn) return;
        // A clicked row takes focus, as a clicked button does in Chromium (WebKit focuses none), so
        // Tab goes on from the rail. Like a pointer's focus there, it neither grows the row nor
        // holds the card open.
        const row = target instanceof Element ? target.closest<HTMLElement>("[data-tick]") : null;
        if (row && row.ownerDocument.activeElement !== row) {
          pressing.current = true;
          row.focus({ preventScroll: true });
          pressing.current = false;
        }
        // The bookmark dot's spot past the tick (the row's right end) toggles the mark.
        if (target instanceof Element && target.closest("[data-dot-hit]") && live.current.marks.can(turn)) {
          live.current.marks.toggle(turn);
          return;
        }
        railBrowsing.current = undefined;
        setCardRow(index);
        jump(index, "click");
      },
    }),
    [intend, dismiss, jump],
  );

  /// Each tick's row by its prompt's key, built once per change of the ticks (a new prompt, older
  /// turns, a cut), never per token.
  const rowOf = useMemo(() => new Map(ticks.map((tick, index) => [tick.key, index])), [ticks]);
  /// The focused, hovered and card rows by their prompt's key. Older turns arriving or earlier ones
  /// going renumber every row in the render that changes the ticks, before any effect can: a row the
  /// state still names by the index it had at the last commit is the row its prompt is at now (a
  /// lookup, no search), and the effect below sets the state to it. A row the state changed to since
  /// is itself.
  const resolve = (index: number | undefined, last: KeyedRow | undefined) =>
    index === undefined || !last || last.index !== index ? index : rowOf.get(last.key);
  const held = {
    focused: resolve(focused, keyed.current.focused),
    hovered: resolve(hovered, keyed.current.hovered),
    card: resolve(cardRow, keyed.current.card),
  };
  /// The tick that has the page's focus (a pointer's click focuses one too, without the keyboard's
  /// grow or card), by its prompt's key: it stays drawn wherever the list scrolls.
  /// A focused button that goes (its chat replaced, its prompt cut, the rail hidden) may send no blur:
  /// a key that is no longer a tick of this chat's shown rail holds nothing, and the effect below
  /// drops it, as it does once the page's focus is not in the list at all.
  const domFocusLive = shown && domFocus !== undefined && domFocus.sessionId === sessionId && rowOf.has(domFocus.key);
  const domFocused = domFocusLive ? rowOf.get(domFocus.key) : undefined;
  /// The rows the list draws (tickWindow.ts), the same array while they stay the same, so a render
  /// that moves none (a streamed token) renders no row.
  const drawn = tickRanges(ticks.length, listTop, height, [
    held.focused,
    held.hovered,
    reveal,
    showCard ? held.card : undefined,
    domFocused,
  ]);
  const drawnKey = drawn.join(" ");
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- keyed on the ranges' contents, not the new array.
  const ranges = useMemo(() => drawn, [drawnKey]);
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- runs after every commit on purpose: it keeps the rows' keys as of this commit, and its setState calls run only when the ticks moved a row.
  useLayoutEffect(() => {
    // Reading the page's focus lays nothing out.
    const focusIn = !!list.current && list.current.contains(list.current.ownerDocument.activeElement);
    if (domFocus !== undefined && (!domFocusLive || !focusIn)) setDomFocus(undefined);
    if (held.focused !== focused) setFocused(held.focused);
    if (held.hovered !== hovered) setHovered(held.hovered);
    if (held.card !== cardRow) setCardRow(held.card);
    const at = (index: number | undefined) =>
      index === undefined || !ticks[index] ? undefined : { index, key: ticks[index]!.key };
    keyed.current = { focused: at(held.focused), hovered: at(held.hovered), card: at(held.card) };
  });
  /// The rail going (a short chat, no room): its keyboard tick, hover and card go with it, so the rail
  /// that comes back draws none of them. Only on the change, so a rail that mounts hidden cools nothing.
  const wasShown = useRef(shown);
  useLayoutEffect(() => {
    const went = wasShown.current && !shown;
    wasShown.current = shown;
    if (!went) return;
    setFocused(undefined);
    setHovered(undefined);
    setCardRow(undefined);
    setReveal(undefined);
    dismiss();
  }, [shown, dismiss]);

  if (full)
    return (
      <ScrollMap
        rows={rows}
        turns={loadedTurns}
        layout={layout}
        scroller={scroller}
        viewportHeight={viewportHeight}
        scrolls={scrolls}
        placement={placement}
        marks={marks}
        jump={jump}
      />
    );
  if (!shown) return null;
  const indexAt = (clientY: number) => {
    const node = list.current;
    if (!node) return 0;
    const index = Math.floor((clientY - node.getBoundingClientRect().top + node.scrollTop) / ROW_PITCH);
    return Math.max(0, Math.min(turns.length - 1, index));
  };
  const endScrub = (event: React.PointerEvent<HTMLElement>) => {
    pressing.current = false;
    const state = scrub.current;
    scrub.current = undefined;
    if (!state?.moved) return;
    // The click a drag ends with never jumps. The next press clears it, not a timer: a slow frame
    // can run a timer between the pointerup and its click.
    swallowClick.current = true;
    setScrubbing(false);
    if (event.currentTarget.hasPointerCapture?.(state.pointer))
      event.currentTarget.releasePointerCapture(state.pointer);
  };
  const railTop = railTopAt(height, viewportHeight, foot);
  const fades = railFades(onScreen, turns.length, height, listTop);
  const inTickContent = (event: React.PointerEvent<HTMLElement>, node: HTMLElement) => {
    const y = event.clientY - node.getBoundingClientRect().top + node.scrollTop;
    return y >= 0 && y < turns.length * ROW_PITCH;
  };
  // When the pane cannot fit the compact rail beside the transcript, leave its edge strip live and
  // reveal the rail over the text only while the strip, rail, card or keyboard focus holds it open.
  const magnified = hovered;
  const cardMarked = cardTurn ? marks.has(cardTurn) : false;
  /// The card centers itself on its row and keeps inside the view (PreviewCard `place`).
  const cardCenter = cardRow === undefined ? 0 : railTop + cardRow * ROW_PITCH + ROW_PITCH / 2 - listTop;
  return (
    <div className="acpmux-minimap" style={{ "--acpmux-rail-left": `${placement.left}px` } as React.CSSProperties}>
      {/* Right-clicking the rail (or its narrow-pane strip) moves it to the other edge. */}
      <ContextMenu items={menu}>
        <span
          className="acpmux-minimap__strip"
          aria-hidden="true"
          data-side={side}
          style={{
            ...railEdge(side, placement.reserve),
            top: railTop,
            width: railVisible ? placement.left : stripWidth,
            height,
          }}
          onPointerEnter={() => {
            overStrip.current = true;
            revealRail();
          }}
          onPointerLeave={(event) => {
            overStrip.current = false;
            if (!within(rail.current, event.relatedTarget) && !within(card.current, event.relatedTarget))
              hideRailAfterGrace();
          }}
        />
        <nav
          ref={rail}
          className="acpmux-minimap__rail"
          aria-label={t("minimap.label")}
          data-side={side}
          style={
            {
              ...railEdge(side, edge),
              top: railTop,
              width: railWidth,
              height,
              "--acpmux-minimap-lit": lit,
              "--acpmux-minimap-mark": mark.bar,
              "--acpmux-minimap-mark-dot": mark.dot,
            } as React.CSSProperties
          }
          data-hovering={hovered !== undefined || undefined}
          data-occluded={!railVisible || undefined}
          data-scrubbing={scrubbing || undefined}
          data-reduce={reduce || undefined}
          data-snap={snap || undefined}
          onPointerLeave={(event) => {
            if (scrub.current?.moved) return;
            pointerY.current = undefined;
            setHovered(undefined);
            // Into the card keeps it; anywhere else it goes on this frame.
            if (!within(card.current, event.relatedTarget)) {
              if (placement.overlapsText) hideRailAfterGrace();
              else {
                setRailRevealed(false);
                intend(null);
              }
            }
          }}
          onPointerEnter={revealRail}
          onBlur={(event) => {
            const next = event.relatedTarget as Node | null;
            if (event.currentTarget.contains(next) || card.current?.contains(next)) return;
            if (hovered === undefined) {
              if (placement.overlapsText) hideRailAfterGrace();
              else {
                setRailRevealed(false);
                intend(null);
              }
            }
          }}
        >
          <ol
            ref={list}
            className="acpmux-minimap__list"
            // The edge fades: 2.5rem, a quarter of a short rail, and never over the band (railFades).
            data-fade-top={fades.top || undefined}
            data-fade-bottom={(overflow && fades.bottom) || undefined}
            // A list longer than its room scrolls itself, and the wheel over it is the rail's (railWheel.ts).
            {...(overflow ? { [RAIL_SCROLLS_ATTRIBUTE]: "" } : {})}
            style={
              {
                "--acpmux-minimap-fade": `${railFade(height)}px`,
                // The ticks' entrance staggers down the rows in the rail's room (threadMinimap.css). Each
                // tick keeps its own place from its mount (Tick), so a scroll changes nothing the list's
                // rows inherit: a per-scroll value here restyled every drawn row on every scrolled frame.
                "--acpmux-minimap-rows": Math.max(1, Math.ceil(height / ROW_PITCH)),
              } as React.CSSProperties
            }
            onFocus={(event) => {
              revealRail();
              const tick = (event.target as Element).closest?.<HTMLElement>("[data-tick]");
              const key = tick ? ticks[Number(tick.dataset.tick)]?.key : undefined;
              if (key !== undefined) setDomFocus({ sessionId, key });
            }}
            onBlur={(event) => {
              if (!within(event.currentTarget, event.relatedTarget)) setDomFocus(undefined);
            }}
            onScroll={(event) => {
              listOffset.current = event.currentTarget.scrollTop;
              // Committed in the scroll event, before the frame paints: a scroll is a continuous
              // event, whose update React renders in a task after the frame, so the frame showed the
              // list at its new offset with the rows of the old one (blank at the edge it scrolled
              // toward on a fast wheel, Leo 2026-10-31: "it can flicker and disapper at the edges").
              // The row under a still pointer (and so the card's row) moves in the same commit, so the
              // card never shows its old row at the list's new offset.
              const node = event.currentTarget;
              flushSync(() => {
                setListTop(listOffset.current);
                followPointer(node);
              });
            }}
            onPointerOver={(event) => {
              pointerY.current = event.clientY;
            }}
            onPointerDown={(event) => {
              if (event.button !== 0 || event.pointerType === "touch") return;
              if (!inTickContent(event, event.currentTarget)) return;
              pressing.current = true;
              swallowClick.current = false;
              const state = { pointer: event.pointerId, y: event.clientY, moved: false };
              scrub.current = state;
              // A press released off the rail (before it moved far enough to capture the pointer) sends
              // its pointerup elsewhere: the window sees it bubble (after the list's own, which ends a drag)
              // and ends the press, so a later hover cannot scrub.
              const page = event.currentTarget.ownerDocument.defaultView ?? window;
              const released = () => {
                page.removeEventListener("pointerup", released);
                page.removeEventListener("pointercancel", released);
                if (scrub.current !== state) return;
                scrub.current = undefined;
                pressing.current = false;
                if (state.moved) setScrubbing(false);
              };
              page.addEventListener("pointerup", released);
              page.addEventListener("pointercancel", released);
            }}
            onPointerMove={(event) => {
              pointerY.current = event.clientY;
              const state = scrub.current;
              if (!inTickContent(event, event.currentTarget)) {
                if (!state?.moved) {
                  setHovered(undefined);
                  setCardRow(undefined);
                  if (!within(card.current, event.relatedTarget)) intend(null);
                }
                return;
              }
              if (!state) return;
              if (!state.moved) {
                if (Math.abs(event.clientY - state.y) < SCRUB_SLOP) return;
                state.moved = true;
                setScrubbing(true);
                // Captured only once it is a drag, so a plain click still lands on its row.
                // A synthetic pointer (the gallery's, a test's) has no capture to take.
                try {
                  event.currentTarget.setPointerCapture?.(state.pointer);
                } catch {}
              }
              const index = indexAt(event.clientY);
              if (index === state.at) return;
              state.at = index;
              setHovered(index);
              setCardRow(index);
              jump(index, "scrub");
            }}
            onPointerUp={endScrub}
            onPointerCancel={endScrub}
          >
            <TickList
              ticks={ticks}
              sessionId={sessionId}
              hovered={magnified}
              focused={focused}
              active={active}
              first={onScreen.first}
              last={onScreen.last}
              listFirst={Math.floor(listTop / ROW_PITCH)}
              described={showCard ? cardRow : undefined}
              cardId={cardId}
              actions={actions}
              ranges={ranges}
            />
          </ol>
        </nav>
      </ContextMenu>
      {showCard && (
        <PreviewCard
          ref={card}
          id={cardId}
          side={side}
          // From the rail's edge of the pane to its far side: card.left == rail.right on the left,
          // card.right == rail.left on the right.
          x={edge + railWidth}
          railLeft={placement.left}
          center={cardCenter}
          viewportHeight={viewportHeight}
          // Out of the scroller: its edge mask would keep the card's blur from the rows (PreviewCard.tsx).
          scroller={scroller.current}
          prompt={cardTurn.prompt}
          reply={cardTurn.reply}
          metadata={cardTurn.metadata}
          bookmark={marks.can(cardTurn) ? { marked: cardMarked, toggle: () => marks.toggle(cardTurn) } : undefined}
          onPointerLeave={(event) => {
            // Back onto the rail keeps it (its row takes over); anywhere else it goes.
            if (!within(rail.current, event.relatedTarget)) {
              if (placement.overlapsText) hideRailAfterGrace();
              else {
                setRailRevealed(false);
                intend(null);
              }
            }
          }}
          onPointerEnter={revealRail}
          onFocus={() => {
            revealRail();
            setCardFocus(true);
          }}
          onBlur={(event) => {
            // Focus leaving the card for anywhere but the rail closes it, as leaving the rail does.
            const next = event.relatedTarget;
            if (within(event.currentTarget, next)) return;
            setCardFocus(false);
            if (within(rail.current, next)) return;
            if (hovered === undefined) {
              if (placement.overlapsText) hideRailAfterGrace();
              else {
                setRailRevealed(false);
                intend(null);
              }
            }
          }}
        />
      )}
    </div>
  );
}

/// The rail's rows, one per prompt. Memoized on what they show: a render of the rail that changes
/// none of these (a token streaming into the live reply, a scroll that keeps the band) renders no
/// row, so the rail's work per token does not grow with the chat.
const TickList = memo(function TickList({
  ticks,
  sessionId,
  hovered,
  focused,
  active,
  first,
  last,
  listFirst,
  described,
  cardId,
  actions,
  ranges,
}: {
  ticks: readonly MinimapTickRow[];
  sessionId: string | undefined;
  /// The row the magnify centers on (the hovered one, or a narrow rail's held card's).
  hovered: number | undefined;
  focused: number | undefined;
  active: number | undefined;
  /// The band: the prompts on screen.
  first: number;
  last: number;
  /// The first row in the list's view: a tick's entrance place counts from it (Tick `place`). It
  /// moves with the list's scroll, as `ranges` does, so it renders the list no more often.
  listFirst: number;
  /// The row the open card describes.
  described: number | undefined;
  cardId: string;
  actions: TickActions;
  /// The rows to draw (tickWindow.ts); spacers stand in for the rest.
  ranges: ReadonlyArray<readonly [number, number]>;
}) {
  const t = useT();
  const marks = usePromptMarks(sessionId);
  // An entrance belongs to a logical prompt, not each virtualized DOM mount. Only the first
  // visible set and prompts appended later enter. Prepending history introduces no animation.
  // ticks stays identical during streaming; only a changed prompt list scans for its old tail.
  const committed = useRef<
    | {
        sessionId?: string;
        ticks: readonly MinimapTickRow[];
        pending: Set<string>;
      }
    | undefined
  >(undefined);
  let entrance = committed.current;
  if (!entrance || entrance.sessionId !== sessionId || entrance.ticks !== ticks) {
    const initial = !entrance || entrance.sessionId !== sessionId;
    const tail = initial ? undefined : entrance!.ticks.at(-1)?.key;
    const after = tail === undefined ? -1 : ticks.findIndex((tick) => tick.key === tail);
    const pending = new Set(initial ? [] : entrance!.pending);
    if (initial) {
      for (const [from, to] of ranges) for (let index = from; index < to; index++) pending.add(ticks[index]!.key);
    } else if (after >= 0 || entrance!.ticks.length === 0) {
      for (let index = after + 1; index < ticks.length; index++) pending.add(ticks[index]!.key);
    }
    entrance = { sessionId, ticks, pending };
  }
  const entering = entrance;
  useLayoutEffect(() => {
    committed.current = entering;
    for (const [from, to] of ranges)
      for (let index = from; index < to; index++) entering.pending.delete(ticks[index]!.key);
  });
  const drawn: React.ReactNode[] = [];
  let next = 0;
  for (const [from, to] of ranges) {
    if (from > next) drawn.push(<Spacer key={`gap-${next}`} rows={from - next} />);
    for (let index = from; index < to; index += 1) drawn.push(tickAt(index));
    next = to;
  }
  if (ticks.length > next) drawn.push(<Spacer key={`gap-${next}`} rows={ticks.length - next} />);
  return drawn;

  function tickAt(index: number) {
    const tick = ticks[index]!;
    // A list item that names its place among every prompt, drawn or not; it draws no box.
    return (
      <li key={tick.key} className="acpmux-minimap__entry" aria-posinset={index + 1} aria-setsize={ticks.length}>
        <Tick
          entering={entering.pending.has(tick.key)}
          index={index}
          place={index - listFirst}
          last={ticks.length - 1}
          progress={hovered !== undefined ? tickProgress(index - hovered) : index === focused ? 1 : 0}
          active={index === active}
          current={index >= first && index <= last}
          marked={marks.has(tick)}
          describedBy={described === index ? cardId : undefined}
          label={t(marks.has(tick) ? "minimap.tickBookmarked" : "minimap.tick", {
            index: index + 1,
            count: ticks.length,
            prompt: tick.prompt,
          })}
          actions={actions}
        />
      </li>
    );
  }
});

/// The rows not drawn, as one block as tall as they are.
function Spacer({ rows }: { rows: number }) {
  return <li className="acpmux-minimap__gap" aria-hidden style={{ height: rows * ROW_PITCH }} />;
}

type TickActions = {
  enter(index: number): void;
  focus(index: number): void;
  blur(index: number): void;
  escape(): void;
  /// Moves focus to a row that is not drawn.
  reveal(index: number): void;
  click(index: number, target: EventTarget): void;
};

/// One prompt's row: a 10 px by 36 px button with its tick and, when marked, the bookmark dot.
const Tick = memo(function Tick({
  entering,
  index,
  place,
  last,
  progress,
  active,
  current,
  marked,
  describedBy,
  label,
  actions,
}: {
  entering: boolean;
  index: number;
  /// Its row's place in the list's view when it mounted, for its entrance stagger
  /// (threadMinimap.css). Read only at mount, so a scroll re-renders no tick (tickPropsEqual).
  place: number;
  last: number;
  progress: number;
  active: boolean;
  current: boolean;
  marked: boolean;
  describedBy?: string;
  label: string;
  actions: TickActions;
}) {
  // Capture eligibility at mount: consuming it after commit must not cancel this entrance.
  const [enter] = useState(entering);
  const [entrance] = useState(place);
  const length = tickLength(progress);
  return (
    <MinimapTick
      type="button"
      index={index}
      last={last}
      // Every row is a tab stop, as the Codex rail's buttons are.
      active
      data-tick={index}
      data-entering={enter || undefined}
      className="acpmux-minimap__tick"
      data-focus-ring="tick"
      data-tone={active ? "active" : current ? "current" : "rest"}
      data-bookmarked={marked || undefined}
      style={{ "--acpmux-minimap-place": entrance } as React.CSSProperties}
      aria-label={label}
      aria-current={current ? "true" : undefined}
      aria-describedby={describedBy}
      onPointerEnter={() => actions.enter(index)}
      onFocus={() => actions.focus(index)}
      onBlur={() => actions.blur(index)}
      onClick={(event) => actions.click(index, event.target)}
      keyboard={(event) => {
        if (event.key === "Escape") actions.escape();
        const list = event.currentTarget.closest(".acpmux-minimap__list");
        const tickAt = (row: number) => list?.querySelector<HTMLButtonElement>(`[data-tick="${row}"]`);
        // Tab walks every row; a row past the drawn ones is drawn, then focused.
        if (event.key === "Tab" && !event.altKey && !event.metaKey && !event.ctrlKey) {
          const row = index + (event.shiftKey ? -1 : 1);
          if (row >= 0 && row <= last && !tickAt(row)) {
            event.preventDefault();
            actions.reveal(row);
          }
          return;
        }
        const to =
          event.key === "ArrowUp"
            ? index - 1
            : event.key === "ArrowDown"
              ? index + 1
              : event.key === "Home"
                ? 0
                : event.key === "End"
                  ? last
                  : undefined;
        if (to === undefined) return;
        const row = Math.max(0, Math.min(last, to));
        const node = tickAt(row);
        if (node) node.focus();
        else actions.reveal(row);
      }}
    >
      <span className="acpmux-minimap__bar" style={{ transform: `scaleX(${length / TICK_BOX})` }} />
      {marked && <span className="acpmux-minimap__dot" style={{ transform: `translateX(${length}px)` }} />}
      <span className="acpmux-minimap__dot-hit" data-dot-hit="" />
    </MinimapTick>
  );
}, tickPropsEqual);

const MOUNT_ONLY = new Set(["place", "entering"]);

/// A tick's props as `memo` compares them, but for `place` and `entering`, which only its mount reads.
function tickPropsEqual(was: Readonly<Record<string, unknown>>, next: Readonly<Record<string, unknown>>): boolean {
  for (const key in next) if (!MOUNT_ONLY.has(key) && !Object.is(was[key], next[key])) return false;
  for (const key in was) if (!(key in next)) return false;
  return true;
}
