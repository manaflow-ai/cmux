// The theme propagation matrix: every appearance knob, set live (no reload) through the same
// `window.cmuxTheme.apply` and `applyAgentTheme` calls the app makes, and every web surface checked
// for having picked it up. A cell is `live` (the surface changed with the knob), `missed` (it should
// have and did not), `still` (it should not, and did not) or `stray` (it changed though the knob does
// not reach it). The knobs only the native app can turn are listed in NATIVE_KNOBS with the Swift
// test that proves them live, or the gap that keeps them from it. Leo, 2026-11-04: "we have to make
// sure it actually propagates and that it propagates properly".
import type { AgentSessionTheme } from "../../agent-session/shared/types";
import { deriveAppTheme, type AppAccent } from "../../theme/appTheme";
import type { GhosttyTheme } from "./ghostty";
import { cardMaterial, tooltipSurface, worstContrast } from "./overlays";
import { composited, BLACK, contrast, wallpaperTintOpacity, WHITE, withAlpha, type ThemeTokens } from "./tokens";
import { agentPaneTheme, themeTokens, webThemePayload, type WebThemePayload } from "./web";

/** What a web page draws from: the shared variables, the app theme, the agent pane's theme, the
 * terminal colors code pages read, the glass mode and the motion policy. */
export const SURFACES = ["pages", "appTheme", "agentPane", "terminal", "glass", "motion"] as const;
export type Surface = (typeof SURFACES)[number];

export const SURFACE_LABELS: Record<Surface, string> = {
  pages: "Pages (--cmux-*)",
  appTheme: "App theme (--cmux-app-*)",
  agentPane: "Agent pane (--agent-*)",
  terminal: "Terminal colors",
  glass: "Glass (data-glass)",
  motion: "Motion (data-cmux-motion)",
};

/** One state of every knob the web side models. */
export type KnobState = {
  theme: string;
  accent: AppAccent;
  /** A picture behind the window (`appearance.background`): pages go see-through. */
  picture: boolean;
  borders: "lines" | "none";
  reducedMotion: boolean;
  glass: "plain" | "lens" | "spectrum";
};

export const BASE_STATE: KnobState = {
  theme: "Catppuccin Mocha",
  accent: "neutral",
  picture: false,
  borders: "lines",
  reducedMotion: false,
  glass: "plain",
};

export type Knob = {
  /** The cmux-next.json key (or the system setting) the knob is. */
  key: string;
  label: string;
  to: Partial<KnobState>;
  reaches: readonly Surface[];
};

export const KNOBS: readonly Knob[] = [
  {
    key: "appearance.theme",
    label: "Ghostty theme",
    to: { theme: "Gruvbox Dark" },
    reaches: ["pages", "appTheme", "agentPane", "terminal"],
  },
  {
    key: "appearance.theme (light side)",
    label: "System appearance flips to the light theme",
    to: { theme: "Catppuccin Latte" },
    reaches: ["pages", "appTheme", "agentPane", "terminal"],
  },
  { key: "appearance.accent", label: "Accent", to: { accent: "theme" }, reaches: ["pages", "appTheme", "agentPane"] },
  { key: "appearance.background", label: "Background picture", to: { picture: true }, reaches: ["pages", "agentPane"] },
  { key: "appearance.borders", label: "Borders", to: { borders: "none" }, reaches: ["pages", "agentPane"] },
  { key: "glass.lensMode", label: "Glass lens", to: { glass: "lens" }, reaches: ["glass"] },
  { key: "Reduce Motion", label: "Reduce Motion", to: { reducedMotion: true }, reaches: ["agentPane", "motion"] },
];

/** The knobs only the native app turns, and what proves each live (or why it is not yet). */
export const NATIVE_KNOBS: readonly { key: string; status: "live" | "gap"; proof: string }[] = [
  {
    key: "appearance.appTheme",
    status: "live",
    proof: "ThemeLivePreviewTests.previewingAnAppThemeReachesTheChromeAndEndingRevertsIt",
  },
  {
    key: "appearance.themeEdits",
    status: "live",
    proof: "ThemeLivePreviewTests.previewingATerminalThemeShowsItAndEndingRevertsIt",
  },
  {
    key: "appearance.hue / saturation / glassTransparency",
    status: "live",
    proof: "ThemeLivePreviewTests.previewingHueTintsTheWindowBeforeItIsSaved",
  },
  {
    key: "appearance.backgroundOpacity / backgroundBlur",
    status: "live",
    proof: "ThemeBridge.repaintBackground, then a Ghostty reload 60 ms after the last slider step",
  },
  {
    key: "sidebar.density / ui.interfaceSize",
    status: "live",
    proof: "SettingsLiveAppearanceTests.interfaceSizeReachesNativeAndWebTypeAndResetsThroughThePage",
  },
  {
    key: "terminal font family / size",
    status: "live",
    proof:
      "applies on save; slider previews skip the reload on purpose (ThemeLivePreviewTests.aSliderPreviewDoesNotReloadTheTerminals)",
  },
  {
    key: "appearance.accent = art (Art Color)",
    status: "gap",
    proof:
      "pages' --cmux-app-accent keeps the old art's hue after a shuffle or a new pick (ThemeCoordinator.applyChromeTheme runs only on theme and accent changes)",
  },
  {
    key: "appearance.highlightColor",
    status: "gap",
    proof: "its live preview never shows: TerminalThemeSetting.take reads snapshot.highlightColor, not applied",
  },
  {
    key: "CMUX_NEXT_DEBUG_LEGACY_MATERIAL",
    status: "gap",
    proof: "debug environment variable read once at launch (Glass.swift); restart-bound by design",
  },
];

export type Applied = { web: WebThemePayload; agent: AgentSessionTheme; tokens: ThemeTokens };

/** What the app sends every web page for `state`, as WebTheme.swift and AgentPaneTheme.swift build it. */
export function appliedTheme(state: KnobState, themes: readonly GhosttyTheme[]): Applied {
  const theme = themes.find((candidate) => candidate.name === state.theme);
  if (!theme) throw new Error(`propagation: no shipped theme named ${state.theme}`);
  const tokens = themeTokens(theme, state.accent);
  const web = webThemePayload(tokens, deriveAppTheme(theme, state.accent), state.picture, {
    borders: state.borders,
    reducedMotion: state.reducedMotion,
    glass: state.glass,
  });
  const agent = agentPaneTheme(tokens, state.reducedMotion, state.picture, state.borders) as AgentSessionTheme;
  return { web, agent, tokens };
}

/** A fingerprint of each surface as a page reads it back from its document. */
export function readSurfaces(doc: Document): Record<Surface, string> {
  const root = doc.documentElement;
  const style = root.style;
  const names: string[] = [];
  for (let index = 0; index < style.length; index += 1) names.push(style.item(index));
  const values = (keep: (name: string) => boolean) =>
    names
      .filter(keep)
      .sort()
      .map((name) => `${name}=${style.getPropertyValue(name).trim()}`)
      .join(";");
  const current = (doc.defaultView as unknown as { cmuxTheme?: { current?: WebThemePayload | null } }).cmuxTheme
    ?.current;
  return {
    pages: values((name) => name.startsWith("--cmux-") && !name.startsWith("--cmux-app-")),
    appTheme: values((name) => name.startsWith("--cmux-app-")),
    agentPane: `${values((name) => name.startsWith("--agent-") && !name.startsWith("--agent-ansi-"))};borders=${root.dataset.borders ?? "lines"}`,
    terminal: `${values((name) => name.startsWith("--agent-ansi-"))};${JSON.stringify(current?.terminal ?? null)}`,
    glass: root.getAttribute("data-glass") ?? "",
    motion: `${root.getAttribute("data-cmux-motion") ?? ""};${root.getAttribute("data-status-indicators") ?? ""}`,
  };
}

export type Cell = "live" | "missed" | "still" | "stray";
export type MatrixRow = { knob: Knob; cells: Record<Surface, Cell> };

/**
 * Runs the matrix: for each knob, applies the base state, reads every surface, applies the knob's
 * state over it, and reads again. `apply` must change the page the way the app does (no reload).
 */
export function runPropagationMatrix(
  apply: (applied: Applied) => void,
  read: () => Record<Surface, string>,
  themes: readonly GhosttyTheme[],
  knobs: readonly Knob[] = KNOBS,
): MatrixRow[] {
  return knobs.map((knob) => {
    apply(appliedTheme(BASE_STATE, themes));
    const before = read();
    apply(appliedTheme({ ...BASE_STATE, ...knob.to }, themes));
    const after = read();
    const cells = Object.fromEntries(
      SURFACES.map((surface) => {
        const changed = before[surface] !== after[surface];
        const expected = knob.reaches.includes(surface);
        const cell: Cell = expected ? (changed ? "live" : "missed") : changed ? "stray" : "still";
        return [surface, cell];
      }),
    ) as Record<Surface, Cell>;
    return { knob, cells };
  });
}

/** The cells that fail: a surface the knob should reach that kept its old value, or one it should
 * not reach that changed. */
export const failures = (rows: readonly MatrixRow[]): string[] =>
  rows.flatMap((row) =>
    SURFACES.filter((surface) => row.cells[surface] === "missed" || row.cells[surface] === "stray").map(
      (surface) => `${row.knob.key} -> ${surface}: ${row.cells[surface]}`,
    ),
  );

/** Contrast of a theme's text over the glass and the wallpaper, on the worst backdrop (pure black or
 * pure white behind the material): tooltips and cards guarantee 4.5:1; the window's tint over a
 * picture is what the wallpaper palette work (step 3) has to hold. */
export function glassContrast(tokens: ThemeTokens): {
  tooltip: number;
  card: number;
  wallpaperText: number;
  wallpaperSecondary: number;
} {
  const tooltip = tooltipSurface(tokens);
  const card = cardMaterial(tokens);
  const tint = withAlpha(tokens.windowBackground, wallpaperTintOpacity(tokens));
  const over = (ink: ThemeTokens["textPrimary"]) =>
    Math.min(
      contrast(withAlpha(ink, 1), composited(tint, BLACK)),
      contrast(withAlpha(ink, 1), composited(tint, WHITE)),
    );
  return {
    tooltip: worstContrast(tooltip.ink, tooltip.tint),
    card: Math.min(worstContrast(tokens.textPrimary, card.tint), worstContrast(tokens.textSecondary, card.tint)),
    wallpaperText: over(tokens.textPrimary),
    wallpaperSecondary: over(tokens.textSecondary),
  };
}
