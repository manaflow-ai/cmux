// Every popover trigger opens on a mouse press and picks by press-drag-release (pressRelease.ts),
// and toggles: pressing it while its popover is open closes it. WebKit never focuses a clicked
// button, so a press first blurs whatever the popover focused, and an outside-press handler may
// close it too; either way the click would find it closed and reopen it. A mouse press decides on
// the press and its click is ignored; a keyboard click reads the state as of the press, or now.
//
// The trigger's state goes with the handlers, so no caller can forget it: `aria-expanded`,
// `aria-haspopup` and, while open, `aria-controls` naming the popup. A `Popover` takes that id as
// `id={trigger["aria-controls"]}`; a caller that draws its own popup passes its id as `popupId`.
import { useEffect, useId, useRef, type PointerEvent } from "react";
import { isMousePress, trackPressRelease } from "./pressRelease";

export interface PopoverTriggerOptions {
  /** The popup's role, for `aria-haspopup` (default `dialog`, a `Popover`'s role). */
  popup?: "dialog" | "listbox" | "menu";
  /** The popup's id, for `aria-controls` (default: one the hook makes). */
  popupId?: string;
}

export function usePopoverTrigger(
  open: boolean,
  setOpen: (open: boolean) => void,
  show?: () => void,
  { popup = "dialog", popupId }: PopoverTriggerOptions = {},
) {
  const ownId = useId();
  const controls = popupId ?? `${ownId}-popup`;
  const openAtPress = useRef<boolean | undefined>(undefined);
  // A mouse press already opened or closed it: the click it ends with does nothing.
  const pressed = useRef(false);
  const press = useRef<(() => void) | null>(null);
  // Clears the pressed marker; set while a mouse press holds the trigger.
  const unmark = useRef<(() => void) | null>(null);
  useEffect(
    () => () => {
      press.current?.();
      unmark.current?.();
    },
    [],
  );
  return {
    "aria-expanded": open,
    "aria-haspopup": popup,
    "aria-controls": open ? controls : undefined,
    onPointerDown: (event: PointerEvent<HTMLElement>) => {
      openAtPress.current = open;
      if (!isMousePress(event)) return;
      // Opening a menu moves focus into it, and the browser's transient :active state goes with it
      // before the held frame paints. The marker keeps that pressed tone until release; the composer
      // uses it to draw the first frame of a click the same as the open chip.
      const target = event.currentTarget;
      unmark.current?.();
      target.dataset.pressActive = "true";
      // A press can end with no pointerup reaching the page (the window loses focus, Escape), so
      // those clear the marker too.
      const view = target.ownerDocument.defaultView;
      const onKey = (key: KeyboardEvent) => {
        if (key.key === "Escape") clear();
      };
      const clear = () => {
        delete target.dataset.pressActive;
        view?.removeEventListener("blur", clear);
        target.ownerDocument.removeEventListener("keydown", onKey, true);
        if (unmark.current === clear) unmark.current = null;
      };
      view?.addEventListener("blur", clear);
      target.ownerDocument.addEventListener("keydown", onKey, true);
      unmark.current = clear;
      pressed.current = true;
      press.current?.();
      if (open) setOpen(false);
      else if (show) show();
      else setOpen(true);
      press.current = trackPressRelease(event, {
        close: open ? undefined : () => setOpen(false),
        end: (onTrigger) => {
          press.current = null;
          clear();
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
