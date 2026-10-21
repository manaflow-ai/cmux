// The full-height thread minimap (the `thread-minimap-layout` experiment's default arm): the rail
// spans the transcript's viewport and maps the whole scroll height onto it. Each prompt is a longer,
// brighter tick and a tab stop; each reply a shorter, dimmer one set in a little; a bar shows what
// is on screen and follows the scroll on its own frame without a render. Hovering grows the marks
// near the pointer and, after the hover delay, previews the nearest message beside it. A click on a
// mark jumps to it (a prompt as the compact rail's click does); a click on the track jumps there;
// dragging anywhere scrubs the transcript. Geometry is the transcript's layout (scrollMap.ts).
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
  MIN_GUTTER,
  RAIL_LEFT,
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
  scrollTopAt,
  type MapMark,
} from "./scrollMap";

/// A pointer that moves this far after pressing scrubs instead of clicking.
const SCRUB_SLOP = 3;
/// The drawn lengths, at rest and fully grown: a prompt's tick, and a reply's.
const USER_LENGTH = [11, TICK_BOX] as const;
const AGENT_LENGTH = [5, 15] as const;

type PromptMarks = ReturnType<typeof usePromptMarks>;
type Press = { pointer: number; y: number; moved: boolean; mark?: number };

const within = (element: Element | null, to: EventTarget | null) =>
  !!element && !!to && "nodeType" in to && element.contains(to as Node);

export function ScrollMap({
  rows,
  turns,
  layout,
  scroller,
  viewportHeight,
  width,
  marks: bookmarks,
  jump,
}: {
  rows: readonly AcpmuxRow[];
  turns: readonly MinimapTurn[];
  layout: ConversationLayout;
  scroller: React.RefObject<HTMLElement | null>;
  viewportHeight: number;
  width: number;
  marks: PromptMarks;
  /// The compact rail's jump to a prompt (ThreadMinimap), so a click lands and flashes the same.
  jump: (turn: number, how: "click" | "scrub") => number | undefined;
}) {
  const t = useT();
  const height = Math.max(0, Math.floor(viewportHeight - 2 * MAP_MARGIN));
  const marks = useMemo(() => mapMarks(rows, turns, layout, height), [rows, turns, layout, height]);
  /// The pointer's place on the rail (for the fisheye), and the mark it is on.
  const [pointerY, setPointerY] = useState<number | undefined>(undefined);
  const [hovered, setHovered] = useState<number | undefined>(undefined);
  const [focused, setFocused] = useState<number | undefined>(undefined);
  const [cardMark, setCardMark] = useState<number | undefined>(undefined);
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
  const shown =
    turns.length >= MAP_MIN_PROMPTS &&
    layout.totalHeight > viewportHeight &&
    height > 4 * MAP_MARGIN &&
    transcriptColumn(width).inset >= MIN_GUTTER;

  const live = useRef({ height, total: layout.totalHeight, viewportHeight });
  live.current = { height, total: layout.totalHeight, viewportHeight };
  // The bar follows the scroll on the scroll's own frame, by style alone.
  const [placeThumb] = useState(() => () => {
    const node = scroller.current;
    const bar = thumb.current;
    if (!node || !bar) return;
    const { height: rail, total, viewportHeight: view } = live.current;
    const at = mapThumb(node.scrollTop, view, total, rail);
    bar.style.transform = `translateY(${at.top}px)`;
    bar.style.height = `${at.height}px`;
  });
  useLayoutEffect(placeThumb);
  useEffect(() => {
    const node = scroller.current;
    if (!node) return;
    node.addEventListener("scroll", placeThumb, { passive: true });
    return () => node.removeEventListener("scroll", placeThumb);
  }, [scroller, placeThumb]);

  const cardAt = cardMark === undefined ? undefined : marks[cardMark];
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

  // A shorter transcript or another chat can leave the marks the state named behind.
  if (hovered !== undefined && hovered >= marks.length) setHovered(undefined);
  if (focused !== undefined && focused >= marks.length) setFocused(undefined);
  if (cardMark !== undefined && cardMark >= marks.length) setCardMark(undefined);

  if (!shown) return null;

  const railY = (clientY: number) => clientY - (rail.current?.getBoundingClientRect().top ?? 0);
  /// Scrolls to `markIndex`'s message: a prompt as the compact rail's click, a reply to its top.
  const activate = (markIndex: number) => {
    const mark = marks[markIndex];
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
    animateScroll(node, target, reducedMotion() ? 0 : jumpDuration(to - node.scrollTop), JUMP_CURVE);
  };
  /// Centers the view on rail point `y`: at once while scrubbing, else on the jump's curve.
  const seek = (y: number, smooth: boolean) => {
    const node = scroller.current;
    if (!node) return;
    const to = scrollTopAt(y, height, layout.totalHeight, node.clientHeight);
    if (!smooth || reducedMotion()) {
      stopScroll(node);
      node.scrollTop = to;
    } else animateScroll(node, () => to, jumpDuration(to - node.scrollTop), JUMP_CURVE);
  };
  const point = (y: number) => {
    const at = markAt(marks, y);
    setPointerY(Math.round(y));
    setHovered(at);
    if (at === undefined) return;
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
  const active = hovered ?? focused;
  const focusTick = (turn: number) =>
    rail.current
      ?.querySelector<HTMLButtonElement>(`[data-tick="${Math.max(0, Math.min(turns.length - 1, turn))}"]`)
      ?.focus();
  const cardTurn = cardAt?.kind === "user" ? turns[cardAt.turn] : undefined;
  const cardMarked = cardTurn ? bookmarks.has(cardTurn) : false;
  return (
    <div className="acpmux-minimap">
      <nav
        ref={rail}
        className="acpmux-minimap__rail acpmux-scrollmap"
        aria-label={t("minimap.label")}
        style={{ left: RAIL_LEFT, top: MAP_MARGIN, width: ROW_WIDTH, height }}
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
          const state: Press = { pointer: event.pointerId, y: event.clientY, moved: false, mark: markAt(marks, y) };
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
        {marks.map((mark, index) => (
          <Mark
            key={`${mark.kind}-${rows[mark.row]?.id ?? mark.row}`}
            mark={mark}
            index={index}
            progress={pointerY !== undefined ? mapProgress(mark.y - pointerY) : index === focused ? 1 : 0}
            active={index === active}
            bookmarked={mark.kind === "user" && !!turns[mark.turn] && bookmarks.has(turns[mark.turn]!)}
            describedBy={showCard && cardMark === index ? cardId : undefined}
            label={
              mark.kind === "user" && turns[mark.turn]
                ? t(bookmarks.has(turns[mark.turn]!) ? "minimap.tickBookmarked" : "minimap.tick", {
                    index: mark.turn + 1,
                    count: turns.length,
                    prompt: turns[mark.turn]!.prompt,
                  })
                : ""
            }
            last={turns.length - 1}
            onFocus={() => {
              if (press.current) return;
              setReduce(reducedMotion());
              setFocused(index);
              setCardMark(index);
              intend("map", 0);
            }}
            onBlur={() => setFocused((current) => (current === index ? undefined : current))}
            onKey={(event) => {
              if (event.key === "Escape") dismiss();
              const to =
                event.key === "ArrowUp"
                  ? mark.turn - 1
                  : event.key === "ArrowDown"
                    ? mark.turn + 1
                    : event.key === "Home"
                      ? 0
                      : event.key === "End"
                        ? turns.length - 1
                        : undefined;
              if (to !== undefined) focusTick(to);
            }}
            onActivate={() => activate(index)}
          />
        ))}
      </nav>
      {showCard && cardAt && (
        <PreviewCard
          ref={card}
          id={cardId}
          x={RAIL_LEFT + ROW_WIDTH}
          y={cardOffset(MAP_MARGIN + cardAt.y, cardHeight, viewportHeight)}
          prompt={cardTurn?.prompt}
          reply={cardTurn ? cardTurn.reply : agentReply}
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
const Mark = memo(function Mark({
  mark,
  index,
  progress,
  active,
  bookmarked,
  describedBy,
  label,
  last,
  onFocus,
  onBlur,
  onKey,
  onActivate,
}: {
  mark: MapMark;
  index: number;
  progress: number;
  active: boolean;
  bookmarked: boolean;
  describedBy?: string;
  label: string;
  last: number;
  onFocus(): void;
  onBlur(): void;
  onKey(event: React.KeyboardEvent<HTMLButtonElement>): void;
  onActivate(): void;
}) {
  const [rest, grown] = mark.kind === "user" ? USER_LENGTH : AGENT_LENGTH;
  const length = rest + (grown - rest) * progress;
  const style = { transform: `translateY(${mark.y - 5}px)` };
  const tone = active ? "active" : "rest";
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
      last={last}
      active
      data-tick={mark.turn}
      data-mark={index}
      data-kind="user"
      className="acpmux-minimap__tick acpmux-scrollmap__mark"
      data-tone={tone}
      data-bookmarked={bookmarked || undefined}
      aria-label={label}
      aria-describedby={describedBy}
      style={style}
      onFocus={onFocus}
      onBlur={onBlur}
      // The rail's pointer handlers take presses; a click with no pointer (Return, Space) jumps here.
      onClick={(event) => {
        if (event.detail === 0) onActivate();
      }}
      keyboard={onKey}
    >
      {bar}
      <span className="acpmux-minimap__dot" style={{ transform: `translateX(${length}px)` }} />
    </MinimapTick>
  );
});
