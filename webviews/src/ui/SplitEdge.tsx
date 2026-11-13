// The draggable edge between two side-by-side panes of a webview: the side preview panel beside the
// chat, a list beside its detail. A line between two panes reads as a split divider, so it drags like
// one (Leo, 2026-11-09: "there's this supposed divider-looking thing that I can't actually drag, and
// it just looks super awkward"). It draws as a native split divider does (CmuxNextLayout
// DividerHandleView): the pane's own hairline at rest, a 2px line in the focus ring's color at 60% while
// hovered or dragged, and a hit zone wider than the line, centred on it. A double-click puts the pane
// back to its default width.
//
// The edge sizes its parent, the pane it sits on: it writes the width to a CSS custom property, which
// the surface's CSS reads (`flex-basis: var(--x, default)`, a grid track), on the parent or on a
// container every element that moves with the pane reads it from. A drag writes at most once a frame
// and never re-renders React; the width is saved when the drag ends and read again on mount. `min` and
// `max` bound the drag; the surface's CSS still clamps what it reads, so a width saved in a wide pane
// never crowds a narrow one.
import { useLayoutEffect, useRef } from "react";
import "./SplitEdge.css";

export type SplitEdgeProps = {
  /** Which side of the sized pane the edge is on: `left` for a panel on the right of what it splits;
   * `start` and `end` follow the writing direction, for a pane whose border does. */
  side: "left" | "right" | "start" | "end";
  /** The custom property the surface's CSS reads the width from. */
  property: `--${string}`;
  /** Where the width is saved (localStorage). */
  storageKey: string;
  /** `px`, or `vw`: a share of the page's width, kept as a native split keeps its ratio. */
  unit?: "px" | "vw";
  /** Drag bounds, in `unit`. */
  min: number;
  max: number;
  /** The element that carries the property: the sized pane (default) or its parent. */
  on?: "pane" | "parent";
};

const readStored = (key: string): number | undefined => {
  try {
    const value = Number(globalThis.localStorage?.getItem(key));
    return Number.isFinite(value) && value > 0 ? value : undefined;
  } catch {
    return undefined;
  }
};
const writeStored = (key: string, value: number | undefined) => {
  try {
    if (value === undefined) globalThis.localStorage?.removeItem(key);
    else globalThis.localStorage?.setItem(key, String(value));
  } catch {
    // A page without storage keeps the width until it unloads.
  }
};

/** The width a drag to `clientX` gives a pane spanning `left`..`right`, in `unit`, within bounds. */
export function splitEdgeWidth(
  side: "left" | "right",
  clientX: number,
  pane: { left: number; right: number },
  unit: NonNullable<SplitEdgeProps["unit"]>,
  pageWidth: number,
  min: number,
  max: number,
): number {
  const px = side === "left" ? pane.right - clientX : clientX - pane.left;
  const value = unit === "vw" ? (pageWidth > 0 ? (px / pageWidth) * 100 : min) : px;
  return Math.round(Math.min(max, Math.max(min, value)) * 10) / 10;
}

export function SplitEdge({ side, property, storageKey, unit = "px", min, max, on = "pane" }: SplitEdgeProps) {
  const handle = useRef<HTMLDivElement>(null);
  const drag = useRef<
    { pane: DOMRect; side: "left" | "right"; value: number; frame: number; moved: boolean } | undefined
  >(undefined);
  const target = () => {
    const pane = handle.current?.parentElement ?? undefined;
    return on === "parent" ? (pane?.parentElement ?? undefined) : pane;
  };
  const apply = (value: number | undefined) => {
    const element = target();
    if (!element) return;
    if (value === undefined) element.style.removeProperty(property);
    else element.style.setProperty(property, `${value}${unit}`);
  };
  // Before the first paint, so a saved width never shows the default for a frame first. The parent
  // outlives the edge, so the property leaves with it.
  useLayoutEffect(() => {
    const element = target();
    const stored = readStored(storageKey);
    if (stored !== undefined) apply(Math.min(max, Math.max(min, stored)));
    return () => {
      // A pane that leaves mid-drag gets no pointerup: its markers leave with it.
      if (drag.current) {
        cancelAnimationFrame(drag.current.frame);
        drag.current = undefined;
        delete document.documentElement.dataset.splitResizing;
      }
      element?.style.removeProperty(property);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the edge's place and key are fixed for its life
  }, [storageKey, property]);
  const end = () => {
    const state = drag.current;
    if (!state) return;
    cancelAnimationFrame(state.frame);
    // A press that never moved (half of a double-click) changes and saves nothing.
    if (state.moved) {
      apply(state.value);
      writeStored(storageKey, state.value);
    }
    drag.current = undefined;
    delete handle.current?.parentElement?.dataset.splitResizing;
    delete document.documentElement.dataset.splitResizing;
  };
  return (
    <div
      ref={handle}
      className="ui-split-edge"
      data-side={side}
      // A pointer affordance, as a native split divider and Session Info's edge are; the panes keep
      // their own keyboard paths.
      aria-hidden="true"
      onPointerDown={(event) => {
        const pane = handle.current?.parentElement;
        if (event.button !== 0 || !pane) return;
        event.preventDefault();
        event.currentTarget.setPointerCapture?.(event.pointerId);
        const rect = pane.getBoundingClientRect();
        const rtl = getComputedStyle(pane).direction === "rtl";
        const physical = side === "start" ? (rtl ? "right" : "left") : side === "end" ? (rtl ? "left" : "right") : side;
        drag.current = { pane: rect, side: physical, value: 0, frame: 0, moved: false };
        pane.dataset.splitResizing = "";
        // The page's too: the resize cursor holds over the other pane and its frames while dragging.
        document.documentElement.dataset.splitResizing = "";
      }}
      onPointerMove={(event) => {
        const state = drag.current;
        if (!state) return;
        state.value = splitEdgeWidth(state.side, event.clientX, state.pane, unit, window.innerWidth, min, max);
        state.moved = true;
        // One write a frame, however many moves the pointer sends.
        if (!state.frame)
          state.frame = requestAnimationFrame(() => {
            state.frame = 0;
            apply(state.value);
          });
      }}
      onPointerUp={end}
      onPointerCancel={end}
      onLostPointerCapture={end}
      onDoubleClick={() => {
        apply(undefined);
        writeStored(storageKey, undefined);
      }}
    />
  );
}
