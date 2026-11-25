// The terminal theme's 16 ANSI colors as `--tasks-ansi-N` on the page root, each lifted only as far
// as it takes to read on the page (status and label marks are palette indices, decision in
// plans/cmux-next/tasks.md section 8). They follow every host theme change (`cmux-theme`).
import { followHostTerminalTheme, hostTerminalTheme } from "../../appearance";
import { parseHex, toHex } from "../../theme/color";
import { fit } from "../../theme/appTheme";

/** A mark's minimum contrast on the page (WCAG non-text contrast). */
export const MARK_CONTRAST = 3;

const DEFAULT_BACKGROUND = { dark: "#1d1f21", light: "#ffffff" };

/** The lifted palette of a terminal theme: index -> hex. */
export function readablePalette(
  palette: Record<string, string> | undefined,
  background: string,
): Record<number, string> {
  const on = parseHex(background);
  const out: Record<number, string> = {};
  if (!palette || !on) return out;
  for (let index = 0; index < 16; index += 1) {
    const color = parseHex(palette[String(index)] ?? "");
    if (color) out[index] = toHex(fit(color, [{ on, min: MARK_CONTRAST }]));
  }
  return out;
}

/** Sets the variables now and on every theme change; returns the unsubscribe. */
export function followTasksPalette(root: HTMLElement): () => void {
  return followHostTerminalTheme(() => {
    const theme = hostTerminalTheme();
    const background = theme?.background ?? DEFAULT_BACKGROUND[theme?.type === "light" ? "light" : "dark"];
    const palette = readablePalette(theme?.palette as Record<string, string> | undefined, background);
    for (let index = 0; index < 16; index += 1) {
      if (palette[index]) root.style.setProperty(`--tasks-ansi-${index}`, palette[index]);
      else root.style.removeProperty(`--tasks-ansi-${index}`);
    }
  });
}
