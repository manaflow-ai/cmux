// Applies the host theme (the AgentPaneTheme.values keys) as CSS variables on <html>.
// Background keys (pageBackground, surfaceBackground...) are ignored on purpose: the page
// never paints a background; the page tab under the transparent web view does.
const variables: Record<string, string> = {
  text: "--text",
  mutedText: "--muted-text",
  softText: "--soft-text",
  border: "--border",
  borderStrong: "--border-strong",
  inputBackground: "--input-bg",
  accent: "--accent",
  accentSoft: "--accent-soft",
  accentText: "--accent-text",
  danger: "--danger",
  warning: "--warning",
  highlight: "--highlight",
  highlightText: "--highlight-text",
};

const motion: Record<string, string> = {
  hover: "--motion-hover",
  focus: "--motion-focus",
  fadeIn: "--motion-in",
  fadeOut: "--motion-out",
};

export function applySettingsTheme(values: Record<string, unknown>, root = document.documentElement): void {
  const isDark = values.isDark === true;
  root.dataset.theme = isDark ? "dark" : "light";
  root.style.colorScheme = isDark ? "dark" : "light";
  if (values.borders === "none") root.dataset.borders = "none";
  else delete root.dataset.borders;
  for (const [key, variable] of Object.entries(variables)) {
    const value = values[key];
    if (typeof value === "string") root.style.setProperty(variable, value);
    else root.style.removeProperty(variable);
  }
  const durations = (values.motion ?? {}) as Record<string, unknown>;
  for (const [key, variable] of Object.entries(motion)) {
    const seconds = durations[key];
    if (typeof seconds === "number" && Number.isFinite(seconds) && seconds >= 0)
      root.style.setProperty(variable, `${Math.round(seconds * 1000)}ms`);
    else root.style.removeProperty(variable);
  }
}
