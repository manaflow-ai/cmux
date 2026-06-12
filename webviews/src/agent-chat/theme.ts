// Terminal theme tokens for the /agent-chat surface.
//
// Reuses the agent-session theme seam end to end: the macOS host resolves the
// active terminal appearance into the AgentSessionTheme token set
// (Sources/Panels/AgentSessionWebTheme.swift) and this surface applies it with
// the shared `applyAgentTheme` (agent-session/shared/theme.ts), which writes
// the `--agent-*` CSS custom properties styles.css reads. Tokens arrive twice:
// in the `chat.init` reply (race-free initial paint, validated here) and as
// `window.cmuxAgentChatBridge.applyTheme` pushes when the terminal appearance
// changes (already wired in bridge.ts). When no tokens arrive (vite dev, the
// mock bridge, bun tests) nothing is applied and styles.css falls back to the
// system color scheme.

import { applyAgentTheme } from "../agent-session/shared/theme";
import type { AgentSessionTheme } from "../agent-session/shared/types";

const stringTokenKeys = [
  "pageBackground",
  "surfaceBackground",
  "surfaceElevatedBackground",
  "inputBackground",
  "border",
  "borderStrong",
  "text",
  "mutedText",
  "softText",
  "accent",
  "accentSoft",
  "danger",
  "shadow",
] as const;

/**
 * Validates an untyped init-reply value into the shared theme token shape.
 * The native host always sends the full set; anything partial or mistyped is
 * rejected so the surface keeps its system-scheme fallback instead of
 * rendering half-themed.
 */
export function parseAgentChatTheme(value: unknown): AgentSessionTheme | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const record = value as Record<string, unknown>;
  if (typeof record.isDark !== "boolean") {
    return null;
  }
  const theme: Record<string, string | boolean> = { isDark: record.isDark };
  for (const key of stringTokenKeys) {
    const token = record[key];
    if (typeof token !== "string" || token === "") {
      return null;
    }
    theme[key] = token;
  }
  return theme as unknown as AgentSessionTheme;
}

/**
 * Applies host-delivered theme tokens to the document. Returns whether tokens
 * were valid and applied; `false` leaves the document untouched (the CSS
 * system-scheme fallback stays in effect).
 */
export function applyAgentChatTheme(value: unknown): boolean {
  const theme = parseAgentChatTheme(value);
  if (theme === null) {
    return false;
  }
  applyAgentTheme(theme);
  return true;
}
