import { SCROLLER_FADE_ATTRIBUTE } from "../../scrollers";
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
  litGlyph: "--agent-lit-glyph",
  accentText: "--agent-accent-text",
  onAccent: "--agent-on-accent",
  danger: "--agent-danger",
  warning: "--agent-warning",
  success: "--agent-success",
  highlight: "--agent-highlight",
  highlightText: "--agent-highlight-text",
  shadow: "--agent-shadow",
  palette: null,
  borders: null,
  focusRingEnabled: null,
  chatWidth: null,
  codexToolRuns: null,
  liveLineBelow: null,
  toolRunLook: null,
  turnActionsPlacement: null,
  motion: null,
  statusIndicators: null,
  workingLook: null,
  subagentTray: null,
  subagentTrayPlacement: null,
  scrollerFade: null,
};

const motionVariables = {
  hover: "--agent-motion-hover",
  hoverOut: "--agent-motion-hover-out",
  focus: "--agent-motion-focus",
  fadeIn: "--agent-motion-in",
  fadeOut: "--agent-motion-out",
  move: "--agent-motion-move",
} as const;

export function applyAgentTheme(theme: AgentSessionTheme): void {
  if (typeof document === "undefined") {
    return;
  }
  const root = document.documentElement;
  root.dataset.theme = theme.isDark ? "dark" : "light";
  applyAgentDocumentMetadata();
  root.classList.toggle("dark", theme.isDark);
  root.classList.toggle("light", !theme.isDark);
  root.style.colorScheme = theme.isDark ? "dark" : "light";
  // appearance.borders: the stylesheets clear their edges under `[data-borders="none"]`.
  if (theme.borders === "none") root.dataset.borders = "none";
  else delete root.dataset.borders;
  // The native focusRing.enabled setting also controls transcript response outlines.
  if (theme.focusRingEnabled === true) root.dataset.focusRingEnabled = "true";
  else delete root.dataset.focusRingEnabled;
  // Static status indicators (or Reduce Motion): the stylesheets stop their loops under it.
  if (theme.statusIndicators) root.dataset.statusIndicators = theme.statusIndicators;
  else delete root.dataset.statusIndicators;
  // How agent work shows on running rows (conversation.css WORKING-LOOK).
  if (theme.workingLook) root.dataset.workingLook = theme.workingLook;
  else delete root.dataset.workingLook;
  // The opt-in scrollbar fade (scrollers.ts SCROLLER_FADE_ATTRIBUTE): shown scrollers fade at rest.
  root.toggleAttribute(SCROLLER_FADE_ATTRIBUTE, theme.scrollerFade === true);
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
  // A theme without motion clears the host's durations, so the stylesheet defaults apply.
  for (const [key, variable] of Object.entries(motionVariables) as Array<[keyof typeof motionVariables, string]>) {
    const seconds = theme.motion?.[key];
    if (typeof seconds === "number" && Number.isFinite(seconds) && seconds >= 0) {
      root.style.setProperty(variable, `${Math.round(seconds * 1000)}ms`);
    } else root.style.removeProperty(variable);
  }
  // `ui.animationSpeed: off` reaches the page as an all-zero motion policy. Mark it on the root so
  // CSS animations and transitions that represent loops or third-party surfaces stop as well as
  // tokenized fades. Reduce Motion keeps its short crossfade values and therefore does not trip this.
  const motionValues = theme.motion ? Object.values(theme.motion) : [];
  if (motionValues.length > 0 && motionValues.every((value) => value === 0)) root.dataset.agentMotion = "off";
  else delete root.dataset.agentMotion;
  if (root.dataset.agentMotion === "off") {
    for (const animation of document.getAnimations?.() ?? []) animation.cancel();
  }
  // `--agent-ansi-0` … `--agent-ansi-15`; a theme without a palette clears them.
  for (let index = 0; index < 16; index += 1) {
    const color = theme.palette?.[index];
    if (color) root.style.setProperty(`--agent-ansi-${index}`, color);
    else root.style.removeProperty(`--agent-ansi-${index}`);
  }
  applyTerminalCodeFont(root);
}

/** The mono stack behind the terminal's face, the pane's own default (conversation.css `--cv-mono`). */
const MONO_STACK = `ui-monospace, "SF Mono", Menlo, monospace`;
/** The pane's code font variables: diffs (diffTheme.ts) and code blocks, file names and paths. */
const CODE_FONT_VARIABLES = ["--cmux-diff-code-font-family", "--cv-code-font"] as const;

/**
 * Code in the pane draws in the terminal's face, as on the diff, markdown and editor pages. The host
 * applies the shared web theme (`window.cmuxTheme`, its `terminal.fontFamily`) just before the pane's
 * own on every theme change (AgentPaneTheme.swift `script`); without a named face the stylesheets'
 * mono stack applies.
 */
function applyTerminalCodeFont(root: HTMLElement): void {
  const host = (window as { cmuxTheme?: { current?: { terminal?: { fontFamily?: unknown } } | null } }).cmuxTheme;
  const family = host?.current?.terminal?.fontFamily;
  const face = typeof family === "string" ? family.trim() : "";
  for (const variable of CODE_FONT_VARIABLES) {
    if (face) root.style.setProperty(variable, `${JSON.stringify(face)}, ${MONO_STACK}`);
    else root.style.removeProperty(variable);
  }
}

export function applyAgentDocumentMetadata(): void {
  if (typeof document === "undefined") {
    return;
  }
  const root = document.documentElement;
  root.dataset.agentOs = agentOs();
}

function agentOs(): string {
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
