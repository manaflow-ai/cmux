// The thread minimap, as the Codex desktop app's prompt rail: one 10 px row per user prompt, 16 px in
// from the transcript's left edge and centered on it. Hovering magnifies the rows near the pointer
// like the Dock and, after the app's hover delay (ui/hoverIntent.ts), opens a preview card (the prompt, its bookmark and
// the start of the reply) beside the hovered row. A click scrolls the transcript so the prompt
// lands near the top and flashes its bubble; dragging scrubs; Tab walks the rows. Bookmarks show
// as a dot past the tick, and the row's right spot toggles one. Geometry comes from the
// transcript's layout (`tops`), so nothing here measures a transcript row; the rail reads only its
// own list (during a scrub) and the card's height. Motion is transform only (threadMinimap.css);
// the numbers are in model.ts.
import React, { memo, useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { transcriptColumn, type AcpmuxRow, type ConversationLayout } from "../model";
import { useT } from "../i18n";
import { MinimapTick } from "../../../ui/MinimapTick";
import { usePromptMarks } from "./promptMarks";
import { useHoverIntent } from "../../../ui/hoverIntent";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { animateScroll, highlightBubble, reducedMotion, settleScroll, stopScroll } from "./scrollMotion";
import { PreviewCard } from "./PreviewCard";
import { ScrollMap } from "./ScrollMap";
import { threadMinimapLayout } from "./layout.experiment";
import { LIT_OPACITY, threadMinimapLit } from "./lit.experiment";
import { MARK_OPACITY, threadMinimapMark } from "./mark.experiment";
import { experimentArm } from "../../../experiments/experiment";
import {
  CARD_DELAY,
  cardOffset,
  JUMP_CURVE,
  jumpDuration,
  LANDING_OFFSET,
  MIN_PROMPTS,
  minimapTurns,
  NARROW_TICK,
  railFade,
  railFades,
  railHeight,
  railPlacement,
  railScrollTop,
  railTop as railTopAt,
  ROW_PITCH,
  ROW_WIDTH,
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
/// The space left of the rows (`.acpmux-row`'s left).
const gutter = (width: number) => transcriptColumn(width).inset;

type Jump = "click" | "step" | "scrub" | "bookmark";

/// The band's first turn at the last commit: its key and row, where its prompt was in the layout,
/// and where its row drew in the rail; and the first turn's key, which older turns change.
type Anchor = { key: string; firstKey: string; index: number; layoutTop: number; y: number };

/// How many turns arrived above `anchor`'s since it was taken (undefined: none, or it is gone).
function prependedBy(anchor: Anchor | undefined, turns: readonly MinimapTurn[]): number | undefined {
  if (!anchor || !turns.length || turns[0]!.key === anchor.firstKey) return undefined;
  for (let index = anchor.index; index < turns.length; index += 1)
    if (turns[index]!.key === anchor.key) return index - anchor.index;
  return undefined;
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
  sessionId,
  layout,
  scroller,
  scrollTop,
  viewportHeight,
  foot,
  scrolls,
  width,
  placed,
  change,
}: {
  rows: AcpmuxRow[];
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
  /// The transcript calls what the rail puts here once each commit's placement pass has set its
  /// offset (VirtualTranscript), so the band reads where the transcript put the reader.
  placed?: React.MutableRefObject<(() => void) | undefined>;
  /// Where `rows` first differs from the last snapshot, as the transcript found it, so the rail
  /// reads only the rows from there (model.ts minimapTurns).
  change?: RowsChange;
}) {
  const t = useT();
  /// The compact Codex rail below (the wave, the default), the full-height map (ScrollMap.tsx), or
  /// none (`off`: the turn steps below still run), read once per pane.
  const [arm] = useState(() => experimentArm(threadMinimapLayout));
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
  const read = useMemo(() => minimapTurns(rows, sessionId, lastTurns.current, change), [rows, sessionId, change]);
  useLayoutEffect(() => {
    lastTurns.current = read;
  }, [read]);
  const { turns, ticks } = read;
  /// The row under the pointer, or the one a scrub is on.
  const [hovered, setHovered] = useState<number | undefined>(undefined);
  /// The row keyboard focus is on.
  const [focused, setFocused] = useState<number | undefined>(undefined);
  /// The row the card shows (it stays while the pointer is in the card).
  const [cardRow, setCardRow] = useState<number | undefined>(undefined);
  // The card's hover intent (ui/hoverIntent.ts): the first waits Codex's 250 ms (CARD_DELAY), then
  // the card follows the pointer from row to row at once, and the rail cools a moment after it goes.
  // Keyboard focus shows it at once.
  const preview = useHoverIntent<"rail">({ delay: CARD_DELAY });
  const cardOpen = preview.shown !== null;
  const intend = preview.hover;
  const dismiss = preview.dismiss;
  const [scrubbing, setScrubbing] = useState(false);
  const [, setBandMoves] = useState(0);
  // Read at mount too, so the ticks' entrance (threadMinimap.css) does not run under the app's gate.
  const [reduce, setReduce] = useState(reducedMotion);
  const [listTop, setListTop] = useState(0);
  const [cardHeight, setCardHeight] = useState(0);
  const rail = useRef<HTMLElement>(null);
  const list = useRef<HTMLDivElement>(null);
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
  const added = prependedBy(anchor.current, turns);
  const anchored = added === undefined ? undefined : turns[anchor.current!.index + added];
  const seen = domTop.current && domTop.current.sessionId === sessionId ? domTop.current.top : undefined;
  if (anchored && seen !== undefined)
    restoring.current = { from: seen, by: (layout.tops[anchored.index] ?? 0) - anchor.current!.layoutTop };
  const shift = restoring.current && restoring.current.from === seen ? restoring.current.by : 0;
  const top = (seen ?? scrollTop) + shift;
  const onScreen = visibleTurns(turns, layout.tops, layout.totalHeight, top, viewportHeight);
  /// Never shorter than the prompts on screen, so the band always draws whole (model.ts railHeight).
  const height = railHeight(turns.length, windowHeight, viewportHeight, foot, onScreen.last - onScreen.first + 1);
  // A view with no room for a single row (the transcript is at least 96 px tall) draws no rail. A
  // narrow pane draws it too, minimal until the pointer or focus is on it (model.ts railPlacement).
  const shown = arm === "compact" && turns.length >= MIN_PROMPTS && height >= ROW_PITCH;
  const placement = railPlacement(gutter(width));
  const overflow = turns.length * ROW_PITCH > height;

  /// What the handlers below read: the turns and layout as of the last commit.
  const live = useRef({
    turns,
    tops: layout.tops,
    total: layout.totalHeight,
    marks,
    viewportHeight,
    onScreen,
    sessionId,
    shown,
    hovered,
  });
  useLayoutEffect(() => {
    live.current = {
      turns,
      tops: layout.tops,
      total: layout.totalHeight,
      marks,
      viewportHeight,
      onScreen,
      sessionId,
      shown,
      hovered,
    };
  });

  // The band follows the scroll on its own frame: a scroll that moves it renders the rail at once
  // (only the rows whose state changed draw again); one that does not renders nothing.
  useEffect(() => {
    const node = scroller.current;
    if (!node) return;
    const scrolled = () => {
      const { turns: all, tops, total, viewportHeight: height, onScreen: drawn, sessionId: session } = live.current;
      domTop.current = { sessionId: session, top: node.scrollTop };
      restoring.current = undefined;
      // The full-height map moves its own bar; no band to draw here.
      if (!live.current.shown) return;
      const next = visibleTurns(all, tops, total, node.scrollTop, height);
      if (next.first !== drawn.first || next.last !== drawn.last) setBandMoves((count) => count + 1);
    };
    // Captured, so it runs before the transcript's own scroll handler and that one's render finds the
    // band already drawn.
    node.addEventListener("scroll", scrolled, { capture: true, passive: true });
    return () => node.removeEventListener("scroll", scrolled, { capture: true });
  }, [scroller]);

  // The transcript's placement pass (its layout effect, after this rail's) has set the offset for
  // this commit: restored the reader's place over older turns, or left it. The band reads that
  // offset before the frame paints, whether or not a scroll event follows.
  useLayoutEffect(() => {
    if (!placed) return;
    placed.current = () => {
      const node = scroller.current;
      if (!node) return;
      const { turns: all, tops, total, viewportHeight: height, onScreen: drawn, sessionId: session } = live.current;
      domTop.current = { sessionId: session, top: node.scrollTop };
      restoring.current = undefined;
      if (!live.current.shown) return;
      const next = visibleTurns(all, tops, total, node.scrollTop, height);
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

  /// Scrolls the transcript to turn `index`: smoothly on the measured curve when its row is mounted,
  /// at once when it is not (or under Reduce Motion, or while scrubbing). It lands the top of the
  /// prompt's row (its sent images, else its bubble) LANDING_OFFSET down. A click or a bookmark jump
  /// flashes the prompt's bubble where it lands. Returns where the scroll goes.
  const [jump] = useState(() => (index: number, how: Jump): number | undefined => {
    const node = scroller.current;
    const turn = live.current.turns[index];
    if (!node || !turn) return undefined;
    const target = () =>
      Math.min(turnScrollTop(turn, live.current.tops), Math.max(0, live.current.total - node.clientHeight));
    const row = mountedRow(node, turn.id);
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
          const box = mountedRow(node, turn.id)?.getBoundingClientRect();
          // Not drawn yet, or no layout to measure (a hidden pane).
          if (!box || box.height === 0) return undefined;
          return box.top - node.getBoundingClientRect().top - LANDING_OFFSET;
        },
        SETTLE_FRAMES,
      );
    if (how === "scrub" || !row || reducedMotion()) {
      stopScroll(node);
      node.scrollTop = to;
      if (how !== "scrub") settle();
    } else if (how === "step") animateScroll(node, target, STEP_MS, STEP_CURVE, settle);
    else animateScroll(node, target, jumpDuration(to - node.scrollTop), JUMP_CURVE, settle);
    if (how === "click" || how === "bookmark") {
      if (row) highlightBubble(bubbleOf(row));
      // An unmounted row mounts once the transcript draws its new place.
      else
        requestAnimationFrame(() => requestAnimationFrame(() => highlightBubble(bubbleOf(mountedRow(node, turn.id)))));
    }
    return to;
  });

  // Previous Turn and Next Turn (the app's Ctrl-Opt-Up and Ctrl-Opt-Down) and Previous and Next
  // Bookmarked Prompt (palette actions) are bridge commands that raise these events. They work
  // while the rail is hidden too (a narrow pane, few prompts).
  useEffect(() => {
    /// An earlier step's turn, by its key (older turns arriving renumber the rows), while its scroll
    /// and landing are under way.
    const pending = { key: undefined as string | undefined, until: 0 };
    /// From the turn being read (an earlier step's while it is under way, else the last whose
    /// landing is at or above the view's top): forward goes to the next match after it; back to its
    /// own prompt when that is above the view and matches, else to the match before it.
    const target = (by: -1 | 1, matches: (index: number) => boolean) => {
      const node = scroller.current;
      const { turns: all, tops, total } = live.current;
      if (!node || !all.length) return undefined;
      const stepping =
        pending.key !== undefined && performance.now() < pending.until
          ? all.findIndex((turn) => turn.key === pending.key)
          : -1;
      const top = Math.min(node.scrollTop, Math.max(0, total - node.clientHeight));
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
      pending.key = live.current.turns[index]?.key;
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
      pending.key = undefined;
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
  const showCard = cardOpen && cardTurn !== undefined;
  /// Focus is inside the card (its bookmark button): Escape there closes it, as on a row.
  const [cardFocus, setCardFocus] = useState(false);
  // A card closed with focus in it (Escape, a click elsewhere) takes no blur: it starts unfocused.
  if (!showCard && cardFocus) setCardFocus(false);
  useEscapeCloses(showCard && cardFocus, dismiss);
  useLayoutEffect(() => {
    const node = card.current;
    if (showCard && node) setCardHeight(node.offsetHeight);
  }, [showCard, cardTurn]);

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
      if (added > 0) {
        const by = (row: number | undefined) => (row === undefined ? row : row + added);
        setHovered(by);
        setFocused(by);
        setCardRow(by);
        if (scrub.current?.at !== undefined) scrub.current.at += added;
      }
      if (node && shell) {
        let moved = railTop + index * ROW_PITCH - scrolled - was.y;
        const room = Math.max(0, turns.length * ROW_PITCH - height);
        const next = Math.max(0, Math.min(room, scrolled + moved));
        if (next !== scrolled) {
          node.scrollTop = next;
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
        key: first.key,
        firstKey: turns[0]!.key,
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
    // The commit that added older turns placed the list itself, around the band.
    if (!node || !overflow || scrubbing || holding.current) return;
    const next = railScrollTop({ first: onScreen.first, last: onScreen.last }, turns.length, height, node.scrollTop);
    if (Math.abs(next - node.scrollTop) < 0.5) return;
    node.scrollTop = next;
    setListTop(node.scrollTop);
    followPointer(node);
  }, [onScreen.first, onScreen.last, turns.length, overflow, height, scrubbing, followPointer]);

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
        setCardRow(index);
        jump(index, "click");
      },
    }),
    [intend, dismiss, jump],
  );

  if (full)
    return (
      <ScrollMap
        rows={rows}
        turns={turns}
        layout={layout}
        scroller={scroller}
        viewportHeight={viewportHeight}
        scrolls={scrolls}
        width={width}
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
  // A narrow rail draws the full wave while the pointer, a scrub, keyboard focus or its card is on
  // it, and rests minimal otherwise: shorter ticks in a strip that stops short of the text, so it
  // takes no pointer from the chat. The change is one frame (width, tick length); the ticks' own
  // spring and the backdrop's fade are CSS transitions that end at their target, and neither runs
  // under Reduce Motion (threadMinimap.css).
  const expanded = hovered !== undefined || focused !== undefined || scrubbing || showCard;
  const minimal = placement.narrow && !expanded;
  // The row the magnify centers on: the hovered one, or, in a narrow rail with the pointer gone to
  // the card, the row the card previews, so the card-held state stays the full wave and not 6 px
  // ticks in the 36 px box (#24525 review round 1). The wide rail eases its ticks back to rest
  // there, its previewed prompt lit, as #24058 shipped.
  const magnified = hovered ?? (placement.narrow && showCard ? cardRow : undefined);
  const cardMarked = cardTurn ? marks.has(cardTurn) : false;
  const cardTop =
    cardRow === undefined
      ? 0
      : cardOffset(railTop + cardRow * ROW_PITCH + ROW_PITCH / 2 - listTop, cardHeight, viewportHeight);
  return (
    <div className="acpmux-minimap">
      <nav
        ref={rail}
        className="acpmux-minimap__rail"
        aria-label={t("minimap.label")}
        style={
          {
            left: placement.left,
            top: railTop,
            width: minimal ? placement.restWidth : ROW_WIDTH,
            height,
            "--acpmux-minimap-lit": lit,
            "--acpmux-minimap-mark": mark.bar,
            "--acpmux-minimap-mark-dot": mark.dot,
          } as React.CSSProperties
        }
        data-narrow={placement.narrow || undefined}
        data-expanded={(placement.narrow && expanded) || undefined}
        data-hovering={hovered !== undefined || undefined}
        data-scrubbing={scrubbing || undefined}
        data-reduce={reduce || undefined}
        data-snap={snap || undefined}
        onPointerLeave={(event) => {
          if (scrub.current?.moved) return;
          pointerY.current = undefined;
          setHovered(undefined);
          // Into the card keeps it; anywhere else it goes on this frame.
          if (!within(card.current, event.relatedTarget)) intend(null);
        }}
        onBlur={(event) => {
          const next = event.relatedTarget as Node | null;
          if (event.currentTarget.contains(next) || card.current?.contains(next)) return;
          if (hovered === undefined) intend(null);
        }}
      >
        <div
          ref={list}
          className="acpmux-minimap__list"
          // The edge fades: 2.5rem, a quarter of a short rail, and never over the band (railFades).
          data-fade-top={fades.top || undefined}
          data-fade-bottom={(overflow && fades.bottom) || undefined}
          style={
            {
              "--acpmux-minimap-fade": `${railFade(height)}px`,
              // The ticks' entrance staggers down the rows in the rail's room (threadMinimap.css).
              "--acpmux-minimap-first": Math.floor(listTop / ROW_PITCH),
              "--acpmux-minimap-rows": Math.max(1, Math.ceil(height / ROW_PITCH)),
            } as React.CSSProperties
          }
          onScroll={(event) => {
            setListTop(event.currentTarget.scrollTop);
            followPointer(event.currentTarget);
          }}
          onPointerOver={(event) => {
            pointerY.current = event.clientY;
          }}
          onPointerDown={(event) => {
            if (event.button !== 0 || event.pointerType === "touch") return;
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
            minimal={minimal}
            active={active}
            first={onScreen.first}
            last={onScreen.last}
            described={showCard ? cardRow : undefined}
            cardId={cardId}
            actions={actions}
          />
        </div>
      </nav>
      {showCard && (
        <PreviewCard
          ref={card}
          id={cardId}
          x={placement.left + ROW_WIDTH}
          y={cardTop}
          // Out of the scroller: its edge mask would keep the card's blur from the rows (PreviewCard.tsx).
          scroller={scroller.current}
          prompt={cardTurn.prompt}
          reply={cardTurn.reply}
          bookmark={marks.can(cardTurn) ? { marked: cardMarked, toggle: () => marks.toggle(cardTurn) } : undefined}
          onPointerLeave={(event) => {
            // Back onto the rail keeps it (its row takes over); anywhere else it goes.
            if (!within(rail.current, event.relatedTarget)) intend(null);
          }}
          onFocus={() => setCardFocus(true)}
          onBlur={(event) => {
            // Focus leaving the card for anywhere but the rail closes it, as leaving the rail does.
            const next = event.relatedTarget;
            if (within(event.currentTarget, next)) return;
            setCardFocus(false);
            if (within(rail.current, next)) return;
            if (hovered === undefined) intend(null);
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
  minimal,
  active,
  first,
  last,
  described,
  cardId,
  actions,
}: {
  ticks: readonly MinimapTickRow[];
  sessionId: string | undefined;
  /// The row the magnify centers on (the hovered one, or a narrow rail's held card's).
  hovered: number | undefined;
  focused: number | undefined;
  /// A resting narrow rail (model.ts railPlacement): every tick short.
  minimal: boolean;
  active: number | undefined;
  /// The band: the prompts on screen.
  first: number;
  last: number;
  /// The row the open card describes.
  described: number | undefined;
  cardId: string;
  actions: TickActions;
}) {
  const t = useT();
  const marks = usePromptMarks(sessionId);
  return ticks.map((tick, index) => (
    <Tick
      key={tick.key}
      index={index}
      last={ticks.length - 1}
      progress={hovered !== undefined ? tickProgress(index - hovered) : index === focused ? 1 : 0}
      minimal={minimal}
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
  ));
});

type TickActions = {
  enter(index: number): void;
  focus(index: number): void;
  blur(index: number): void;
  escape(): void;
  click(index: number, target: EventTarget): void;
};

/// One prompt's row: a 10 px by 36 px button with its tick and, when marked, the bookmark dot.
const Tick = memo(function Tick({
  index,
  last,
  progress,
  minimal,
  active,
  current,
  marked,
  describedBy,
  label,
  actions,
}: {
  index: number;
  last: number;
  progress: number;
  /// A resting narrow rail: the short tick (model.ts NARROW_TICK).
  minimal: boolean;
  active: boolean;
  current: boolean;
  marked: boolean;
  describedBy?: string;
  label: string;
  actions: TickActions;
}) {
  const length = minimal ? NARROW_TICK : tickLength(progress);
  return (
    <MinimapTick
      type="button"
      index={index}
      last={last}
      // Every row is a tab stop, as the Codex rail's buttons are.
      active
      data-tick={index}
      className="acpmux-minimap__tick"
      data-tone={active ? "active" : current ? "current" : "rest"}
      data-bookmarked={marked || undefined}
      style={{ "--acpmux-minimap-row": index } as React.CSSProperties}
      aria-label={label}
      aria-current={current ? "true" : undefined}
      aria-describedby={describedBy}
      onPointerEnter={() => actions.enter(index)}
      onFocus={() => actions.focus(index)}
      onBlur={() => actions.blur(index)}
      onClick={(event) => actions.click(index, event.target)}
      keyboard={(event) => {
        if (event.key === "Escape") actions.escape();
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
        if (to !== undefined)
          event.currentTarget.parentElement
            ?.querySelector<HTMLButtonElement>(`[data-tick="${Math.max(0, Math.min(last, to))}"]`)
            ?.focus();
      }}
    >
      <span className="acpmux-minimap__bar" style={{ transform: `scaleX(${length / TICK_BOX})` }} />
      {marked && <span className="acpmux-minimap__dot" style={{ transform: `translateX(${length}px)` }} />}
      <span className="acpmux-minimap__dot-hit" data-dot-hit="" />
    </MinimapTick>
  );
});
