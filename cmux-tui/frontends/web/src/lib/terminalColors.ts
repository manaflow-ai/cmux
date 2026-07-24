import type { ITerminalOptions, ITheme } from "@xterm/xterm";
import type { TerminalColors } from "cmux/browser";

type CursorColors = {
  cursor_style?: unknown;
  cursor_blink?: unknown;
};

export type CursorOptionsPatch = Partial<Pick<ITerminalOptions, "cursorStyle" | "cursorBlink">>;

/** Map host-owned selection colors without changing xterm's OSC restore defaults. */
export function colorsToSelectionThemePatch(
  colors: Partial<TerminalColors> | null | undefined,
): ITheme | null {
  if (colors == null) return null;

  const patch: ITheme = {};
  if (colors.selection_bg != null) patch.selectionBackground = colors.selection_bg;
  if (colors.selection_fg != null) patch.selectionForeground = colors.selection_fg;
  return patch;
}

/** Apply effective OSC 10/11/12 colors without replacing xterm's restore baseline. */
export function colorsToDynamicColorSequence(
  colors: Partial<TerminalColors> | null | undefined,
): string | null {
  if (colors == null) return null;

  let sequence = "";
  if (colors.fg != null) sequence += `\x1b]10;${colors.fg}\x1b\\`;
  if (colors.bg != null) sequence += `\x1b]11;${colors.bg}\x1b\\`;
  if (colors.cursor != null) sequence += `\x1b]12;${colors.cursor}\x1b\\`;
  return sequence || null;
}

/** Reset xterm's live palette to its host theme, then apply PTY-authored OSC 4 entries. */
export function colorsToPaletteSequence(
  colors: Partial<TerminalColors> | null | undefined,
): string | null {
  if (colors?.palette === undefined) return null;

  const overrides: Array<[number, string]> = [];
  for (const [rawIndex, color] of Object.entries(colors.palette)) {
    const index = Number(rawIndex);
    if (!Number.isInteger(index) || index < 0 || index > 255) continue;
    overrides.push([index, color]);
  }
  overrides.sort(([left], [right]) => left - right);
  return `\x1b]104\x1b\\${overrides
    .map(([index, color]) => `\x1b]4;${index};${color}\x1b\\`)
    .join("")}`;
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
