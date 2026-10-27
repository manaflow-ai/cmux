// A right-click menu (ContextMenu.tsx) shows as a standard macOS menu the app draws (Lawrence
// 2026-10-23: "we don't want ANYTHING custom besides the icons"): the page sends its rows and the
// pointer, the host pops an NSMenu up there and answers `{picked}`, the chosen row's id or null
// (CmuxNextDesign WebContextMenu). A page in the app installs the host's call at boot
// (pageClient.ts, the agent pane's legacy bridge); the dev loop and the gallery have none and keep
// the page-drawn menu.

export interface NativeMenuRow {
  id: string;
  label: string;
  /** The row's icon: an SF Symbol, or an icon pack name the app pairs with one. */
  symbol?: string;
  disabled?: boolean;
  /** A toggle's state, rendered as a native checkmark. */
  checked?: boolean;
  separator?: boolean;
}

export interface NativeMenuRequest {
  items: NativeMenuRow[];
  /** The pointer, in CSS px in the page's viewport. */
  point: { x: number; y: number };
}

/** The host's call: resolves to its reply (`{picked}`); rejects when the host has no native menu. */
export type NativeMenu = (request: NativeMenuRequest) => Promise<unknown>;

/** The page host's op (PageNativeOp.contextMenu). */
export const NATIVE_MENU_OP = "cmux.app.contextMenu.show";

let installed: NativeMenu | null = null;

/** Sets the page's native menu; null removes it (tests). */
export function installNativeMenu(menu: NativeMenu | null): void {
  installed = menu;
}

/** The page's native menu, or null where the page draws its own. */
export function nativeMenu(): NativeMenu | null {
  return installed;
}

/** The chosen row's id in the host's reply, or null when the menu was dismissed. */
export function pickedId(reply: unknown): string | null {
  const picked = (reply as { picked?: unknown } | null)?.picked;
  return typeof picked === "string" ? picked : null;
}
