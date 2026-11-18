export type HeroAppearance = "system" | "light" | "dark";

export type HeroTerminalTheme = {
  id: string;
  label: string;
  background: string;
  foreground: string;
  palette: readonly string[];
  cursor: string;
};

// These values are copied from the Ghostty theme files used by cmux NEXT.
// Keep the semantic names below aligned with WebTheme.swift so the landing
// preview demonstrates the same surfaces as the app instead of inventing a
// separate marketing palette.
export const heroTerminalThemes: readonly HeroTerminalTheme[] = [
  {
    id: "ghostty",
    label: "Ghostty Default",
    background: "#282c34",
    foreground: "#ffffff",
    palette: [
      "#1d1f21", "#cc6566", "#b6bd68", "#f0c674", "#82a2be", "#b294bb", "#8abeb7", "#c4c8c6",
      "#666666", "#d54e53", "#b9ca4b", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
    ],
    cursor: "#ffffff",
  },
  {
    id: "catppuccin-mocha",
    label: "Catppuccin Mocha",
    background: "#1e1e2e",
    foreground: "#cdd6f4",
    palette: [
      "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
      "#585b70", "#f7aec2", "#c2ecbf", "#fcd682", "#aeccfc", "#f398da", "#b1eae1", "#a6adc8",
    ],
    cursor: "#f5e0dc",
  },
  {
    id: "catppuccin-latte",
    label: "Catppuccin Latte",
    background: "#eff1f5",
    foreground: "#4c4f69",
    palette: [
      "#bcc0cc", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#5c5f77",
      "#acb0be", "#e7103f", "#46b02f", "#e49931", "#3878f6", "#ef95d7", "#19a1a8", "#6c6f85",
    ],
    cursor: "#dc8a78",
  },
] as const;

export function heroTerminalTheme(id: string): HeroTerminalTheme {
  return heroTerminalThemes.find((theme) => theme.id === id) ?? heroTerminalThemes[0];
}

export function heroThemeVariables(
  theme: HeroTerminalTheme,
  appearance: Exclude<HeroAppearance, "system">,
  transparency: number,
): Record<string, string> {
  const dark = appearance === "dark";
  const surface = dark ? "#111318" : "#f7f7f5";
  const foreground = dark ? "#f3f4f6" : "#242424";
  const surfaceAlpha = Math.round(100 - Math.min(Math.max(transparency, 0), 100) * 0.42);

  return {
    "--cmux-surface-background": `color-mix(in srgb, ${surface} ${surfaceAlpha}%, transparent)`,
    "--cmux-surface-token": theme.background,
    "--cmux-sidebar-surface": `color-mix(in srgb, ${surface} 92%, ${theme.background})`,
    "--cmux-elevated-background": `color-mix(in srgb, ${surface} 84%, ${foreground})`,
    "--cmux-text": foreground,
    "--cmux-text-secondary": `color-mix(in srgb, ${foreground} 68%, ${surface})`,
    "--cmux-text-tertiary": `color-mix(in srgb, ${foreground} 46%, ${surface})`,
    "--cmux-chrome-divider": `color-mix(in srgb, ${foreground} 20%, transparent)`,
    "--cmux-hover": `color-mix(in srgb, ${foreground} 8%, transparent)`,
    "--cmux-selection": `color-mix(in srgb, ${theme.palette[4]} 24%, transparent)`,
    "--cmux-accent": theme.palette[4],
    "--cmux-on-accent": dark ? "#111318" : "#ffffff",
    "--cmux-caret": theme.cursor,
    "--cmux-terminal-background": theme.background,
    "--cmux-terminal-foreground": theme.foreground,
    "--cmux-terminal-selection": theme.palette[4],
  };
}
