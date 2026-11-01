// A portaled popover's side is decided once, when it opens (cx-ncc.53): Base UI's positioner
// would flip it whenever its height changes against the room left (a filter shrinking the list,
// rows loading), so the composer's location menus could jump between above and below their chip
// while open, each on its own. `useOpenSide` resolves the side with the shared rule
// (`resolveUiSide`) from the control's room at the moment it opens; the popup then keeps it
// (`flip={false}`) and fits the room it got (`--available-height`).
import { useCallback, useState, type RefObject } from "react";
import { resolveUiSide } from "./anchor";

export type UiPopupSide = "top" | "bottom";

/// How a portaled popup keeps clear of the window's edges. `true`: it flips to the other side when
/// this one has no room (Base UI's default). `false`: it keeps `side` and fits the room it got
/// (`useOpenSide` chose the side). `"shift"`: it keeps `side` and slides along it, over its own
/// anchor, to stay in the window: a composer's location menu that must not open onto the chat.
export type UiPopupFlip = boolean | "shift";

/// Base UI's `collisionAvoidance` for a `UiPopupFlip` (undefined: Base UI's default, which flips).
export function popupCollision(flip: UiPopupFlip) {
  if (flip === true) return undefined;
  if (flip === "shift") return { side: "shift", align: "shift", fallbackAxisSide: "none" } as const;
  return { side: "none" } as const;
}

/// `open` and `setOpen` for a popover whose side is chosen when `setOpen(true)` runs: `preferred`
/// when `height` fits there or it has the more room, else the other side.
export function useOpenSide(
  control: RefObject<HTMLElement | null>,
  preferred: UiPopupSide,
  height: number,
): { open: boolean; setOpen(open: boolean): void; side: UiPopupSide } {
  const [state, setState] = useState<{ open: boolean; side: UiPopupSide }>({ open: false, side: preferred });
  const setOpen = useCallback(
    (open: boolean) => {
      const rect = open ? control.current?.getBoundingClientRect() : undefined;
      const fits =
        rect && resolveUiSide(rect, height, window.innerHeight, { side: preferred === "top" ? "above" : "below" });
      setState((last) =>
        last.open === open ? last : { open, side: fits ? (fits === "above" ? "top" : "bottom") : last.side },
      );
    },
    [control, preferred, height],
  );
  return { open: state.open, setOpen, side: state.side };
}
