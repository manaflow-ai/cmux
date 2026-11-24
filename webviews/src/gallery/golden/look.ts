// A look as the golden screen draws it (looks.json, resolved by dev-server/goldenLooks.ts): the theme
// file of each scheme, the setup's settings, the chat stylesheet and the composer's look. The stage
// frame (frame/main.ts), the agent pane host (frame/agentPane.ts) and the mock app's window
// (mock-app/main.ts) each apply their part, as the app applies a setup's parts to its own.
import type { GhosttyTheme } from "../theme/ghostty";

/** One scheme's theme file, the keys the gallery can draw. */
export type GoldenScheme = {
  /** Where it came from (a repo path, or looks.json for an inline one). */
  source?: string;
  name?: string;
  /** `appearance.theme`: a Ghostty theme's name; absent or unknown keeps the scheme's default. */
  theme?: string;
  /** `colors`: over the terminal theme's own. */
  colors?: { background?: string; foreground?: string; selection?: string; accent?: string };
  /** `appearance.accent` (theme/appTheme.ts APP_ACCENTS). */
  accent?: string;
  /** `appearance.selection`: `neutral` keeps the selection fill gray under any accent. */
  selection?: "accent" | "neutral";
  /** `appearance.surfaces.sidebar.color` and `appearance.surfaces.agentPane.color`. */
  surfaces?: { sidebar?: string; agentPane?: string };
  /** `appearance.density`. */
  density?: "compact" | "comfortable";
};

export type GoldenLook = {
  id: string;
  title: string;
  note: string;
  source: string;
  /** The setup's settings: `agentPane.*` go to the chat's display push, `sidebar.*` to the window. */
  settings: Record<string, unknown>;
  schemes: { light: GoldenScheme; dark: GoldenScheme };
  /** agent-pane/theme.css (cmux.agentPane.style/1 tokens). */
  themeCSS?: string;
  composerLook?: "claude" | "codex";
};

export type Scheme = "light" | "dark";

/** The scheme a stage draws: the env's, `auto` meaning dark (the gallery's default theme is dark). */
export const schemeOf = (colorScheme: string): Scheme => (colorScheme === "light" ? "light" : "dark");

/** The terminal theme under a look's scheme: its named theme (else `base`), with its `colors` over it. */
export function lookTheme(
  scheme: GoldenScheme,
  base: GhosttyTheme,
  named: (name: string) => GhosttyTheme | undefined,
): GhosttyTheme {
  const theme = (scheme.theme && named(scheme.theme)) || base;
  const colors = scheme.colors ?? {};
  return {
    ...theme,
    name: scheme.name ?? theme.name,
    ...(colors.background && { background: colors.background }),
    ...(colors.foreground && { foreground: colors.foreground }),
    ...(colors.selection && { selectionBackground: colors.selection }),
    ...(colors.accent && { accent: colors.accent }),
  };
}

/** The chat's display push from a look's settings (its `agentPane.*` keys). */
export function lookDisplay(look: GoldenLook): Record<string, unknown> {
  return Object.fromEntries(Object.entries(look.settings).filter(([key]) => key.startsWith("agentPane.")));
}

/** A setting of the look, or `fallback`. */
export function lookSetting<T>(look: GoldenLook | undefined, key: string, fallback: T): T {
  const value = look?.settings[key];
  return value === undefined ? fallback : (value as T);
}

/** The setup's `agentPane.composerLook` when it names a look ("auto", the default, names none): the
 * composer the app draws for it, as the host's composer push would pick it. */
export function lookComposerLook(look: GoldenLook): string | undefined {
  const value = look.settings["agentPane.composerLook"];
  return typeof value === "string" && value !== "auto" ? value : undefined;
}
