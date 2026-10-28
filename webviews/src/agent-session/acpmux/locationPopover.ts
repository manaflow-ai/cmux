import { useEffect, useMemo, useRef } from "react";
import type { UiVirtualAnchor } from "../../ui/Popover";
import { useOpenSide } from "../../ui/openSide";
import { registerPicker } from "./pickerOpeners";

/// The location menus open next to their control, below it and away from the chat like the other
/// composer dropdowns. Every menu decides its side once when it opens by the shared rule
/// (`useOpenSide`): below when the full menu fits, flipping above only when below has less room.
/// It keeps that side while open (a filter shrinking the folder list never moves it, cx-ncc.53)
/// and fits the room.
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
  return { control, anchor, ...useOpenSide(control, "bottom", LOCATION_MENU_HEIGHT) };
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
