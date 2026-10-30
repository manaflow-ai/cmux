import { useEffect, useMemo, useRef } from "react";
import type { UiVirtualAnchor } from "../../ui/Popover";
import { useOpenSide } from "../../ui/openSide";
import { registerPicker } from "./pickerOpeners";

/// The location menus open below their control whenever the full menu fits there. If there is no
/// room below, the shared rule (`useOpenSide`) flips above only when that side fits or has more
/// room. The side is decided once on open and stays fixed while filtering or refreshing rows.
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
