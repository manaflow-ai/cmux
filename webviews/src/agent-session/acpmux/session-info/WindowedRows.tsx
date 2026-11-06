// A Session Info list opened to any length costs the same: the open draws only the rows that can
// show (the panel's window, or the list's own capped scroller, and a few past it), puts a box as tall
// as the rest under them, so the list and the panel's scroll take their whole height at once, and
// draws the rest as they scroll into view. It never draws a row again for a scroll, and stops
// listening once every row is drawn (Leo, 2026-11-06: "If I open up this 5,427 finished, it'll lag.
// And there's probably more places like that where shit will lag if I open things up"). The same rule
// as the transcript's opened runs (conversation/ToolGroupRow.tsx StepList).
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";

/// The least height a list row draws at, in px: the rows a window can show are its height over this.
const ROW_MIN_PX = 24;
/// Rows drawn past the window's edge, so a slow scroll finds them there.
export const OVERSCAN_ROWS = 8;

/// The rows an open draws for a window `viewHeight` px tall: as many as can show, and the overscan.
export function firstRowCount(viewHeight: number): number {
  return Math.max(1, Math.ceil(viewHeight / ROW_MIN_PX)) + OVERSCAN_ROWS;
}

const viewHeight = () => (typeof window === "undefined" ? 800 : window.innerHeight || 800);

/// The element that scrolls `node`: itself or its nearest ancestor that scrolls up and down.
function scrollerOf(node: Element): HTMLElement | null {
  const view = node.ownerDocument.defaultView;
  for (let at: Element | null = node; at; at = at.parentElement) {
    const overflow = view?.getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll") return at as HTMLElement;
  }
  return null;
}

/// `items` drawn by `render` as the rows of the list it sits in (a `<ul>`'s `<li>`s): only those
/// that can show, then the rest as the list scrolls to them, in a box held for them (`li[data-rows-rest]`).
/// A list that fits draws as it did, every row and no box.
export function WindowedRows<T>({
  items,
  render,
}: {
  items: readonly T[];
  render: (item: T, index: number) => ReactNode;
}) {
  // The rows drawn: only grows, so a row once drawn stays (its state, its focus, a Find match).
  const [drawn, setDrawn] = useState(() => firstRowCount(viewHeight()));
  // A list folded back to a few rows (its Show less) opens again at the window's rows, not at all
  // it reached before.
  const first = firstRowCount(viewHeight());
  if (items.length <= first && drawn > first) setDrawn(first);
  const count = Math.min(items.length, drawn);
  const rest = items.length - count;
  const box = useRef<HTMLLIElement>(null);
  useLayoutEffect(() => {
    const spacer = box.current;
    const list = spacer?.parentElement;
    if (!spacer || !list || rest <= 0) return;
    const rows = list.children;
    const at = Array.prototype.indexOf.call(rows, spacer) as number;
    const lead = rows[at - count];
    if (!lead) return;
    // The drawn rows' pitch, and the box for the rest at that pitch, before paint.
    const pitch = Math.max(1, (spacer.getBoundingClientRect().top - lead.getBoundingClientRect().top) / count);
    spacer.style.height = `${rest * pitch}px`;
    const scroller = scrollerOf(list);
    // The rows the window reaches now, and the overscan; drawn in the next commit when past what is.
    // Read from the box, which stays while rows are held back: a row drawn above it may be replaced
    // (a sort, a reorder of the same rows) without this effect running again, and a replaced row's
    // rect is a detached node's, which never moves.
    const reach = () => {
      const bottom = Math.min(scroller?.getBoundingClientRect().bottom ?? Infinity, viewHeight());
      const top = spacer.getBoundingClientRect().top - count * pitch;
      const need = Math.ceil((bottom - top) / pitch) + OVERSCAN_ROWS;
      if (need > count) setDrawn((now) => Math.max(now, need));
    };
    reach();
    const target: EventTarget = scroller ?? window;
    target.addEventListener("scroll", reach, { passive: true });
    window.addEventListener("resize", reach);
    return () => {
      target.removeEventListener("scroll", reach);
      window.removeEventListener("resize", reach);
    };
  }, [rest, count]);
  return (
    <>
      {items.slice(0, count).map(render)}
      {rest > 0 && <li ref={box} className="acpmux-session-info-rows-rest" data-rows-rest={rest} aria-hidden />}
    </>
  );
}
