// The thread minimap, as the Codex desktop app's prompt rail: one 10 px row per user prompt, 16 px in
// from the transcript's left edge and centered on it. Hovering magnifies the rows near the pointer
// like the Dock and, after the app's hover delay (ui/hoverIntent.ts), opens a preview card (the prompt, its bookmark and
// the start of the reply) beside the hovered row. A click scrolls the transcript so the prompt
// lands near the top and flashes its bubble; dragging scrubs; Tab walks the rows. Bookmarks show
// as a dot past the tick, and clicking the dot's spot toggles one. Geometry comes from the
// transcript's layout (`tops`), so nothing here measures a transcript row; the rail reads only its
// own list (during a scrub) and the card's height. Motion is transform only (threadMinimap.css);
// the numbers are in model.ts.
import React, { memo, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { transcriptColumn, type AcpmuxRow, type ConversationLayout } from "../model";
import { useT } from "../i18n";
import { MinimapTick } from "../../../ui/MinimapTick";
import { usePromptMarks } from "./promptMarks";
import { useHoverIntent } from "../../../ui/hoverIntent";
import { animateScroll, highlightBubble, reducedMotion, stopScroll } from "./scrollMotion";
import { BookmarkIcon } from "./BookmarkIcon";
import {
  cardOffset,
  JUMP_CURVE,
  jumpDuration,
  MIN_GUTTER,
  MIN_PROMPTS,
  minimapTurns,
  RAIL_LEFT,
  railHeight,
  ROW_PITCH,
  ROW_WIDTH,
  STEP_CURVE,
  STEP_MS,
  TICK_BOX,
  tickLength,
  tickProgress,
  turnScrollTop,
  visibleTurns,
  type MinimapTurn,
  type MinimapTurns,
} from "./model";

/// How long a step's scroll counts as under way for the next step, so repeats keep stepping.
const STEP_PENDING_MS = STEP_MS + 150;
/// A pointer that moves this far after pressing a row scrubs instead of clicking.
const SCRUB_SLOP = 3;
/// The space left of the rows (`.acpmux-row`'s left).
const gutter = (width: number) => transcriptColumn(width).inset;

type Jump = "click" | "step" | "scrub" | "bookmark";

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
  width,
}: {
  rows: AcpmuxRow[];
  sessionId?: string;
  layout: ConversationLayout;
  scroller: React.RefObject<HTMLElement | null>;
  scrollTop: number;
  viewportHeight: number;
  width: number;
}) {
  const t = useT();
  const marks = usePromptMarks(sessionId);
  const lastTurns = useRef<MinimapTurns | undefined>(undefined);
  const turns = useMemo(() => {
    const next = minimapTurns(rows, sessionId, lastTurns.current);
    lastTurns.current = next;
    return next.turns;
  }, [rows, sessionId]);
  /// The row under the pointer, or the one a scrub is on.
  const [hovered, setHovered] = useState<number | undefined>(undefined);
  /// The row keyboard focus is on.
  const [focused, setFocused] = useState<number | undefined>(undefined);
  /// The row the card shows (it stays while the pointer is in the card).
  const [cardRow, setCardRow] = useState<number | undefined>(undefined);
  // The card's hover intent (ui/hoverIntent.ts), as every hover card's: the first waits the hover
  // delay, then the card follows the pointer from row to row at once, and the rail cools a moment
  // after it goes. Keyboard focus shows it at once.
  const preview = useHoverIntent<"rail">();
  const cardOpen = preview.shown !== null;
  const intend = preview.hover;
  const dismiss = preview.dismiss;
  const [scrubbing, setScrubbing] = useState(false);
  const [reduce, setReduce] = useState(false);
  const [listTop, setListTop] = useState(0);
  const [cardHeight, setCardHeight] = useState(0);
  const rail = useRef<HTMLElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const card = useRef<HTMLDivElement>(null);
  const cardId = useId();
  /// A press is under way: the focus it brings is not keyboard focus.
  const pressing = useRef(false);
  const scrub = useRef<{ pointer: number; y: number; moved: boolean; at?: number } | undefined>(undefined);
  const swallowClick = useRef(false);
  const windowHeight = globalThis.innerHeight || viewportHeight;
  const onScreen = visibleTurns(turns, layout.tops, layout.totalHeight, scrollTop, viewportHeight);
  const shown = turns.length >= MIN_PROMPTS && gutter(width) >= MIN_GUTTER;
  const height = railHeight(turns.length, windowHeight);
  const overflow = turns.length * ROW_PITCH > height;

  /// What the handlers below read: the turns and layout as of the last commit.
  const live = useRef({ turns, tops: layout.tops, total: layout.totalHeight, marks });
  useLayoutEffect(() => {
    live.current = { turns, tops: layout.tops, total: layout.totalHeight, marks };
  });

  /// Scrolls the transcript to turn `index`: smoothly on the measured curve when its row is mounted,
  /// at once when it is not (or under Reduce Motion, or while scrubbing). A click or a bookmark jump
  /// flashes the prompt's bubble where it lands. Returns where the scroll goes.
  const [jump] = useState(() => (index: number, how: Jump): number | undefined => {
    const node = scroller.current;
    const turn = live.current.turns[index];
    if (!node || !turn) return undefined;
    const target = () =>
      Math.min(turnScrollTop(turn, live.current.tops), Math.max(0, live.current.total - node.clientHeight));
    const row = mountedRow(node, turn.id);
    const to = target();
    if (how === "scrub" || !row || reducedMotion()) {
      stopScroll(node);
      node.scrollTop = to;
    } else if (how === "step") animateScroll(node, target, STEP_MS, STEP_CURVE);
    else animateScroll(node, target, jumpDuration(to - node.scrollTop), JUMP_CURVE);
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
    const pending = { target: undefined as number | undefined, until: 0 };
    /// Where the reader is: an earlier step's landing while its scroll is under way, else the view.
    const from = (node: HTMLElement) =>
      pending.target !== undefined && performance.now() < pending.until && Math.abs(node.scrollTop - pending.target) > 1
        ? pending.target
        : node.scrollTop;
    /// From the turn being read (the last whose landing is at or above the view's top): forward
    /// goes to the next match after it; back to its own prompt when that is above the view and
    /// matches, else to the match before it.
    const target = (by: -1 | 1, matches: (index: number) => boolean) => {
      const node = scroller.current;
      const { turns: all, tops, total } = live.current;
      if (!node || !all.length) return undefined;
      const top = Math.min(from(node), Math.max(0, total - node.clientHeight));
      let reading = 0;
      for (let index = 0; index < all.length; index += 1)
        if (turnScrollTop(all[index]!, tops) <= top + 1) reading = index;
      const start = by > 0 || turnScrollTop(all[reading]!, tops) >= top - 1 ? reading + by : reading;
      for (let index = start; index >= 0 && index < all.length; index += by) if (matches(index)) return index;
      return undefined;
    };
    const go = (index: number | undefined, how: Jump) => {
      if (index === undefined) return;
      const to = jump(index, how);
      if (to === undefined) return;
      pending.target = to;
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
      pending.target = undefined;
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
  useLayoutEffect(() => {
    const node = card.current;
    if (showCard && node) setCardHeight(node.offsetHeight);
  }, [showCard, cardTurn]);

  // A rail longer than its room keeps the first prompt on screen in view while the reader scrolls.
  useLayoutEffect(() => {
    const node = list.current;
    if (!node || !overflow || hovered !== undefined || focused !== undefined) return;
    const rowTop = onScreen.first * ROW_PITCH;
    if (rowTop >= node.scrollTop && rowTop + ROW_PITCH <= node.scrollTop + height) return;
    node.scrollTop = Math.max(0, rowTop - height / 3);
    setListTop(node.scrollTop);
  }, [onScreen.first, overflow, height, hovered, focused]);

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
  const railTop = Math.round((viewportHeight - height) / 2);
  const active = hovered ?? focused;
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
        style={{ left: RAIL_LEFT, top: railTop, width: ROW_WIDTH, height }}
        data-hovering={hovered !== undefined || undefined}
        data-scrubbing={scrubbing || undefined}
        data-reduce={reduce || undefined}
        onPointerLeave={(event) => {
          if (scrub.current?.moved) return;
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
          data-fade-top={listTop > 0 || undefined}
          data-fade-bottom={(overflow && listTop + height < turns.length * ROW_PITCH - 1) || undefined}
          onScroll={(event) => setListTop(event.currentTarget.scrollTop)}
          onPointerDown={(event) => {
            if (event.button !== 0 || event.pointerType === "touch") return;
            pressing.current = true;
            swallowClick.current = false;
            scrub.current = { pointer: event.pointerId, y: event.clientY, moved: false };
          }}
          onPointerMove={(event) => {
            const state = scrub.current;
            if (!state) return;
            if (!state.moved) {
              if (Math.abs(event.clientY - state.y) < SCRUB_SLOP) return;
              state.moved = true;
              setScrubbing(true);
              // Captured only once it is a drag, so a plain click still lands on its row.
              event.currentTarget.setPointerCapture?.(state.pointer);
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
          {turns.map((turn, index) => (
            <Tick
              key={turn.key}
              index={index}
              last={turns.length - 1}
              progress={hovered !== undefined ? tickProgress(index - hovered) : index === focused ? 1 : 0}
              active={index === active}
              current={index >= onScreen.first && index <= onScreen.last}
              marked={marks.has(turn)}
              describedBy={showCard && cardRow === index ? cardId : undefined}
              label={t(marks.has(turn) ? "minimap.tickBookmarked" : "minimap.tick", {
                index: index + 1,
                count: turns.length,
                prompt: turn.prompt,
              })}
              actions={actions}
            />
          ))}
        </div>
      </nav>
      {showCard && (
        <div
          ref={card}
          id={cardId}
          className="acpmux-minimap__card"
          style={{ transform: `translate3d(${RAIL_LEFT + ROW_WIDTH}px, ${cardTop}px, 0)` }}
          onPointerLeave={(event) => {
            // Back onto the rail keeps it (its row takes over); anywhere else it goes.
            if (!within(rail.current, event.relatedTarget)) intend(null);
          }}
        >
          <div className="acpmux-minimap__title">
            <span className="acpmux-minimap__prompt">{cardTurn.prompt}</span>
            {marks.can(cardTurn) && (
              <button
                type="button"
                className="acpmux-minimap__bookmark"
                aria-pressed={cardMarked}
                aria-label={t(cardMarked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
                title={t(cardMarked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
                onClick={() => marks.toggle(cardTurn)}
              >
                <BookmarkIcon filled={cardMarked} />
              </button>
            )}
          </div>
          {cardTurn.reply.length > 0 && (
            <div className="acpmux-minimap__reply">
              {cardTurn.reply.map((block, blockIndex) => (
                <p key={blockIndex} className={block.kind === "item" ? "acpmux-minimap__item" : undefined}>
                  {block.spans.map((span, spanIndex) =>
                    span.bold ? <strong key={spanIndex}>{span.text}</strong> : span.text,
                  )}
                </p>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

type TickActions = {
  enter(index: number): void;
  focus(index: number): void;
  blur(index: number): void;
  escape(): void;
  click(index: number, target: EventTarget): void;
};

/// One prompt's row: a 10 px by 36 px button with its tick and, past the tick, the bookmark dot.
const Tick = memo(function Tick({
  index,
  last,
  progress,
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
  active: boolean;
  current: boolean;
  marked: boolean;
  describedBy?: string;
  label: string;
  actions: TickActions;
}) {
  const length = tickLength(progress);
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
      <span className="acpmux-minimap__dot" style={{ transform: `translateX(${length}px)` }} />
      <span className="acpmux-minimap__dot-hit" data-dot-hit="" />
    </MinimapTick>
  );
});
