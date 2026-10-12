// Every popover trigger opens on a mouse press and picks by press-drag-release (pressRelease.ts),
// and toggles: pressing it while its popover is open closes it. WebKit never focuses a clicked
// button, so a press first blurs whatever the popover focused, and an outside-press handler may
// close it too; either way the click would find it closed and reopen it. A mouse press decides on
// the press and its click is ignored; a keyboard click reads the state as of the press, or now.
import { useEffect, useRef, type PointerEvent } from "react";
import { isMousePress, trackPressRelease } from "./pressRelease";

export function usePopoverTrigger(open: boolean, setOpen: (open: boolean) => void, show?: () => void) {
  const openAtPress = useRef<boolean | undefined>(undefined);
  // A mouse press already opened or closed it: the click it ends with does nothing.
  const pressed = useRef(false);
  const press = useRef<(() => void) | null>(null);
  useEffect(() => () => press.current?.(), []);
  return {
    onPointerDown: (event: PointerEvent<HTMLElement>) => {
      openAtPress.current = open;
      if (!isMousePress(event)) return;
      pressed.current = true;
      press.current?.();
      if (open) setOpen(false);
      else if (show) show();
      else setOpen(true);
      press.current = trackPressRelease(event, {
        close: open ? undefined : () => setOpen(false),
        end: (onTrigger) => {
          press.current = null;
          // No click follows a release off the trigger.
          if (!onTrigger) pressed.current = false;
        },
      });
    },
    onMouseDown: (event: { preventDefault(): void }) => {
      if (open) event.preventDefault();
    },
    onClick: () => {
      const wasOpen = openAtPress.current ?? open;
      openAtPress.current = undefined;
      if (pressed.current) {
        pressed.current = false;
        return;
      }
      if (wasOpen) setOpen(false);
      else if (show) show();
      else setOpen(true);
    },
  };
}
