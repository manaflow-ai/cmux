import { useCallback, useEffect, useMemo, useRef, useState, useContext } from "react";
import type { UiVirtualAnchor } from "../../ui/Popover";
import type { UiPopupFlip, UiPopupSide } from "../../ui/openSide";
import { resolveUiSide } from "../../ui/anchor";
import { interfaceScale, viewOf } from "../../ui/interfaceScale";
import { registerPicker, ChatViewParked } from "./pickerOpeners";

/// The composer a location control heads: the chat pane's form, or the New Tab page's composer.
const COMPOSER = "form.acpmux-composer, .nt-composer";

/// The composer's text field: the chat pane's prompt (ProseMirror or its textarea) or New Tab's field.
const COMPOSER_FIELD = ".acpmux-composer-box .ProseMirror, .acpmux-composer-box textarea, .nt-field";

/// The side away from the composer's text field (Leo 2026-11-22: "the things should usually if
/// possible open away from the text input"). A control over the field (the folder, computer and
/// branch strip) opens up; one under it (the foot chips) opens down, so a menu never draws over the
/// prompt and the chips beside it when the other side has room. Lucas saw the folder menu open down
/// over the field and the "Bypass permissions" chip on a New Tab composer just under the window's
/// middle (the 2026-10-29 rule below sent it down). Read from where the control and the field sit
/// when the menu opens. No composer, or a composer whose field is not drawn: undefined.
export function sideAwayFromInput(control: Element | null): UiPopupSide | undefined {
  const field = control?.closest(COMPOSER)?.querySelector(COMPOSER_FIELD);
  const box = field?.getBoundingClientRect();
  if (!control || !box || box.height <= 0) return undefined;
  const own = control.getBoundingClientRect();
  return (own.top + own.bottom) / 2 <= (box.top + box.bottom) / 2 ? "top" : "bottom";
}

/// The side away from the conversation (Leo 2026-10-29: "make them open away from teh chat, which
/// is obviously up if it's up, down if it's down"), now only the fallback when no text field is
/// drawn (`sideAwayFromInput` comes first). It is read from where the composer sits in the
/// window when the menu opens, never from which page it is: a composer in the lower half has the
/// chat above it, so its menus open down; one in the upper half (New Tab, with the chats under it)
/// opens them up. Outside a composer there is no chat to keep clear: undefined.
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
/// text field (`sideAwayFromInput`; `sideAwayFromChat` when no field is drawn) when their shortest
/// useful form fits there, and the list shrinks to the room it got (`--available-height`). When it
/// does not fit, they open on the other side. A menu
/// never covers its own control, so a second press on the control still closes it (Lucas
/// 2026-11-07). Anywhere else they open below whenever the full menu fits there, and the shared rule
/// (`resolveUiSide`) flips above only when that side fits or has more room. Either way the side is
/// decided once on open and stays fixed while filtering or refreshing rows. `listCap`: the menu's own
/// list cap when it is not the shared one (the folder menu's taller list, FOLDER_MENU_LIST_CAP).
/// `shortest`: its own shortest useful height at the default Text Size; `setOpen(true, height)`
/// gives it for this open instead (the folder menu's, `folderMenuShortest` of the rows it has now).
export function useLocationPopover({
  listCap = LOCATION_FOLDERS_CAP,
  shortest = LOCATION_MENU_MIN_HEIGHT,
}: { listCap?: number; shortest?: number } = {}) {
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
  const setOpen = useCallback(
    (open: boolean, shortestNow = shortest) => {
      const side = open ? locationMenuSide(control.current, window.innerHeight, listCap, shortestNow) : undefined;
      setState((last) => (last.open === open ? last : { open, side: side ?? last.side }));
    },
    [listCap, shortest],
  );
  // The side is fixed on open and the popup fits the room there: it never flips or shifts onto its control.
  const flip: UiPopupFlip = false;
  return { control, anchor, open: state.open, setOpen, side: state.side, flip };
}

/// The side a location menu opens on, read once when it opens. In a composer: away from its text
/// field when the menu's shortest form, or at least `AWAY_FROM_INPUT_FLOOR`, fits there or that side
/// has the more room, else the other side; with no field drawn, away from the chat by the same
/// measure without the floor. Outside a composer: below when the full menu fits or below has the
/// more room, else above.
export function locationMenuSide(
  control: Element | null,
  viewportHeight = window.innerHeight,
  listCap = LOCATION_FOLDERS_CAP,
  shortestAtDefault = LOCATION_MENU_MIN_HEIGHT,
): UiPopupSide | undefined {
  const rect = control?.getBoundingClientRect();
  if (!rect) return undefined;
  const scale = interfaceScale(viewOf(control));
  const { tallest, shortest } = locationMenuHeights(scale, listCap, shortestAtDefault);
  // Away from the text field the menu stays while the search field and a few rows fit, its list
  // scrolling in the room it got: the other side covers the prompt and the chips beside it.
  const clearOfInput = sideAwayFromInput(control);
  const away = clearOfInput ?? sideAwayFromChat(control, viewportHeight);
  const needs = clearOfInput ? Math.min(shortest, AWAY_FROM_INPUT_FLOOR * scale) : shortest;
  const resolved = away
    ? resolveUiSide(rect, needs, viewportHeight, { side: away === "top" ? "above" : "below" })
    : resolveUiSide(rect, tallest, viewportHeight, { side: "below" });
  return resolved === "above" ? "top" : "bottom";
}

/// The least room a menu keeps on the side away from the text field, at the default Text Size: its
/// search field, three rows and padding. Short of it the menu takes the other side.
export const AWAY_FROM_INPUT_FLOOR = 150;

/// The folder list's cap (`.acpmux-location-folders`, composerLocation.css): a fixed height its rows
/// scroll in, at any Text Size.
const LOCATION_FOLDERS_CAP = 260;

/// The folder menu's (FolderPopover) list cap: its designed scroll height (`--popup-scroll-cap` on
/// `.acpmux-folder-popover .acpmux-location-folders`, composerLocation.css), taller than the shared one.
export const FOLDER_MENU_LIST_CAP = 440;

/// What a location menu draws around its folder list at the default Text Size: a field or Choose
/// folder… and the menu's padding. Rows and padding follow Text Size.
const LOCATION_MENU_CHROME = 60;

/// A location menu at its shortest useful size at the default Text Size: the search field, the
/// pinned actions (Add folder…, No folder and the like), two folder rows and the menu's padding.
/// All rows, so all of it follows Text Size.
const LOCATION_MENU_MIN_HEIGHT = 220;

/// The folder menu's (FolderPopover) shortest size that cuts nothing, at the default Text Size: the
/// search field with the menu's padding and rule, up to three of its `listRows` folder rows and every
/// one of its `actions` (Add folder…, the GitHub row, No folder and the like). The side away from the
/// chat is taken when this fits there (a New Tab menu with a few rows opens up, as designed); on a
/// side with less room the list is squeezed and the actions scroll, so that side is taken only when
/// the other has less still.
export function folderMenuShortest(listRows: number, actions: number): number {
  return (
    FOLDER_MENU_FRAME +
    Math.min(3, Math.max(0, listRows)) * FOLDER_MENU_LIST_ROW +
    Math.max(0, actions) * FOLDER_MENU_ACTION_ROW
  );
}

/// The folder menu around its rows: the search field, the rule over the actions and the padding.
const FOLDER_MENU_FRAME = 54;
/// A folder row with the gap under it (the chat's list; New Tab's rows are 28), and an action's row.
const FOLDER_MENU_LIST_ROW = 30;
const FOLDER_MENU_ACTION_ROW = 28;

/// The heights that pick a location menu's side at interface scale `scale`, CSS px: at its tallest
/// (the list at its cap) and at its shortest useful size. The rows grow with Text Size, so a side
/// with room for the menu at 12 pt can be short of it at 16 (Leo, 2026-11-12: "it doesn't follow").
/// `listCap`: the menu's list cap (the shared one unless the menu has its own); `shortest`: its
/// shortest useful height at the default Text Size (the shared one unless the menu has its own).
export function locationMenuHeights(
  scale: number,
  listCap = LOCATION_FOLDERS_CAP,
  shortest = LOCATION_MENU_MIN_HEIGHT,
): { tallest: number; shortest: number } {
  return {
    tallest: listCap + LOCATION_MENU_CHROME * scale,
    shortest: shortest * scale,
  };
}

/// Automation opens a location menu by its stable name (`openPicker`: "Computer", "Location"),
/// as a click does: the focus leaves the prompt, then the menu opens. A label (a started chat)
/// registers nothing.
export function useLocationOpener(name: string | undefined, open: () => void) {
  const latest = useRef(open);
  latest.current = open;
  const parked = useContext(ChatViewParked);
  useEffect(() => {
    if (!name || parked) return;
    return registerPicker(name, () => {
      if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
      latest.current();
    });
  }, [name, parked]);
}
