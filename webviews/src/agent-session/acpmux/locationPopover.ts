import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { UiVirtualAnchor } from "../../ui/Popover";
import { useOpenSide, type UiPopupFlip, type UiPopupSide } from "../../ui/openSide";
import { registerPicker } from "./pickerOpeners";

/// The composer a location control heads: the chat pane's form, or the New Tab page's composer.
const COMPOSER = "form.acpmux-composer, .nt-composer";

/// The side away from the conversation (Leo 2026-10-29: "make them open away from teh chat, which
/// is obviously up if it's up, down if it's down"). It is read from where the composer sits in the
/// window when the menu opens, never from which page it is: a composer in the lower half has the
/// chat above it, so its menus open down over the composer; one in the upper half (New Tab, with
/// the chats under it) opens them up. Outside a composer there is no chat to keep clear: undefined.
export function sideAwayFromChat(
  control: Element | null,
  viewportHeight = window.innerHeight,
): UiPopupSide | undefined {
  const composer = control?.closest(COMPOSER);
  if (!composer) return undefined;
  const box = composer.getBoundingClientRect();
  return (box.top + box.bottom) / 2 >= viewportHeight / 2 ? "bottom" : "top";
}

/// The location menus (project, machine, branch). In a composer they open on the side away from the
/// chat (`sideAwayFromChat`) and keep it: when that side is short of room, the menu shifts along
/// it to stay in the window, over its own composer, instead of flipping onto the conversation
/// (`flip: "shift"`). Anywhere else they open below whenever the full menu fits there, and the
/// shared rule (`useOpenSide`) flips above only when that side fits or has more room. Either way
/// the side is decided once on open and stays fixed while filtering or refreshing rows.
export function useLocationPopover() {
  const control = useRef<HTMLSpanElement>(null);
  const anchor = useMemo<UiVirtualAnchor>(
    () => ({
      getBoundingClientRect: () => control.current?.getBoundingClientRect() ?? new DOMRect(),
      get contextElement() {
        return control.current ?? undefined;
      },
    }),
    [],
  );
  const shared = useOpenSide(control, "bottom", LOCATION_MENU_HEIGHT);
  const sharedSetOpen = shared.setOpen;
  const [away, setAway] = useState<UiPopupSide | undefined>(undefined);
  const setOpen = useCallback(
    (open: boolean) => {
      if (open) setAway(sideAwayFromChat(control.current));
      sharedSetOpen(open);
    },
    [sharedSetOpen],
  );
  const flip: UiPopupFlip = away ? "shift" : false;
  return { control, anchor, open: shared.open, setOpen, side: away ?? shared.side, flip };
}

/// A location menu at its tallest: the folder list's cap (composerLocation.css), a field or
/// Choose folder…, and the menu's padding.
const LOCATION_MENU_HEIGHT = 320;

/// Automation opens a location menu by its stable name (`openPicker`: "Computer", "Location"),
/// as a click does: the focus leaves the prompt, then the menu opens. A label (a started chat)
/// registers nothing.
export function useLocationOpener(name: string | undefined, open: () => void) {
  const latest = useRef(open);
  latest.current = open;
  useEffect(() => {
    if (!name) return;
    return registerPicker(name, () => {
      if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
      latest.current();
    });
  }, [name]);
}
