import type { AgentSessionTheme } from "./types";

const cssVariables: Record<keyof AgentSessionTheme, string | null> = {
  isDark: null,
  pageBackground: "--agent-page-bg",
  surfaceBackground: "--agent-surface",
  surfaceElevatedBackground: "--agent-surface-elevated",
  inputBackground: "--agent-input-bg",
  border: "--agent-border",
  borderStrong: "--agent-border-strong",
  text: "--agent-text",
  mutedText: "--agent-muted",
  softText: "--agent-soft",
  accent: "--agent-accent",
  accentSoft: "--agent-accent-soft",
  accentText: "--agent-accent-text",
  danger: "--agent-danger",
  warning: "--agent-warning",
  highlight: "--agent-highlight",
  highlightText: "--agent-highlight-text",
  shadow: "--agent-shadow",
  palette: null,
  borders: null,
};

export function applyAgentTheme(theme: AgentSessionTheme): void {
  if (typeof document === "undefined") {
    return;
  }
  const root = document.documentElement;
  root.dataset.theme = theme.isDark ? "dark" : "light";
  applyCodexDocumentMetadata();
  root.classList.toggle("dark", theme.isDark);
  root.classList.toggle("electron-dark", theme.isDark);
  root.classList.toggle("light", !theme.isDark);
  root.style.colorScheme = theme.isDark ? "dark" : "light";
  // appearance.borders: the stylesheets clear their edges under `[data-borders="none"]`.
  if (theme.borders === "none") root.dataset.borders = "none";
  else delete root.dataset.borders;
  for (const [key, variable] of Object.entries(cssVariables) as Array<[keyof AgentSessionTheme, string | null]>) {
    if (!variable) {
      continue;
    }
    // A key this theme leaves out must not keep the last theme's value.
    if (theme[key] === undefined) {
      root.style.removeProperty(variable);
      continue;
    }
    root.style.setProperty(variable, String(theme[key]));
  }
  // `--agent-ansi-0` … `--agent-ansi-15`; a theme without a palette clears them.
  for (let index = 0; index < 16; index += 1) {
    const color = theme.palette?.[index];
    if (color) root.style.setProperty(`--agent-ansi-${index}`, color);
    else root.style.removeProperty(`--agent-ansi-${index}`);
  }
}

export function applyCodexDocumentMetadata(): void {
  if (typeof document === "undefined") {
    return;
  }
  const root = document.documentElement;
  root.dataset.codexWindowType = "electron";
  root.dataset.windowType = "electron";
  root.dataset.codexOs = codexOs();
  if (document.body) {
    document.body.dataset.codexWindowType = "electron";
  }
}

function codexOs(): string {
  if (typeof navigator === "undefined") {
    return "unknown";
  }
  const maybeNavigator = navigator as Navigator & {
    userAgentData?: { platform?: string };
  };
  const platform = (
    maybeNavigator.userAgentData?.platform ??
    maybeNavigator.platform ??
    maybeNavigator.userAgent
  ).toLowerCase();
  if (platform.includes("win")) {
    return "win32";
  }
  if (platform.includes("mac") || platform.includes("darwin")) {
    return "darwin";
  }
  if (platform.includes("linux")) {
    return "linux";
  }
  return "unknown";
}
