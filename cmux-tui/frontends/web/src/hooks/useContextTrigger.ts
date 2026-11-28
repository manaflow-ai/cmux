import { useCallback, useEffect, useRef, type PointerEvent as ReactPointerEvent } from "react";
import type { ContextMenuPoint } from "../lib/contextMenu";

const LONG_PRESS_MS = 500;

export function useContextTrigger(onOpen: (point: ContextMenuPoint) => void) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const start = useRef<ContextMenuPoint | null>(null);

  const cancel = useCallback(() => {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
    start.current = null;
  }, []);

  useEffect(() => cancel, [cancel]);

  return {
    onContextMenu: (event: ReactPointerEvent<HTMLElement> | React.MouseEvent<HTMLElement>) => {
      event.preventDefault();
      event.stopPropagation();
      cancel();
      onOpen({ x: event.clientX, y: event.clientY });
    },
    onPointerDown: (event: ReactPointerEvent<HTMLElement>) => {
      if (event.pointerType !== "touch") return;
      event.stopPropagation();
      const point = { x: event.clientX, y: event.clientY };
      start.current = point;
      timer.current = setTimeout(() => {
        onOpen(point);
        timer.current = null;
      }, LONG_PRESS_MS);
    },
    onPointerMove: (event: ReactPointerEvent<HTMLElement>) => {
      const point = start.current;
      if (point && Math.hypot(event.clientX - point.x, event.clientY - point.y) > 10) cancel();
    },
    onPointerUp: cancel,
    onPointerCancel: cancel,
  };
}
