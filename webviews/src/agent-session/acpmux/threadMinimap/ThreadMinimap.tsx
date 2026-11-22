// The thread minimap: one tick per user message at the transcript's left edge. Hovering the
// column grows the ticks near the pointer and, after a short pause, shows the prompt and the
// start of its reply beside the tick; a click scrolls the transcript to that prompt. The
// bookmark in the popover marks the turn (bookmarks.ts). Geometry comes from the transcript's
// layout (`tops`), so nothing here measures a row; the only element read is the popover itself.
// Motion is transforms and opacity only (threadMinimap.css). Spec: minimap-spec.md in the lane notes.
import React, { memo, useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxRow, ConversationLayout } from "../model";
import { useT } from "../i18n";
import { useBookmarks } from "./bookmarks";
import { MinimapTick } from "../../../ui/MinimapTick";
import {
  currentTurn,
  minimapTurns,
  popoverOffset,
  POPOVER_DELAY_MS,
  tickLayout,
  tickWidth,
  TICK_LEFT,
  TICK_MAX_WIDTH,
  POPOVER_LEFT,
  turnScrollTop,
  visibleTurns,
  type MinimapTurn,
} from "./model";

/// The narrowest gutter (the space left of the rows) the column draws in; narrower panes hide it.
const MIN_GUTTER = 28;
/// Matches `.acpmux-row`'s left: max(18px, (100% - 760px) / 2).
const gutter = (width: number) => Math.max(18, (width - 760) / 2);

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
  const bookmarks = useBookmarks();
  const turns = useMemo(() => minimapTurns(rows, sessionId), [rows, sessionId]);
  /// The tick under the pointer or keyboard focus.
  const [hovered, setHovered] = useState<number | undefined>(undefined);
  const [shown, setShown] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const root = useRef<HTMLElement>(null);
  const popover = useRef<HTMLDivElement>(null);
  const [popoverHeight, setPopoverHeight] = useState(0);
  const { first, pitch } = tickLayout(turns.length, viewportHeight);
  const current = turns.length ? currentTurn(turns, layout.tops, scrollTop, viewportHeight) : 0;
  const onScreen = visibleTurns(turns, layout.tops, layout.totalHeight, scrollTop, viewportHeight);
  const active = hovered ?? current;
  const turn: MinimapTurn | undefined = hovered === undefined ? undefined : turns[hovered];

  const shownRef = useRef(false);
  const close = useCallback(() => {
    clearTimeout(timer.current);
    timer.current = undefined;
    shownRef.current = false;
    setHovered(undefined);
    setShown(false);
  }, []);
  /// Hovers tick `index`. The first popover waits POPOVER_DELAY_MS (keyboard focus shows it at once);
  /// once one shows, the next tick's replaces it on the same frame.
  const hover = useCallback((index: number, immediately: boolean) => {
    setHovered(index);
    if (shownRef.current) return;
    const show = () => {
      timer.current = undefined;
      shownRef.current = true;
      setShown(true);
    };
    if (immediately) {
      clearTimeout(timer.current);
      show();
    } else if (timer.current === undefined) timer.current = setTimeout(show, POPOVER_DELAY_MS);
  }, []);
  // The popover's own height, for centering it on the tick and keeping it inside the viewport.
  useLayoutEffect(() => {
    const node = popover.current;
    if (shown && node) setPopoverHeight(node.offsetHeight);
  }, [shown, turn?.key, turn?.reply]);
  useLayoutEffect(() => () => clearTimeout(timer.current), []);

  const indexAt = (clientY: number) => {
    const box = root.current?.getBoundingClientRect();
    if (!box || !turns.length) return undefined;
    const index = Math.floor((clientY - box.top) / pitch);
    return Math.max(0, Math.min(turns.length - 1, index));
  };
  const jump = (index: number) => {
    const node = scroller.current;
    const target = turns[index];
    if (!node || !target) return;
    const reduce = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    node.scrollTo({ top: turnScrollTop(target, layout.tops), behavior: reduce ? "auto" : "smooth" });
  };
  const focusTick = (index: number) => {
    const next = Math.max(0, Math.min(turns.length - 1, index));
    root.current?.querySelector<HTMLButtonElement>(`[data-tick="${next}"]`)?.focus();
  };

  if (turns.length < 2 || gutter(width) < MIN_GUTTER) return null;
  const center = first + active * pitch;
  /// The column's top edge: the first tick's band starts half a pitch above its center.
  const railTop = first - pitch / 2;
  const marked = turn ? bookmarks.marks.has(turn.key) : false;
  return (
    <div className="acpmux-minimap">
      <nav
        ref={root}
        className="acpmux-minimap__rail"
        aria-label={t("minimap.label")}
        style={{ transform: `translate3d(0, ${railTop}px, 0)`, height: pitch * turns.length }}
        data-hovering={hovered !== undefined || undefined}
        onPointerMove={(event) => {
          if (event.pointerType === "touch") return;
          if ((event.target as Element).closest(".acpmux-minimap__popover")) return;
          const index = indexAt(event.clientY);
          if (index !== undefined && index !== hovered) hover(index, false);
        }}
        onPointerLeave={close}
        onBlur={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) close();
        }}
      >
        {turns.map((entry, index) => (
          <Tick
            key={entry.key}
            index={index}
            top={index * pitch}
            pitch={pitch}
            width={tickWidth(hovered === undefined ? undefined : index - hovered)}
            tone={
              hovered === index
                ? "active"
                : hovered === undefined && index >= onScreen.first && index <= onScreen.last
                  ? "current"
                  : "rest"
            }
            tabbable={index === active}
            current={index === current}
            label={t(bookmarks.marks.has(entry.key) ? "minimap.tickBookmarked" : "minimap.tick", {
              index: index + 1,
              count: turns.length,
              prompt: entry.prompt,
            })}
            onJump={jump}
            onFocusTick={hover}
            onMove={focusTick}
            last={turns.length - 1}
          />
        ))}
        {turn && (
          <div
            ref={popover}
            className="acpmux-minimap__popover"
            hidden={!shown}
            style={{
              transform: `translate3d(${POPOVER_LEFT}px, ${popoverOffset(center, popoverHeight, viewportHeight) - railTop}px, 0)`,
            }}
          >
            <div className="acpmux-minimap__title">
              <span className="acpmux-minimap__prompt">{turn.prompt}</span>
              <button
                type="button"
                className="acpmux-minimap__bookmark"
                aria-pressed={marked}
                aria-label={t(marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
                title={t(marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
                onClick={() => bookmarks.toggle(turn.key)}
              >
                <BookmarkIcon filled={marked} />
              </button>
            </div>
            {turn.reply.length > 0 && (
              <div className="acpmux-minimap__reply">
                {turn.reply.map((block, blockIndex) => (
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
      </nav>
    </div>
  );
}

const Tick = memo(function Tick({
  index,
  top,
  pitch,
  width,
  tone,
  tabbable,
  current,
  label,
  onJump,
  onFocusTick,
  onMove,
  last,
}: {
  index: number;
  top: number;
  pitch: number;
  width: number;
  tone: "rest" | "current" | "active";
  tabbable: boolean;
  current: boolean;
  label: string;
  onJump: (index: number) => void;
  onFocusTick: (index: number, immediately: boolean) => void;
  onMove: (index: number) => void;
  last: number;
}) {
  return (
    <MinimapTick
      type="button"
      index={index}
      last={last}
      data-tick={index}
      className="acpmux-minimap__tick"
      data-tone={tone}
      aria-label={label}
      aria-current={current ? "location" : undefined}
      active={tabbable}
      style={{ transform: `translate3d(0, ${top}px, 0)`, height: pitch }}
      onClick={() => onJump(index)}
      onFocus={(event) => {
        if (event.currentTarget.matches(":focus-visible")) onFocusTick(index, true);
      }}
      keyboard={(event) => {
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
        if (to !== undefined) onMove(to);
      }}
    >
      <span
        className="acpmux-minimap__bar"
        style={{ transform: `translateX(${TICK_LEFT}px) scaleX(${width / TICK_MAX_WIDTH})` }}
      />
    </MinimapTick>
  );
});

function BookmarkIcon({ filled }: { filled: boolean }) {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M3 3.5a1.75 1.75 0 0 1 1.75-1.75h6.5A1.75 1.75 0 0 1 13 3.5v10.15a.4.4 0 0 1-.64.32L8 10.9l-4.36 3.07a.4.4 0 0 1-.64-.32Z"
        fill={filled ? "currentColor" : "none"}
        stroke="currentColor"
        strokeWidth="1.1"
        strokeLinejoin="round"
      />
    </svg>
  );
}
