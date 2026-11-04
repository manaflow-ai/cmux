// `host=app`: the stage runs inside a cmux app's own window (GalleryStageView, CmuxNextApp), not a
// gallery shell. The app installed its WebTheme bootstrap and its live payload at document start and
// draws its own backdrop behind the page, so the stage keeps both instead of the gallery's: the theme,
// accent, scale and picture are the person's own, and change with the app's.
import type { GhosttyTheme } from "../theme/ghostty";

type HostTerminal = {
  background?: unknown;
  foreground?: unknown;
  palette?: unknown;
  selectionBackground?: unknown;
};
type HostThemeWindow = Window & { cmuxTheme?: { current?: { terminal?: HostTerminal } | null } };

/** Whether the frame asked for the app host and an app's theme bootstrap is in place. */
export function isAppHosted(params: URLSearchParams): boolean {
  return params.get("host") === "app" && typeof (window as HostThemeWindow).cmuxTheme === "object";
}

/**
 * The app's terminal colors (WebTheme.swift `terminal`) as a Ghostty theme, so the stage's own
 * derived tokens (the agent pane theme, the diff appearance) match the app's; undefined when the
 * app sent none.
 */
export function appHostTheme(): GhosttyTheme | undefined {
  const terminal = (window as HostThemeWindow).cmuxTheme?.current?.terminal;
  if (!terminal || typeof terminal.background !== "string" || typeof terminal.foreground !== "string") return undefined;
  const slots =
    terminal.palette && typeof terminal.palette === "object" ? (terminal.palette as Record<string, unknown>) : {};
  const palette = Array.from({ length: 16 }, (_, index) => {
    const color = slots[String(index)];
    return typeof color === "string" ? color : null;
  });
  return {
    name: "cmux app",
    background: terminal.background,
    foreground: terminal.foreground,
    palette,
    ...(typeof terminal.selectionBackground === "string" ? { selectionBackground: terminal.selectionBackground } : {}),
  };
}
