// The thread minimap: one tick per user message at the transcript's left edge. Hovering the
// column grows the ticks near the pointer and, after a short pause, shows the prompt and the
// start of its reply beside the tick; a click scrolls the transcript to that prompt. The
// bookmark in the popover marks the turn (bookmarks.ts). Geometry comes from the transcript's
// layout (`tops`), so nothing here measures a row; the only element read is the popover itself.
// Motion is transforms and opacity only (threadMinimap.css). Spec: minimap-spec.md in the lane notes.
import React, { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { transcriptColumn, type AcpmuxRow, type ConversationLayout } from "../model";
import { useT } from "../i18n";
import { promptSeq, useBookmarks } from "./bookmarks";
import { MinimapTick } from "../../../ui/MinimapTick";
import { useHoverIntent } from "../../../ui/hoverIntent";
import {
  currentTurn,
  minimapTurns,
  popoverOffset,
  tickLayout,
  tickWidth,
  TICK_CURRENT_WIDTH,
  TICK_LEFT,
  TICK_MAX_WIDTH,
  POPOVER_LEFT,
  turnScrollTop,
  visibleTurns,
  type MinimapTurn,
  type MinimapTurns,
} from "./model";

/// The narrowest gutter (the space left of the rows) the column draws in; narrower panes hide it.
const MIN_GUTTER = 28;
/// How long a Previous or Next Turn step's smooth scroll counts as under way for the next step.
const STEP_PENDING_MS = 800;
/// The space left of the rows (`.acpmux-row`'s left).
const gutter = (width: number) => transcriptColumn(width).inset;

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
  const bookmarks = useBookmarks(sessionId);
  const lastTurns = useRef<MinimapTurns | undefined>(undefined);
  const turns = useMemo(() => {
    const next = minimapTurns(rows, sessionId, lastTurns.current);
    lastTurns.current = next;
    return next.turns;
  }, [rows, sessionId]);
  /// The tick under the pointer or keyboard focus.
  const [hovered, setHovered] = useState<number | undefined>(undefined);
  // The turn preview's hover intent (ui/hoverIntent.ts): the first waits the hover delay, then it
  // follows the pointer from tick to tick at once, and cools a moment after the pointer leaves.
  const preview = useHoverIntent<"rail">();
  const shown = preview.shown !== null;
  const root = useRef<HTMLElement>(null);
  const popover = useRef<HTMLDivElement>(null);
  const [popoverHeight, setPopoverHeight] = useState(0);
  const { first, pitch } = tickLayout(turns.length, viewportHeight);
  const current = turns.length ? currentTurn(turns, layout.tops, scrollTop, viewportHeight) : 0;
  const onScreen = visibleTurns(turns, layout.tops, layout.totalHeight, scrollTop, viewportHeight);
  const active = hovered ?? current;
  const turn: MinimapTurn | undefined = hovered === undefined ? undefined : turns[hovered];
  // Keep the rail's absolute geometry, but mount only a small window around the viewport and the
  // active tick. Long transcripts otherwise create thousands of DOM nodes on every scroll.
  const tickStart = Math.max(0, Math.min(onScreen.first, active) - 100);
  const tickEnd = Math.min(turns.length, Math.max(onScreen.last, active) + 101);
  const renderedTurns = useMemo(() => turns.slice(tickStart, tickEnd), [turns, tickStart, tickEnd]);

  const intend = preview.hover;
  const close = useCallback(() => {
    setHovered(undefined);
    intend(null);
  }, [intend]);
  /// Hovers tick `index`. The first popover waits the hover delay (keyboard focus shows it at once);
  /// once one shows, the next tick's replaces it on the same frame.
  const hover = useCallback(
    (index: number, immediately: boolean) => {
      setHovered(index);
      intend("rail", immediately ? 0 : undefined);
    },
    [intend],
  );
  // The popover's own height, for centering it on the tick and keeping it inside the viewport.
  useLayoutEffect(() => {
    const node = popover.current;
    if (shown && node) setPopoverHeight(node.offsetHeight);
  }, [shown, turn?.key, turn?.reply]);
  // Previous Turn and Next Turn (the app's Ctrl-Opt-Up and Ctrl-Opt-Down, bridge commands that raise
  // these events) step the transcript from prompt to prompt, as a tick's click does. They work while the column is hidden too (a narrow pane, one turn).
  const stepping = useRef({
    turns,
    tops: layout.tops,
    total: layout.totalHeight,
    /// Where the last step's smooth scroll goes, and until when that counts (STEP_PENDING_MS).
    target: undefined as number | undefined,
    until: 0,
  });
  useEffect(() => {
    stepping.current.turns = turns;
    stepping.current.tops = layout.tops;
    stepping.current.total = layout.totalHeight;
  }, [turns, layout.tops, layout.totalHeight]);
  useEffect(() => {
    const step = (by: -1 | 1) => {
      const node = scroller.current;
      const { turns: all, tops, total, target, until } = stepping.current;
      if (!node || !all.length) return;
      // A step during its smooth scroll counts from where that scroll goes, so repeats keep stepping.
      // Only then: once it has passed or the reader scrolled, the view is where they are.
      const pending = target !== undefined && performance.now() < until && Math.abs(node.scrollTop - target) > 1;
      const from = pending ? target : node.scrollTop;
      // From the turn being read: Next goes to the turn after it; Previous to its own prompt when
      // that is above the viewport, else to the turn before it.
      const reading = currentTurn(all, tops, from, node.clientHeight);
      const index = by > 0 || turnScrollTop(all[reading], tops) >= from - 1 ? reading + by : reading;
      if (index < 0 || index >= all.length) return;
      // The last turns' prompts can sit below the furthest the transcript scrolls.
      const next = Math.min(turnScrollTop(all[index], tops), Math.max(0, total - node.clientHeight));
      stepping.current.target = next;
      stepping.current.until = performance.now() + STEP_PENDING_MS;
      const reduce = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
      node.scrollTo({ top: next, behavior: reduce ? "auto" : "smooth" });
    };
    const previous = () => step(-1);
    const following = () => step(1);
    // The reader's own scroll ends a pending step.
    const reader = () => {
      stepping.current.target = undefined;
    };
    const node = scroller.current;
    const inputs = ["wheel", "pointerdown", "touchstart", "keydown"] as const;
    for (const name of inputs) node?.addEventListener(name, reader, { passive: true });
    window.addEventListener("cmux-acpmux-previousTurn", previous);
    window.addEventListener("cmux-acpmux-nextTurn", following);
    return () => {
      window.removeEventListener("cmux-acpmux-previousTurn", previous);
      window.removeEventListener("cmux-acpmux-nextTurn", following);
      for (const name of inputs) node?.removeEventListener(name, reader);
    };
  }, [scroller]);

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
    hover(next, true);
    requestAnimationFrame(() => root.current?.querySelector<HTMLButtonElement>(`[data-tick="${next}"]`)?.focus());
  };

  if (turns.length < 2 || gutter(width) < MIN_GUTTER) return null;
  const center = first + active * pitch;
  /// The column's top edge: the first tick's band starts half a pitch above its center.
  const railTop = first - pitch / 2;
  /// The hovered prompt's seq in acpmux's log; a prompt not logged yet has no bookmark.
  const seq = turn ? promptSeq(turn.id) : undefined;
  const marked = seq !== undefined && bookmarks.marks.has(seq);
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
        {renderedTurns.map((entry, offset) => {
          const index = tickStart + offset;
          return (
            <Tick
              key={entry.key}
              index={index}
              top={index * pitch}
              pitch={pitch}
              width={Math.max(
                tickWidth(hovered === undefined ? undefined : index - hovered),
                index === current ? TICK_CURRENT_WIDTH : 0,
              )}
              tone={
                hovered === index
                  ? "active"
                  : hovered === undefined && index >= onScreen.first && index <= onScreen.last
                    ? "current"
                    : "rest"
              }
              tabbable={index === active}
              current={index === current}
              label={t(isMarked(bookmarks.marks, entry.id) ? "minimap.tickBookmarked" : "minimap.tick", {
                index: index + 1,
                count: turns.length,
                prompt: entry.prompt,
              })}
              onJump={jump}
              onFocusTick={hover}
              onMove={focusTick}
              last={turns.length - 1}
            />
          );
        })}
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
              {seq !== undefined && (
                <button
                  type="button"
                  className="acpmux-minimap__bookmark"
                  aria-pressed={marked}
                  aria-label={t(marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
                  title={t(marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
                  onClick={() => bookmarks.toggle(seq)}
                >
                  <BookmarkIcon filled={marked} />
                </button>
              )}
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

function isMarked(marks: ReadonlySet<number>, rowId: string): boolean {
  const seq = promptSeq(rowId);
  return seq !== undefined && marks.has(seq);
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
      data-current={current ? "" : undefined}
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
