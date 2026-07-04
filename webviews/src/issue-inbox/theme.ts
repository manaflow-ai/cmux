import type { IssueInboxTheme } from "./types";

const cssVariables: Record<keyof IssueInboxTheme, string | null> = {
  isDark: null,
  pageBackground: "--issue-page-bg",
  surfaceBackground: "--issue-surface",
  surfaceElevatedBackground: "--issue-surface-elevated",
  inputBackground: "--issue-input-bg",
  border: "--issue-border",
  borderStrong: "--issue-border-strong",
  text: "--issue-text",
  mutedText: "--issue-muted",
  softText: "--issue-soft",
  accent: "--issue-accent",
  accentSoft: "--issue-accent-soft",
  danger: "--issue-danger",
  shadow: "--issue-shadow",
};

export function applyIssueInboxTheme(theme: IssueInboxTheme | undefined): void {
  if (!theme || typeof document === "undefined") {
    return;
  }
  const root = document.documentElement;
  root.dataset.theme = theme.isDark ? "dark" : "light";
  root.classList.toggle("dark", theme.isDark);
  root.classList.toggle("light", !theme.isDark);
  root.style.colorScheme = theme.isDark ? "dark" : "light";
  for (const [key, variable] of Object.entries(cssVariables) as Array<
    [keyof IssueInboxTheme, string | null]
  >) {
    if (variable) {
      root.style.setProperty(variable, String(theme[key]));
    }
  }
}
