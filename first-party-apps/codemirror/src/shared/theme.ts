// Terminal-derived editor colors (shared by the editor apps; identical copies
// in first-party-apps/{monaco,codemirror}/src/shared). Syntax colors come from
// the terminal's 16-color palette. Blue entries (4, 12) are never used, and
// selection, cursor and focus use the host's colors, never a library default.

import type { EditorSettings, EditorTheme } from "../interfaces/editor.ts"

const HEX = /^#([0-9a-f]{6})$/i

export function parseHex(color: string): [number, number, number] | null {
  const m = HEX.exec(color.trim())
  if (!m) return null
  const n = parseInt(m[1]!, 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

const hex = (rgb: [number, number, number]) => `#${rgb.map((v) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0")).join("")}`

/** `a` mixed toward `b` by `t` (0..1). */
export function mix(a: string, b: string, t: number): string {
  const x = parseHex(a)
  const y = parseHex(b)
  if (!x || !y) return a
  return hex([x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t])
}

/** `#RRGGBBAA` with the given alpha (0..1). */
export const alpha = (color: string, a: number) => (parseHex(color) ? `${color.slice(0, 7)}${Math.round(a * 255).toString(16).padStart(2, "0")}` : color)

export interface SyntaxColors {
  keyword: string
  string: string
  number: string
  comment: string
  function: string
  type: string
  constant: string
  property: string
  tag: string
  attribute: string
  regexp: string
  operator: string
  heading: string
  link: string
  invalid: string
  variable: string
}

/** ANSI index -> role. 0 black 1 red 2 green 3 yellow 5 magenta 6 cyan 8+ bright. No 4 or 12 (blue). */
export function syntaxColors(theme: EditorTheme): SyntaxColors {
  const p = (i: number, fallback: string) => (parseHex(theme.palette[i] ?? "") ? theme.palette[i]! : fallback)
  const fg = theme.foreground
  const muted = mix(fg, theme.background, 0.45)
  return {
    keyword: p(5, fg),
    string: p(2, fg),
    number: p(3, fg),
    comment: p(8, muted),
    function: p(6, fg),
    type: p(11, p(3, fg)),
    constant: p(13, p(5, fg)),
    property: p(14, p(6, fg)),
    tag: p(1, fg),
    attribute: p(3, fg),
    regexp: p(9, p(1, fg)),
    operator: mix(fg, theme.background, 0.2),
    heading: p(13, p(5, fg)),
    link: p(14, p(6, fg)),
    invalid: p(1, fg),
    variable: fg
  }
}

/** Chrome colors derived from the theme (status line, banners, gutters, diff bands). */
export function chromeColors(theme: EditorTheme) {
  const bg = theme.background
  const fg = theme.foreground
  return {
    background: bg,
    foreground: fg,
    muted: mix(fg, bg, 0.45),
    faint: mix(fg, bg, 0.7),
    line: mix(bg, fg, 0.06),
    gutter: mix(fg, bg, 0.6),
    gutterActive: mix(fg, bg, 0.2),
    statusBackground: mix(bg, fg, 0.04),
    border: mix(bg, fg, 0.14),
    accent: theme.accent,
    cursor: theme.cursor,
    selection: theme.selectionBackground,
    selectionText: theme.selectionForeground ?? null,
    inactiveSelection: alpha(theme.selectionBackground, 0.55),
    added: theme.palette[2] ?? "#3f9f5f",
    removed: theme.palette[1] ?? "#c0504d",
    warning: theme.palette[3] ?? "#c79a3a",
    addedBand: alpha(theme.palette[2] ?? "#3f9f5f", theme.appearance === "dark" ? 0.16 : 0.14),
    removedBand: alpha(theme.palette[1] ?? "#c0504d", theme.appearance === "dark" ? 0.16 : 0.12),
    addedText: alpha(theme.palette[2] ?? "#3f9f5f", 0.32),
    removedText: alpha(theme.palette[1] ?? "#c0504d", 0.3),
    match: alpha(theme.accent, 0.28),
    matchStrong: alpha(theme.accent, 0.5)
  }
}

/** Sets CSS variables on the root for the chrome stylesheet (shared/chrome.css). */
export function applyCssVariables(root: { style: { setProperty(k: string, v: string): void } }, theme: EditorTheme, settings: EditorSettings) {
  const c = chromeColors(theme)
  const vars: Record<string, string> = {
    "--cmux-bg": c.background,
    "--cmux-fg": c.foreground,
    "--cmux-muted": c.muted,
    "--cmux-faint": c.faint,
    "--cmux-status-bg": c.statusBackground,
    "--cmux-border": c.border,
    "--cmux-accent": c.accent,
    "--cmux-warning": c.warning,
    "--cmux-danger": c.removed,
    "--cmux-success": c.added,
    "--cmux-font": fontFamily(theme, settings),
    "--cmux-font-size": `${fontSize(theme, settings)}px`
  }
  for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v)
}

const quote = (f: string) => (/^[\w-]+$/.test(f) || /^["'].*["']$/.test(f) ? f : `"${f.replace(/"/g, "")}"`)

export function fontFamily(theme: EditorTheme, settings: EditorSettings): string {
  const chosen = settings.fontFamily.trim() || theme.fontFamily.trim()
  return [chosen, "ui-monospace", "SFMono-Regular", "Menlo", "monospace"].filter(Boolean).map(quote).join(", ")
}

export const fontSize = (theme: EditorTheme, settings: EditorSettings) => (settings.fontSize >= 6 && settings.fontSize <= 72 ? settings.fontSize : theme.fontSize >= 6 ? theme.fontSize : 13)

/** A neutral theme for previews and for a pane opened before the host sends one. */
export const FALLBACK_THEME: EditorTheme = {
  appearance: "dark",
  background: "#1d1f21",
  foreground: "#c5c8c6",
  cursor: "#c5c8c6",
  selectionBackground: "#3d4245",
  palette: ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6", "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea"],
  fontFamily: "",
  fontSize: 13,
  accent: "#c5c8c6"
}
