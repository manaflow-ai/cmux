import type { ITerminalOptions, ITheme } from "@xterm/xterm";
import type { TerminalColors } from "cmux/browser";

type CursorColors = {
  cursor_style?: unknown;
  cursor_blink?: unknown;
};

export type CursorOptionsPatch = Partial<Pick<ITerminalOptions, "cursorStyle" | "cursorBlink">>;

/** Map protocol special colors without synthesizing indexed ANSI colors. */
export function colorsToThemePatch(
  colors: Partial<TerminalColors> | null | undefined,
): ITheme | null {
  if (colors == null) return null;

  const patch: ITheme = {};
  if (colors.bg != null) patch.background = colors.bg;
  if (colors.fg != null) patch.foreground = colors.fg;
  if (colors.cursor != null) patch.cursor = colors.cursor;
  if (colors.selection_bg != null) patch.selectionBackground = colors.selection_bg;
  if (colors.selection_fg != null) patch.selectionForeground = colors.selection_fg;
  return patch;
}

/** Map protocol cursor metadata while ignoring null and unknown wire values. */
export function colorsToCursorOptionsPatch(
  colors: CursorColors | null | undefined,
): CursorOptionsPatch | null {
  if (colors == null) return null;

  const patch: CursorOptionsPatch = {};
  if (
    colors.cursor_style === "block"
    || colors.cursor_style === "underline"
    || colors.cursor_style === "bar"
  ) {
    patch.cursorStyle = colors.cursor_style;
  }
  if (typeof colors.cursor_blink === "boolean") patch.cursorBlink = colors.cursor_blink;
  return patch;
}
