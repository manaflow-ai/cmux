// Every composer popover trigger toggles: pressing it while its popover is open closes it. WebKit
// never focuses a clicked button, so a press first blurs whatever the popover focused, and an
// outside-press handler may close it too; either way the click would find it closed and reopen it.
// The click reads the state as of the press instead, and the press keeps focus where it is.
import { useRef } from "react";

export function usePopoverTrigger(open: boolean, setOpen: (open: boolean) => void, show?: () => void) {
  const openAtPress = useRef<boolean | undefined>(undefined);
  return {
    onPointerDown: () => {
      openAtPress.current = open;
    },
    onMouseDown: (event: { preventDefault(): void }) => {
      if (open) event.preventDefault();
    },
    // A keyboard click has no press: it reads the current state.
    onClick: () => {
      const wasOpen = openAtPress.current ?? open;
      openAtPress.current = undefined;
      if (wasOpen) setOpen(false);
      else if (show) show();
      else setOpen(true);
    },
  };
}
