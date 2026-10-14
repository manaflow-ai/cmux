import { useEffect, useMemo, useRef } from "react";
import type { UiVirtualAnchor } from "../../ui/Popover";
import { useOpenSide } from "../../ui/openSide";
import { registerPicker } from "./pickerOpeners";

/// The location menus open next to their control: on its top side, the way the model menu opens
/// above its chip (Lawrence 2026-10-08: "popover is not next to the button"; this replaces
/// cx-yrgh's anchor at the card's top edge, which left the card's height between the two). Every
/// location menu decides its side once, when it opens, by the shared rule (`useOpenSide`): above
/// unless the menu's full height does not fit there and below has more room. It keeps that side
/// while open (a filter shrinking the folder list never moves it, cx-ncc.53) and fits the room.
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
  return { control, anchor, ...useOpenSide(control, "top", LOCATION_MENU_HEIGHT) };
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
