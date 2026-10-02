import { useEffect, useMemo, useRef } from "react";
import { HOVER_INTENT_MS } from "./modelPickerVariant";

export type Point = { x: number; y: number };
type Rect = { left: number; right: number; top: number; bottom: number };

/// Whether `p` lies inside the triangle `a b c` (either winding).
export function insideTriangle(p: Point, a: Point, b: Point, c: Point): boolean {
  const side = (from: Point, to: Point) => (to.x - from.x) * (p.y - from.y) - (to.y - from.y) * (p.x - from.x);
  const ab = side(a, b);
  const bc = side(b, c);
  const ca = side(c, a);
  return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0);
}

/// The safe triangle: whether the pointer, moving from `from` to `to`, heads for the open
/// submenu `rect` (it lies inside the submenu, or inside the triangle from `from` to the
/// submenu's nearest edge). A row it crosses on the way then doesn't swap the submenu out.
export function aimingAt(from: Point | undefined, to: Point | undefined, rect: Rect | undefined): boolean {
  if (!from || !to || !rect || rect.right <= rect.left || rect.bottom <= rect.top) return false;
  if (from.x === to.x && from.y === to.y) return false;
  if (to.x >= rect.left && to.x <= rect.right && to.y >= rect.top && to.y <= rect.bottom) return true;
  const beside = from.x < rect.left || from.x > rect.right;
  const [a, b]: [Point, Point] = beside
    ? [
        { x: from.x < rect.left ? rect.left : rect.right, y: rect.top },
        { x: from.x < rect.left ? rect.left : rect.right, y: rect.bottom },
      ]
    : [
        { x: rect.left, y: from.y < rect.top ? rect.top : rect.bottom },
        { x: rect.right, y: from.y < rect.top ? rect.top : rect.bottom },
      ];
  return insideTriangle(to, from, a, b);
}

/// Hover intent for submenus: a row's submenu opens once the pointer rests on it for
/// HOVER_INTENT_MS, and waits while the pointer travels toward the submenu already open
/// (`aim`), so a diagonal path into it doesn't collapse it. A pointer that stops waiting
/// lets the row win.
export function useHoverIntent(delay = HOVER_INTENT_MS) {
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const points = useRef<Point[]>([]);
  useEffect(() => () => clearTimeout(timer.current), []);
  return useMemo(
    () => ({
      /// Records the pointer; call from the popover's pointermove.
      track(event: { clientX: number; clientY: number }) {
        points.current = [...points.current.slice(-1), { x: event.clientX, y: event.clientY }];
      },
      schedule(apply: () => void, aim?: () => Element | null | undefined) {
        clearTimeout(timer.current);
        let seen = points.current.at(-1);
        let tries = 0;
        const attempt = () => {
          timer.current = setTimeout(() => {
            const [from, to] = points.current;
            const moved = to !== seen;
            seen = to;
            if (moved && tries < 6 && aimingAt(from, to, aim?.()?.getBoundingClientRect())) {
              tries += 1;
              attempt();
            } else apply();
          }, delay);
        };
        attempt();
      },
      cancel() {
        clearTimeout(timer.current);
      },
    }),
    [delay],
  );
}
