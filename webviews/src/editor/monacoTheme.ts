import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import type { DiffViewerTheme } from "../appearance";

/** Monaco theme names registered from the active cmux (Ghostty) appearance. */
export type MonacoThemeNames = {
  dark: string;
  light: string;
};

/**
 * Registers `cmux-dark` and `cmux-light` Monaco themes derived from the live
 * cmux appearance (the same Ghostty-derived light/dark themes the diff viewer
 * uses), so the editor matches the terminal theme instead of Monaco defaults.
 */
export function defineMonacoThemes(dark: DiffViewerTheme, light: DiffViewerTheme): MonacoThemeNames {
  monaco.editor.defineTheme("cmux-dark", themeData(dark, "vs-dark"));
  monaco.editor.defineTheme("cmux-light", themeData(light, "vs"));
  return { dark: "cmux-dark", light: "cmux-light" };
}

function themeData(theme: DiffViewerTheme, base: "vs" | "vs-dark"): monaco.editor.IStandaloneThemeData {
  const background = normalizeHex(theme.background) ?? (base === "vs-dark" ? "#1e1e1e" : "#ffffff");
  const foreground = normalizeHex(theme.foreground) ?? (base === "vs-dark" ? "#d4d4d4" : "#000000");
  const colors: Record<string, string> = {
    "editor.background": background,
    "editor.foreground": foreground,
    "editorGutter.background": background,
    "editorLineNumber.foreground": withAlpha(foreground, "66"),
    "editorLineNumber.activeForeground": withAlpha(foreground, "cc"),
  };
  const selection = normalizeHex(theme.selectionBackground);
  if (selection) {
    colors["editor.selectionBackground"] = selection;
  }
  return { base, inherit: true, rules: [], colors };
}

/** Returns a `#rrggbb` color, or `undefined` when the input is not a 6-digit hex. */
function normalizeHex(value: string | undefined): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  return /^#[0-9a-fA-F]{6}$/.test(value) ? value : undefined;
}

/** Appends an 8-bit alpha suffix to a `#rrggbb` color for subtle line-number tints. */
function withAlpha(hex: string, alpha: string): string {
  return `${hex}${alpha}`;
}
