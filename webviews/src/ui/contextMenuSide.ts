/** A row's height in the menu, for the room a menu of `rows` rows needs (an estimate: the host draws it). */
const NATIVE_ROW_PX = 28;

/**
 * Whether a menu of `rows` rows at pointer height `y` opens upward: there is no room below it in the
 * page and more above (a hat over the composer at the window's bottom edge).
 */
/// The side the panel opens on: the page's flip applies only to the default "bottom"; a caller's own side stays.
export function popupSide<S extends string>(callerSide: S, flipped: "top" | "bottom"): S | "top" {
  return callerSide === "bottom" ? (flipped as S | "top") : callerSide;
}

export function opensUp(y: number, rows: number, viewportHeight = window.innerHeight): boolean {
  const need = rows * NATIVE_ROW_PX + 8;
  return viewportHeight - y < need && y > viewportHeight - y;
}
