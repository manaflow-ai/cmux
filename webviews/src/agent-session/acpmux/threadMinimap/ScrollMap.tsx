// The full-height thread minimap (the `thread-minimap-layout` experiment's `full` arm): the rail
// spans the transcript's viewport and maps the whole scroll height onto it. Each prompt is a longer,
// brighter tick and a tab stop; each reply a shorter, dimmer one set in a little; a bar shows what
// is on screen and follows the scroll on its own frame without a render. Hovering grows the marks
// near the pointer and, after the hover delay, previews the nearest message beside it. A click on a
// mark jumps to it (a prompt as the compact rail's click does); a click on the track jumps there;
// dragging anywhere scrubs the transcript. Geometry is the transcript's layout (mapGeometry.ts).
import React, { memo, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { transcriptColumn, type AcpmuxRow, type ConversationLayout } from "../model";
import { useT } from "../i18n";
import { MinimapTick } from "../../../ui/MinimapTick";
import { useHoverIntent } from "../../../ui/hoverIntent";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { animateScroll, reducedMotion, stopScroll } from "./scrollMotion";
import { PreviewCard } from "./PreviewCard";
import type { usePromptMarks } from "./promptMarks";
import {
  CARD_DELAY,
  cardOffset,
  JUMP_CURVE,
  jumpDuration,
  LANDING_OFFSET,
  railPlacement,
  replyPreview,
  ROW_WIDTH,
  THREAD_PADDING_TOP,
  TICK_BOX,
  type MinimapTurn,
} from "./model";
import {
  MAP_MARGIN,
  MAP_MIN_PROMPTS,
  mapMarks,
  mapProgress,
  mapThumb,
  markAt,
  marksIn,
  scrollTopAt,
  type MapMark,
} from "./mapGeometry";

/// A pointer that moves this far after pressing scrubs instead of clicking.
const SCRUB_SLOP = 3;
/// The drawn lengths, at rest and fully grown: a prompt's tick, and a reply's.
const USER_LENGTH = [11, TICK_BOX] as const;
const AGENT_LENGTH = [5, 15] as const;

type PromptMarks = ReturnType<typeof usePromptMarks>;
type Press = { pointer: number; y: number; moved: boolean; mark?: string };

const within = (element: Element | null, to: EventTarget | null) =>
  !!element && !!to && "nodeType" in to && element.contains(to as Node);

export function ScrollMap({
  rows,
  turns,
  layout,
  scroller,
  viewportHeight,
  scrolls,
  width,
  marks: bookmarks,
  jump,
}: {
  rows: readonly AcpmuxRow[];
  turns: readonly MinimapTurn[];
  layout: ConversationLayout;
  scroller: React.RefObject<HTMLElement | null>;
  viewportHeight: number;
  scrolls: boolean;
  width: number;
  marks: PromptMarks;
  /// The compact rail's jump to a prompt (ThreadMinimap), so a click lands and flashes the same.
  jump: (turn: number, how: "click" | "scrub") => number | undefined;
}) {
  const t = useT();
  const height = Math.max(0, Math.floor(viewportHeight - 2 * MAP_MARGIN));
  const marks = useMemo(() => mapMarks(rows, turns, layout, height), [rows, turns, layout, height]);
  /// Each mark's place in `marks`, by its row's id. The state below names row ids, not places: which
  /// replies merge moves as a reply streams, and older turns arriving renumber every place and row.
  const keyOf = (mark: MapMark | undefined) => (mark ? (rows[mark.row]?.id ?? `#${mark.row}`) : undefined);
  const byKey = useMemo(
    () => new Map(marks.map((mark, index) => [rows[mark.row]?.id ?? `#${mark.row}`, index])),
    [marks, rows],
  );
  /// The pointer's place on the rail (for the fisheye), and the row id of the mark it is on.
  const [pointerY, setPointerY] = useState<number | undefined>(undefined);
  const [hovered, setHovered] = useState<string | undefined>(undefined);
  const [focused, setFocused] = useState<string | undefined>(undefined);
  const [cardMark, setCardMark] = useState<string | undefined>(undefined);
  const [cardHeight, setCardHeight] = useState(0);
  const [cardFocus, setCardFocus] = useState(false);
  const [scrubbing, setScrubbing] = useState(false);
  const [reduce, setReduce] = useState(false);
  const preview = useHoverIntent<"map">({ delay: CARD_DELAY });
  const intend = preview.hover;
  const dismiss = preview.dismiss;
  const rail = useRef<HTMLElement>(null);
  const thumb = useRef<HTMLDivElement>(null);
  const card = useRef<HTMLDivElement>(null);
  const cardId = useId();
  const press = useRef<Press | undefined>(undefined);
  const placement = railPlacement(transcriptColumn(width).inset);
  const shown = turns.length >= MAP_MIN_PROMPTS && scrolls && height > 4 * MAP_MARGIN && !placement.hidden;

  /// The marks the view bar covers (first and last place in `marks`), for their "current" tone.
  /// The bar moves by style on each scroll frame; this renders only when the covered marks change.
  const [inView, setInView] = useState<{ first: number; last: number } | undefined>(undefined);
  const live = useRef({ height, total: layout.totalHeight, viewportHeight, marks });
  live.current = { height, total: layout.totalHeight, viewportHeight, marks };
  // The bar follows the scroll on the scroll's own frame, by style alone.
  const [placeThumb] = useState(() => () => {
    const node = scroller.current;
    const bar = thumb.current;
    if (!node || !bar) return;
    const { height: rail, total, viewportHeight: view, marks: all } = live.current;
    const at = mapThumb(node.scrollTop, view, total, rail);
    bar.style.transform = `translateY(${at.top}px)`;
    bar.style.height = `${at.height}px`;
    const covered = marksIn(all, at.top, at.top + at.height);
    setInView((was) => (was?.first === covered?.first && was?.last === covered?.last ? was : covered));
  });
  useLayoutEffect(placeThumb);
  useEffect(() => {
    const node = scroller.current;
    if (!node) return;
    node.addEventListener("scroll", placeThumb, { passive: true });
    return () => node.removeEventListener("scroll", placeThumb);
  }, [scroller, placeThumb]);

  const markOf = (key: string | undefined) => (key === undefined ? undefined : marks[byKey.get(key) ?? -1]);
  const cardAt = markOf(cardMark);
  const showCard = preview.shown !== null && cardAt !== undefined;
  if (!showCard && cardFocus) setCardFocus(false);
  useEscapeCloses(showCard && cardFocus, dismiss);
  useLayoutEffect(() => {
    if (showCard && card.current) setCardHeight(card.current.offsetHeight);
  }, [showCard, cardAt]);
  const cardRow = cardAt ? rows[cardAt.row] : undefined;
  const agentReply = useMemo(
    () => (cardAt?.kind === "agent" && cardRow?.text ? replyPreview(cardRow.text) : []),
    [cardAt?.kind, cardRow],
  );

  // What the marks' handlers do: one stable object for the memoized marks, reading this render.
  const handlers = useRef<MarkActions | undefined>(undefined);
  const [actions] = useState<MarkActions>(() => ({
    focus: (row) => handlers.current?.focus(row),
    blur: (row) => handlers.current?.blur(row),
    key: (event, turn) => handlers.current?.key(event, turn),
    activate: (row) => handlers.current?.activate(row),
  }));

  if (!shown) return null;

  const railY = (clientY: number) => clientY - (rail.current?.getBoundingClientRect().top ?? 0);
  /// Scrolls to `key`'s message: a prompt as the compact rail's click, a reply to its top.
  const activate = (key: string) => {
    const mark = markOf(key);
    const node = scroller.current;
    if (!mark || !node) return;
    if (mark.kind === "user" && mark.turn >= 0) {
      jump(mark.turn, "click");
      return;
    }
    const target = () =>
      Math.min(
        Math.max(0, THREAD_PADDING_TOP + (layout.tops[mark.row] ?? 0) - LANDING_OFFSET),
        Math.max(0, layout.totalHeight - node.clientHeight),
      );
    const to = target();
    animateScroll(
      node,
      target,
      reducedMotion() ? 0 : jumpDuration(to - node.scrollTop),
      JUMP_CURVE,
      undefined,
      undefined,
      {
        explicit: true,
      },
    );
  };
  /// Centers the view on rail point `y`: at once while scrubbing, else on the jump's curve.
  const seek = (y: number, smooth: boolean) => {
    const node = scroller.current;
    if (!node) return;
    const to = scrollTopAt(y, height, layout.totalHeight, node.clientHeight);
    if (!smooth || reducedMotion()) {
      stopScroll(node);
      node.scrollTop = to;
    } else
      animateScroll(node, () => to, jumpDuration(to - node.scrollTop), JUMP_CURVE, undefined, undefined, {
        explicit: true,
      });
  };
  const point = (y: number) => {
    const at = keyOf(marks[markAt(marks, y) ?? -1]);
    setPointerY(Math.round(y));
    setHovered(at);
    // A scrub moves the transcript, not the card: it opens again once the drag ends.
    if (at === undefined || press.current?.moved) return;
    setCardMark(at);
    intend("map");
  };
  const endPress = (event: React.PointerEvent<HTMLElement>) => {
    const state = press.current;
    press.current = undefined;
    if (!state) return;
    if (state.moved) {
      setScrubbing(false);
      if (event.currentTarget.hasPointerCapture?.(state.pointer))
        event.currentTarget.releasePointerCapture(state.pointer);
      return;
    }
    if (state.mark !== undefined) activate(state.mark);
    else seek(railY(event.clientY), true);
  };
  // The previewed message stays lit while the pointer is on its card.
  const active = hovered ?? focused ?? (showCard ? cardMark : undefined);
  const focusTick = (turn: number) =>
    rail.current
      ?.querySelector<HTMLButtonElement>(`[data-tick="${Math.max(0, Math.min(turns.length - 1, turn))}"]`)
      ?.focus();
  handlers.current = {
    focus(key) {
      if (press.current) return;
      setReduce(reducedMotion());
      setFocused(key);
      setCardMark(key);
      intend("map", 0);
    },
    blur(key) {
      setFocused((current) => (current === key ? undefined : current));
    },
    key(event, turn) {
      if (event.key === "Escape") dismiss();
      const to =
        event.key === "ArrowUp"
          ? turn - 1
          : event.key === "ArrowDown"
            ? turn + 1
            : event.key === "Home"
              ? 0
              : event.key === "End"
                ? turns.length - 1
                : undefined;
      if (to !== undefined) focusTick(to);
    },
    activate,
  };
  const cardTurn = cardAt?.kind === "user" ? turns[cardAt.turn] : undefined;
  const cardMarked = cardTurn ? bookmarks.has(cardTurn) : false;
  return (
    <div className="acpmux-minimap" style={{ "--acpmux-rail-left": `${placement.left}px` } as React.CSSProperties}>
      <nav
        ref={rail}
        className="acpmux-minimap__rail acpmux-scrollmap"
        aria-label={t("minimap.label")}
        style={{ left: placement.left, top: MAP_MARGIN, width: ROW_WIDTH, height }}
        data-hovering={pointerY !== undefined || undefined}
        data-scrubbing={scrubbing || undefined}
        data-reduce={reduce || undefined}
        onPointerEnter={() => setReduce(reducedMotion())}
        onPointerMove={(event) => {
          const y = railY(event.clientY);
          const state = press.current;
          if (state && !state.moved && Math.abs(event.clientY - state.y) >= SCRUB_SLOP) {
            state.moved = true;
            setScrubbing(true);
            dismiss();
            try {
              event.currentTarget.setPointerCapture?.(state.pointer);
            } catch {}
          }
          if (state?.moved) seek(y, false);
          point(y);
        }}
        onPointerLeave={(event) => {
          if (press.current?.moved) return;
          setPointerY(undefined);
          setHovered(undefined);
          if (!within(card.current, event.relatedTarget)) intend(null);
        }}
        onPointerDown={(event) => {
          if (event.button !== 0 || event.pointerType === "touch") return;
          const y = railY(event.clientY);
          const state: Press = {
            pointer: event.pointerId,
            y: event.clientY,
            moved: false,
            mark: keyOf(marks[markAt(marks, y) ?? -1]),
          };
          press.current = state;
          // A press released off the rail ends here, so a later hover cannot scrub.
          const page = event.currentTarget.ownerDocument.defaultView ?? window;
          const released = () => {
            page.removeEventListener("pointerup", released);
            page.removeEventListener("pointercancel", released);
            if (press.current !== state) return;
            press.current = undefined;
            if (state.moved) setScrubbing(false);
          };
          page.addEventListener("pointerup", released);
          page.addEventListener("pointercancel", released);
        }}
        onPointerUp={endPress}
        onPointerCancel={(event) => {
          if (press.current) press.current.moved = true;
          endPress(event);
        }}
        onBlur={(event) => {
          const next = event.relatedTarget as Node | null;
          if (event.currentTarget.contains(next) || card.current?.contains(next)) return;
          if (hovered === undefined) intend(null);
        }}
      >
        <div ref={thumb} className="acpmux-scrollmap__view" aria-hidden />
        {marks.map((mark, index) => {
          const turn = mark.kind === "user" ? turns[mark.turn] : undefined;
          const key = keyOf(mark)!;
          return (
            <Mark
              key={key}
              id={key}
              mark={mark}
              progress={pointerY !== undefined ? mapProgress(mark.y - pointerY) : key === focused ? 1 : 0}
              active={key === active}
              current={inView !== undefined && index >= inView.first && index <= inView.last}
              bookmarked={!!turn && bookmarks.has(turn)}
              describedBy={showCard && cardMark === key ? cardId : undefined}
              prompt={turn?.prompt}
              count={turns.length}
              actions={actions}
            />
          );
        })}
      </nav>
      {showCard && cardAt && (
        <PreviewCard
          ref={card}
          id={cardId}
          x={placement.left + ROW_WIDTH}
          railLeft={placement.left}
          y={cardOffset(MAP_MARGIN + cardAt.y, cardHeight, viewportHeight)}
          // Out of the scroller: its edge mask would keep the card's blur from the rows (PreviewCard.tsx).
          scroller={scroller.current}
          prompt={cardTurn?.prompt}
          reply={cardTurn ? cardTurn.reply : agentReply}
          metadata={cardTurn?.metadata}
          onSizeChange={() => setCardHeight(card.current?.offsetHeight ?? 0)}
          bookmark={
            cardTurn && bookmarks.can(cardTurn)
              ? { marked: cardMarked, toggle: () => bookmarks.toggle(cardTurn) }
              : undefined
          }
          onPointerLeave={(event) => {
            if (!within(rail.current, event.relatedTarget)) intend(null);
          }}
          onFocus={() => setCardFocus(true)}
          onBlur={(event) => {
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

/// One message's mark: a prompt's is a button (a tab stop, Return or Space jumps); a reply's is
/// drawn only, reached by pointer.
type MarkActions = {
  focus(key: string): void;
  blur(key: string): void;
  key(event: React.KeyboardEvent<HTMLButtonElement>, turn: number): void;
  activate(key: string): void;
};

const Mark = memo(function Mark({
  id,
  mark,
  progress,
  active,
  current,
  bookmarked,
  describedBy,
  prompt,
  count,
  actions,
}: {
  /// The mark's row id, which the rail's state names.
  id: string;
  mark: MapMark;
  progress: number;
  active: boolean;
  /// Under the view bar: on screen.
  current: boolean;
  bookmarked: boolean;
  describedBy?: string;
  /// A prompt's mark: its prompt, for the label.
  prompt?: string;
  count: number;
  actions: MarkActions;
}) {
  const t = useT();
  const [rest, grown] = mark.kind === "user" ? USER_LENGTH : AGENT_LENGTH;
  const length = rest + (grown - rest) * progress;
  const style = { transform: `translateY(${mark.y - 5}px)` };
  const tone = active ? "active" : current ? "current" : "rest";
  const label =
    prompt === undefined
      ? ""
      : t(bookmarked ? "minimap.tickBookmarked" : "minimap.tick", { index: mark.turn + 1, count, prompt });
  const bar = <span className="acpmux-minimap__bar" style={{ transform: `scaleX(${length / TICK_BOX})` }} />;
  if (mark.kind === "agent")
    return (
      <span className="acpmux-minimap__tick acpmux-scrollmap__mark" data-kind="agent" data-tone={tone} style={style}>
        {bar}
      </span>
    );
  return (
    <MinimapTick
      type="button"
      index={mark.turn}
      last={count - 1}
      active
      data-tick={mark.turn}
      data-kind="user"
      className="acpmux-minimap__tick acpmux-scrollmap__mark"
      data-tone={tone}
      data-bookmarked={bookmarked || undefined}
      aria-label={label}
      aria-describedby={describedBy}
      style={style}
      onFocus={() => actions.focus(id)}
      onBlur={() => actions.blur(id)}
      // The rail's pointer handlers take presses; a click with no pointer (Return, Space) jumps here.
      onClick={(event) => {
        if (event.detail === 0) actions.activate(id);
      }}
      keyboard={(event) => actions.key(event, mark.turn)}
    >
      {bar}
      <span className="acpmux-minimap__dot" style={{ transform: `translateX(${length}px)` }} />
    </MinimapTick>
  );
});
