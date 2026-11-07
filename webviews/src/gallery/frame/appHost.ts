// `host=app`: the stage runs inside a cmux app's own window (GalleryStageView, CmuxNextPages), not a
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
type HostThemeWindow = Window & {
  cmuxTheme?: { current?: { terminal?: HostTerminal; variables?: Record<string, unknown> } | null };
};

/** The app's `--cmux-*` value `name` (WebTheme.swift `variables`), or undefined. */
function hostVariable(name: string): string | undefined {
  const value = (window as HostThemeWindow).cmuxTheme?.current?.variables?.[name];
  return typeof value === "string" ? value : undefined;
}

/** `rgba(r, g, b, a)` (WebTheme.css) as its channels, or undefined. */
function rgba(value: string | undefined): [number, number, number, number] | undefined {
  const match = value?.match(/^rgba\(\s*(\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\s*\)$/);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3]), Number(match[4])] : undefined;
}

/** Whether the app's window shows its backdrop through pages: its page background is clear. */
export function appHostSeeThrough(): boolean {
  return rgba(hostVariable("--cmux-surface-background"))?.[3] === 0;
}

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
  // The app's resolved accent, as a theme's own accent (which wins over `appearance.accent`).
  const accent = rgba(hostVariable("--cmux-accent"));
  return {
    name: "cmux app",
    ...(accent
      ? {
          accent: `#${accent
            .slice(0, 3)
            .map((channel) => channel.toString(16).padStart(2, "0"))
            .join("")}`,
        }
      : {}),
    background: terminal.background,
    foreground: terminal.foreground,
    palette,
    ...(typeof terminal.selectionBackground === "string" ? { selectionBackground: terminal.selectionBackground } : {}),
  };
}
