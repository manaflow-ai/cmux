import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { UiVirtualAnchor } from "../../ui/Popover";
import type { UiPopupFlip, UiPopupSide } from "../../ui/openSide";
import { resolveUiSide } from "../../ui/anchor";
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
/// chat (`sideAwayFromChat`) when their shortest useful form fits there, and the list shrinks to the
/// room it got (`--available-height`). When it does not fit, they open on the other side. A menu
/// never covers its own control, so a second press on the control still closes it (Lucas
/// 2026-11-07). Anywhere else they open below whenever the full menu fits there, and the shared rule
/// (`resolveUiSide`) flips above only when that side fits or has more room. Either way the side is
/// decided once on open and stays fixed while filtering or refreshing rows.
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
  const [state, setState] = useState<{ open: boolean; side: UiPopupSide }>({ open: false, side: "bottom" });
  const setOpen = useCallback((open: boolean) => {
    const side = open ? locationMenuSide(control.current) : undefined;
    setState((last) => (last.open === open ? last : { open, side: side ?? last.side }));
  }, []);
  // The side is fixed on open and the popup fits the room there: it never flips or shifts onto its control.
  const flip: UiPopupFlip = false;
  return { control, anchor, open: state.open, setOpen, side: state.side, flip };
}

/// The side a location menu opens on, read once when it opens. In a composer: away from the chat when
/// the menu's shortest form fits there or that side has the more room, else the other side. Outside
/// a composer: below when the full menu fits or below has the more room, else above.
export function locationMenuSide(
  control: Element | null,
  viewportHeight = window.innerHeight,
): UiPopupSide | undefined {
  const rect = control?.getBoundingClientRect();
  if (!rect) return undefined;
  const away = sideAwayFromChat(control, viewportHeight);
  const resolved = away
    ? resolveUiSide(rect, LOCATION_MENU_MIN_HEIGHT, viewportHeight, { side: away === "top" ? "above" : "below" })
    : resolveUiSide(rect, LOCATION_MENU_HEIGHT, viewportHeight, { side: "below" });
  return resolved === "above" ? "top" : "bottom";
}

/// A location menu at its tallest: the folder list's cap (composerLocation.css), a field or
/// Choose folder…, and the menu's padding.
const LOCATION_MENU_HEIGHT = 320;

/// A location menu at its shortest useful size: the search field, the pinned actions (Add folder…,
/// No folder and the like), two folder rows and the menu's padding.
const LOCATION_MENU_MIN_HEIGHT = 220;

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
