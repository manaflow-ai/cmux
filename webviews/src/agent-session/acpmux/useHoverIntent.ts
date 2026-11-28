import { useEffect, useMemo, useRef } from "react";
import { HOVER_INTENT_MS } from "./modelPickerLayout";
// The safe triangle is the pages' one (ui/hoverIntent.ts), shared with hover cards.
import { aimingAt, type Point } from "../../ui/hoverIntent";

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
