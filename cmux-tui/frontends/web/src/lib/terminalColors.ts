import type { ITheme } from "@xterm/xterm";
import type { TerminalColors } from "cmux/browser";

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
